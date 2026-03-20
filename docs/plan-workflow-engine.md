# Plan: Lua Workflow Engine

**Status: NOT STARTED**

## Context

The thin slice works: trigger → single LLM call → output. But an "agent" that makes one API call isn't an agent — it's a function. The next step is a workflow engine that can execute multi-step Lua scripts, where each step is either deterministic (HTTP call, data transform) or LLM-based (summarize, classify, extract).

This engine is the foundation that the chat builder will eventually generate Lua scripts for. We need to understand what generated workflows look like by hand-writing a few first.

### Why Lua (not Elixir modules, not JSON graphs)

The builder LLM generates workflows at runtime. This rules out:
- **Elixir modules** — unsandboxable. LLM-generated Elixir has access to `:os.cmd`, `System.cmd`, file I/O, network, etc.
- **JSON/YAML step graphs** — too limited. Representing loops, conditionals, and variables in data means reinventing a bad programming language.

Lua via luerl (pure Erlang Lua 5.3 VM) gives us:
- Real control flow in a language LLMs are good at generating
- Sandboxed by architecture — only explicitly exposed host functions are callable
- Zero serialization cost on the BEAM — no NIFs, no ports
- VM state is an immutable Erlang term — checkpointable

We use the `lua` hex package (wraps luerl) for the Elixir API.

## What To Build

### 1. Lua Runtime Module

`lib/norns/workflow/runtime.ex`

Wraps the `lua` hex package. Responsibilities:
- Initialize a sandboxed Lua VM with host functions loaded
- Execute a Lua script string within the VM
- Enforce resource limits (max_reductions, max_time via luerl_sandbox)
- Capture and format errors for feedback to the builder LLM

```elixir
defmodule Norns.Workflow.Runtime do
  def execute(script, state, context) do
    Lua.new()
    |> Lua.load_api(Norns.Workflow.API)
    |> Lua.set!("state", state)
    |> Lua.set!("ctx", context)
    |> Lua.eval!(script)
  end
end
```

### 2. Host API Module

`lib/norns/workflow/api.ex`

Elixir module using `deflua` to expose functions to Lua scripts:

```elixir
defmodule Norns.Workflow.API do
  use Lua.API

  deflua call_llm(prompt, opts) do
    # Call Anthropic API, log RunEvent, return response
  end

  deflua http(method, url, body) do
    # Make HTTP request, log RunEvent, return response
  end

  deflua store(key, value) do
    # Persist key-value pair, log RunEvent
  end

  deflua emit(value) do
    # Set workflow output, log RunEvent
  end

  deflua interrupt(payload) do
    # Pause workflow, checkpoint VM state, surface payload to caller
  end
end
```

Every function logs a RunEvent before returning. This is the audit trail and the replay cache.

### 3. Checkpointing and Durability

Each side-effectful host function call:
1. Logs a RunEvent with type, input, and output
2. On replay: checks if a RunEvent already exists for this sequence number → returns cached result instead of re-executing

The Lua VM state can optionally be serialized to the run's `state` column between steps for exact resume semantics.

### 4. Workflow-Aware Runner

Update `Norns.Agents.Runner` to:
- Check if the agent has a `workflow_script`
- If yes: pass the script to `Workflow.Runtime.execute/3`
- If no: fall back to the current single-LLM-call behavior
- Handle the `interrupt` case: save VM state, set run status to `waiting`
- Handle resume: restore VM state, continue execution

### 5. Agent Schema Change

Add `workflow_script` (text) to agents. This is the Lua source code. Nullable — agents without a script use the legacy single-prompt path.

Migration: add column, no data backfill needed.

### 6. Two Concrete Workflows

**a) Release Notes Generator** — refactor from mix task

```lua
local since = state.since or "7 days ago"
local commits = http("GET", ctx.repo_url .. "/commits?since=" .. since)

if #commits == 0 then
  emit("No commits found.")
  return
end

local notes = call_llm(
  "Summarize these commits into user-facing release notes grouped by category. Output markdown.\n\n"
  .. commits.body
)

emit(notes)
```

**b) URL Summarizer** — proves HTTP step works

```lua
local body = http("GET", state.url)
local summary = call_llm("Summarize the following web page content concisely:\n\n" .. body.body)
emit(summary)
```

### 7. POST Endpoint to Trigger Runs

`POST /api/v1/runs`

```json
{
  "agent": "release-notes-generator",
  "input": {"since": "7 days ago"}
}
```

Returns:
```json
{
  "run_id": 42,
  "status": "pending"
}
```

Also: `POST /api/v1/runs/:id/resume` for resuming interrupted workflows.

## Files to Create/Modify

| File | Action |
|------|--------|
| `lib/norns/workflow/runtime.ex` | NEW — Lua VM wrapper, execution, sandboxing |
| `lib/norns/workflow/api.ex` | NEW — host functions exposed to Lua (`deflua`) |
| `lib/norns/agents/runner.ex` | MODIFY — dispatch to Lua runtime |
| `lib/norns/agents/agent.ex` | MODIFY — add workflow_script field |
| `priv/repo/migrations/NEW` | Migration: add workflow_script to agents |
| `lib/mix/tasks/gen_release_notes.ex` | MODIFY — use Lua workflow-based agent |
| `lib/norns_web/endpoint.ex` | NEW — Phoenix endpoint |
| `lib/norns_web/router.ex` | NEW — API routes |
| `lib/norns_web/controllers/run_controller.ex` | NEW — POST /api/v1/runs, POST /runs/:id/resume |
| `lib/norns_web/plugs/api_auth.ex` | NEW — API key auth |
| `config/dev.exs` | MODIFY — add endpoint config |
| `mix.exs` | MODIFY — add `lua` dependency |
| `test/norns/workflow/runtime_test.exs` | NEW — Lua execution + sandboxing tests |
| `test/norns/workflow/api_test.exs` | NEW — host function tests |
| `test/norns_web/controllers/run_controller_test.exs` | NEW |

## What We're NOT Building

- Chat builder (needs the engine first)
- Integration connectors (use HTTP for everything)
- Workflow code generation (the chat builder's job, not the engine's)
- Streaming responses from within Lua scripts
- Parallel step execution within a single workflow
- Visual workflow editor or graph UI

## Implementation Order

1. Add `lua` dep, spike a hello-world Lua execution in a test
2. Build `Workflow.Runtime` — execute Lua strings with sandboxing
3. Build `Workflow.API` — expose `call_llm`, `http`, `emit` with RunEvent logging
4. Wire into Runner — agent with `workflow_script` dispatches to Lua runtime
5. Hand-write the two example workflows, validate end-to-end
6. Add the POST endpoint for triggering runs
7. Add `interrupt`/resume support

## Verification

1. `docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test` — all tests pass
2. Trigger release notes workflow via API — returns run_id, run completes
3. Check DB: run has events for each Lua host function call with inputs/outputs logged
4. Trigger URL summarizer — exercises HTTP + LLM steps
5. Test sandboxing: a Lua script that tries `os.execute("rm -rf /")` fails safely
6. Test resource limits: an infinite loop hits max_reductions and terminates
