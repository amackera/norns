# Architecture

## Product Vision

Norns is a chat-based builder for AI-enabled workflows. The core loop:

1. User describes a workflow in natural language via chat
2. A builder LLM generates a Lua script — real code with loops, conditionals, integrations
3. The workflow engine executes it on the BEAM via luerl, logging every step
4. Some workflow steps are deterministic (HTTP calls, data transforms); some call an LLM for reasoning (summarize, classify, extract, decide)

**The product is the builder.** The engine is infrastructure. Integrations are third-party (Nango/Composio or plain HTTP) — we build none ourselves.

## Current State

The engine foundation works: define an agent → trigger a run via Oban → call the Anthropic API → store the output with a full event trail.

```
Supervisor
├── Norns.Repo (Ecto/PostgreSQL)
└── Oban (background job processor)
    └── Workers.RunAgent → Agents.Runner → LLM.complete
```

**Execution flow:**
1. Something enqueues a `RunAgent` Oban job (currently: mix task)
2. Worker looks up agent + tenant, calls `Runner.execute/3`
3. Runner creates a Run, transitions through pending → running → completed/failed
4. Each step is logged as a RunEvent (run_started, llm_response, run_completed)

**Data model:**
- `tenants` — name, slug, api_keys (Anthropic key per tenant)
- `agents` — name, purpose, system_prompt, model, model_config, status, tenant_id
- `runs` — status, trigger_type, input, state, output, agent_id, tenant_id
- `run_events` — sequence, event_type, payload, source, metadata, run_id, tenant_id

## Next: Lua Workflow Engine (see `plan-workflow-engine.md`)

Agents get a `workflow_script` field containing a Lua script. The engine executes it via luerl on the BEAM, with host functions exposed for side effects (`call_llm`, `http`, `store`, `emit`, `interrupt`). Every side-effectful call is logged as a RunEvent.

```lua
local commits = http("GET", "https://api.github.com/repos/org/repo/commits?since=" .. ctx.input.since)

local notes = call_llm("Summarize these commits into release notes:\n\n" .. commits.body)

emit(notes)
```

This is the foundation the chat builder will eventually generate code for.

## Key Design Principles

### Workflows Are Code, Not Config

Workflows are Lua scripts — real code with the full expressiveness of a programming language. Not JSON step lists, not YAML, not a visual DAG. This is what the chat builder generates.

Previously considered Elixir modules, but LLM-generated Elixir is an unsandboxable security risk. Lua via luerl gives us real code in a sandboxed environment. See `decision-log.md` for the full evaluation.

### Control Plane vs Reasoning Plane

- **Control plane (deterministic):** the Lua script itself — conditionals, loops, data flow, error handling
- **Reasoning plane (non-deterministic):** `call_llm()` steps within the script — summarize, classify, extract, decide

The workflow is always deterministic in structure. LLM steps are just another function call within the code.

### Durable Execution via Checkpointed Side Effects

Every side-effectful host function (`call_llm`, `http`, `store`) is checkpointed as a RunEvent. On replay, intercepted calls return cached results from the event log instead of re-executing. This gives Temporal-style durability without Temporal infrastructure.

The Lua VM state (an immutable Erlang term in luerl) can be snapshotted between steps for exact resume-from-pause semantics — no node re-execution needed (unlike LangGraph).

### Error Taxonomy

Four categories, each with a different recovery path:
1. **Transient** (network, rate limits) → automatic retry with backoff (Oban)
2. **LLM-recoverable** (bad tool call, parse failure) → feed error back to the LLM
3. **User-fixable** (missing info, needs approval) → `interrupt()` pauses the workflow
4. **Unexpected** → bubble up for debugging

### Integrations Are Third-Party

We don't build Slack/GitHub/Gmail connectors. Options:
- Managed integration platforms (Nango, Composio) for auth + normalized APIs
- Plain HTTP for anything with a REST API
- Webhooks for inbound triggers

### Multi-Tenancy Is Structural

Every table has `tenant_id`. Agent names unique per tenant. API keys per tenant. This is enforced at the data model level, not application middleware.

## Future Direction

### Chat Builder (the product)

An LLM-powered chat interface that translates natural language into Lua workflow scripts:

- "Make an agent that summarizes open PRs every morning and posts to Slack"
- "Add a step that checks for security vulnerabilities before posting"
- "Change it to run at 8am instead of 9am"

The builder LLM understands:
- The available Lua API surface (host functions it can call)
- When to emit a deterministic step vs an LLM step
- What integrations are available and how to use them
- How to wire up triggers (schedule, webhook, event-driven)

### Agent Management UI

Web UI for viewing and managing what the builder creates:
- Agent status (inactive / idle / running)
- Run history and step-by-step event logs
- Edit name, purpose, trigger schedule
- Start / stop agents
- View and edit the generated Lua script directly

Visual direction: monochrome base, minimal accent colors for status, clean typography, blueprint aesthetic.

### Interrupt/Resume (human-in-the-loop)

Workflows can pause at any point via `interrupt(payload)`, surfacing a request to the caller. The run enters `waiting` status. An API endpoint resumes it with a response value. The Lua VM state is checkpointed at the exact pause point.

### LLM Reflection Points

Workflows can include reflection checkpoints where `call_llm()` reviews the execution so far and can adjust the plan. Between reflection points, execution is pure Lua. At reflection points, it's agentic.

## Process Architecture (Target)

```
Supervisor
├── Norns.Repo (Ecto/PostgreSQL)
├── Oban (scheduled jobs and triggers)
└── Phoenix.Endpoint (web layer + API)
```

GenServers and DynamicSupervisors are deferred until workflows need long-running or interactive execution.
