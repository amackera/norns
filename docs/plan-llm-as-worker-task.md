# Plan: LLM Calls as Worker Tasks

## The Problem

The agent GenServer currently makes LLM calls synchronously inside its process. When the LLM returns a 429 rate limit error, the agent either retries (blocking itself and making `get_state` timeout) or fails the entire run. The agent is tightly coupled to LLM execution — if the call can't complete right now, everything stalls.

This is the same problem Temporal solved for arbitrary code execution: the orchestrator should never execute anything directly.

## The Insight

LLM calls are just another task to be done — no different from tool calls. The orchestrator should dispatch them and wait, not execute them. This makes the agent a pure state machine: "given my current state and the event log, what's the next task to dispatch?"

## Proposed Architecture

```
Orchestrator (state machine)              Worker (executes things)
  │                                           │
  │  "I need an LLM response"                │
  │  → checkpoint state                       │
  │  → dispatch llm_task to queue ──────────► │  picks up llm_task
  │  → go idle (handle other messages)        │  calls Anthropic API
  │                                           │  429? → back to queue with delay
  │                                           │  success? → deliver result
  │  ◄── llm_response ──────────────────────  │
  │  → log event                              │
  │  → "I need a tool executed"               │
  │  → dispatch tool_task ──────────────────► │  picks up tool_task
  │  ...                                      │
```

### What the orchestrator does
- Maintains the agent state machine (idle → running → waiting → completed)
- Logs events to the run event log
- Decides what to do next based on the last event
- Dispatches tasks (LLM calls, tool calls) to workers
- Responds to status queries, stop requests, messages at any time (never blocked)

### What the orchestrator does NOT do
- Make HTTP calls to the LLM API
- Execute tool handlers
- Block on anything

### What workers do
- Connect to the runtime (persistent WebSocket or in-process)
- Register capabilities: "I can make LLM calls" and/or "I can run these tools"
- Pick up tasks, execute them, return results
- Handle retries, rate limiting, backoff locally
- Hold the API keys (LLM keys, database credentials, etc.)

## Worker Types

### LLM Worker
Registers capability to make LLM calls. Receives `llm_task` with model, system prompt, messages, tools. Returns the LLM response. Handles rate limits with queuing/backoff — the orchestrator never sees a 429.

### Tool Worker (existing)
Registers specific tool functions. Receives `tool_task` with tool name and input. Returns tool result. This is what we already have.

### Default Worker (bundled)
Ships with Norns for the self-hosted / getting-started experience. Runs in the same BEAM VM as the orchestrator. Handles LLM calls + built-in tools. Zero config — just works.

When you want to scale or separate concerns:
- Run the orchestrator on its own
- Run LLM workers closer to the API provider (or with different API keys per worker)
- Run tool workers in your infrastructure

## What Changes in the Agent Process

The agent GenServer becomes a state machine driven by events:

```elixir
# Current: GenServer that blocks on LLM calls
handle_continue(:llm_loop, state) do
  case LLM.chat(...) do  # blocks for 5-30 seconds
    {:ok, response} -> handle_llm_response(state, response)
    {:error, reason} -> handle_error(state, reason)
  end
end

# Proposed: GenServer that dispatches and waits
handle_continue(:llm_loop, state) do
  # Non-blocking: dispatch and return immediately
  dispatch_llm_task(state)
  {:noreply, %{state | status: :awaiting_llm}}
end

handle_info({:llm_result, response}, state) do
  handle_llm_response(state, response)
end
```

The agent is never blocked. It can always respond to `get_state`, `stop`, or other messages.

## Rate Limiting

With LLM calls on workers, rate limiting becomes a worker-side concern:

- **Per-tenant rate limiter** on the LLM worker: queue LLM tasks, dispatch at the allowed rate
- **Backoff on 429**: worker re-queues the task with a delay, orchestrator is unaware
- **Priority queuing**: interactive agents get priority over batch tasks
- **Multiple API keys**: different workers with different keys for different rate limit pools

The orchestrator never sees a rate limit error. From its perspective, LLM calls just take varying amounts of time.

## Self-hosted Mode (Default)

For the getting-started experience, nothing changes from the user's perspective:

```bash
docker compose up   # starts orchestrator + default worker + DB
```

The default worker runs in the same BEAM VM. LLM calls and built-in tools are "local" — function calls with no network hop. The architectural separation exists but is invisible.

The difference only appears when you:
- Want separate workers for different API keys
- Want workers in different regions
- Want to scale workers independently
- Want workers in a different language (Python/TS SDK)

## Migration Path

This is a big architectural shift. Phased approach:

### Phase A: Async LLM dispatch (minimal change)
- Agent process dispatches LLM calls via `Task.async` or a dedicated GenServer
- Agent doesn't block — receives result as a message
- Rate limiting handled by the LLM dispatch layer
- No worker protocol change needed
- Default worker is just a local module

### Phase B: LLM tasks through worker protocol
- LLM calls dispatched through the same WorkerRegistry as tool calls
- Workers register "llm" capability alongside tool registrations
- Unified task dispatch: LLM and tools use the same path
- Default worker handles both

### Phase C: Full separation
- Orchestrator is a pure state machine
- All execution goes through workers
- Multiple worker types with different capabilities
- SDK workers in Python/TS can handle LLM calls too

## Implications

### Security
Workers hold API keys, not the orchestrator. In the cloud offering, Norns never sees user API keys — workers in the user's infrastructure make the LLM calls directly. This is a much better security story.

### API key per tenant
Currently the tenant's Anthropic key is stored in the `tenants.api_keys` map and the orchestrator uses it directly. In the worker model, the key lives on the worker. For self-hosted mode, the default worker reads it from the environment.

For cloud mode: the user's worker connects with their API key. Norns Cloud never touches it.

### Pricing
In cloud mode, Norns charges for orchestration (events, storage, compute), not for LLM usage. LLM costs are between the user and their LLM provider. Clean separation.

## What NOT to change

- Event log structure — events are the same regardless of where execution happens
- Agent modes (task/conversation) — orthogonal to execution model
- Memory — still agent-scoped, still stored in Norns DB
- Dashboard — shows the same events regardless of execution model

## Open Questions

1. **Should the orchestrator be able to run without any workers?** If yes, keep the ability to make LLM calls locally as a fallback. If no, workers are required (like Temporal).

2. **Task persistence**: should dispatched tasks survive orchestrator restarts? Oban gives this for free. The worker protocol currently doesn't persist tasks — they're in-memory in WorkerRegistry/TaskQueue.

3. **LLM task shape**: what exactly goes in an `llm_task`? The full messages array? Or a reference to the run + step so the worker can load it? Sending full messages is simpler. Reference is more efficient for large conversations.

## Files Affected

This is Phase A only (async LLM dispatch, minimal change):

| File | Change |
|------|--------|
| `lib/norns/agents/process.ex` | Dispatch LLM calls async instead of blocking |
| `lib/norns/llm_dispatcher.ex` | New: handles LLM task queuing, rate limiting, dispatch |
| `lib/norns/application.ex` | Add LLM dispatcher to supervision tree |
| `test/norns/agents/process_test.ex` | Update for async LLM pattern |

Phase B and C would involve larger changes to the worker protocol and are separate plans.
