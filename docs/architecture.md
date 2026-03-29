# Architecture

## What Is This

Norns is a durable agent runtime. It orchestrates LLM-powered agents — managing state, checkpointing, retries, and crash recovery — while workers handle all actual execution (LLM calls, tool functions, external API access).

The orchestrator is a pure state machine. It never makes LLM calls or executes tools. You must connect at least one worker for agents to do anything.

## Orchestrator / Worker Split

```
Orchestrator (state machine)              Worker (your code)
  │                                           │
  │  dispatch llm_task ─────────────────────► │  calls LLM API
  │  ◄── llm_response ──────────────────────  │
  │  log event, dispatch tool_task ─────────► │  executes tool
  │  ◄── tool_result ───────────────────────  │
  │  log event, checkpoint                    │
```

Workers connect via `/worker` WebSocket, register their tools and LLM capability, and receive task pushes. Workers hold all API keys and secrets. Norns never sees them.

If a worker disconnects, pending tasks are queued and flushed when it reconnects.

## Agent States

Each agent is a GenServer managed by a DynamicSupervisor:

- `:idle` — waiting for a message
- `:awaiting_llm` — dispatched LLM task, waiting for response
- `:awaiting_tools` — dispatched tool tasks, waiting for results
- `:waiting` — paused for human input (interrupt/resume)

The agent is never blocked — it always responds to status queries and stop requests.

## Agent Modes

**Task mode** (default) — each message starts a fresh run. No history between runs.

**Conversation mode** — messages append to a persistent conversation. The LLM sees full history from previous runs. One agent can handle multiple concurrent conversations, each identified by an external key (e.g., Slack channel ID).

Context management via sliding window (configurable size) prevents unbounded token growth.

## Worker Protocol

Workers join `"worker:lobby"` with their registration:

```json
{
  "worker_id": "my-worker",
  "tools": [{"name": "search", "description": "...", "input_schema": {...}}],
  "capabilities": ["llm", "tools"]
}
```

Task dispatch uses a provider-neutral format. The worker translates to/from whatever LLM provider it uses (Anthropic, OpenAI, etc).

| Direction | Event | Payload |
|-----------|-------|---------|
| Server → Worker | `llm_task` | model, system_prompt, messages, tools |
| Worker → Server | `tool_result` | task_id, status, content/tool_calls, finish_reason, usage |
| Server → Worker | `tool_task` | task_id, tool_name, input |
| Worker → Server | `tool_result` | task_id, status, result/error |

## Runtime Contracts

### Events

All state is captured as versioned, validated events (`schema_version: 1`). Events are constructed via `Norns.Runtime.Events` which validates payloads before persistence.

- **Lifecycle:** `run_started`, `run_completed`, `run_failed`
- **LLM:** `llm_request`, `llm_response`
- **Tools:** `tool_call`, `tool_result`, `tool_duplicate`
- **Checkpointing:** `checkpoint_saved`
- **Human-in-the-loop:** `waiting_for_user`, `user_response`
- **Retry:** `retry`

### Error Classification

| Class | Example | Retry behavior |
|-------|---------|---------------|
| `transient` | timeout | up to 3 retries, exponential backoff |
| `external_dependency` | rate limit, upstream down | up to 10 retries, linear backoff |
| `validation` | invalid payload | terminal |
| `policy` | policy violation, cancelled | terminal |
| `internal` | unexpected error | terminal |

### Idempotency

Tools marked `side_effect?: true` get deterministic idempotency keys. On replay, the executor checks for an existing result with the same key and skips re-execution.

### Checkpoint / Restore

- `checkpoint_saved` snapshots messages and step
- Replay restores from the latest checkpoint, then replays subsequent events
- Pending tool calls with no result trigger re-dispatch on resume
- Proven by the replay conformance test suite

### Failure Inspector

Failed runs expose `error_class`, `error_code`, `retry_decision`, last checkpoint, and last event — enough to diagnose failures in under 60 seconds.

## Data Model

```
tenants        — name, slug, api_keys
agents         — name, purpose, system_prompt, model, model_config, max_steps, status
conversations  — agent_id, key, messages (jsonb), summary, message_count
runs           — status, trigger_type, input, output, failure_metadata, agent_id, conversation_id
run_events     — sequence, event_type, payload (schema_version: 1), source, metadata, run_id
```

## REST API

```
POST   /api/v1/agents                         — create agent
GET    /api/v1/agents                         — list agents
GET    /api/v1/agents/:id                     — show agent
POST   /api/v1/agents/:id/messages           — send message (returns run_id)
GET    /api/v1/agents/:id/runs               — list runs
GET    /api/v1/agents/:id/conversations      — list conversations
GET    /api/v1/runs/:id                      — run details + failure inspector
GET    /api/v1/runs/:id/events               — event log
```

Auth via `Authorization: Bearer <token>`. Real-time events via WebSocket at `/socket`.

## Supervision Tree

```
Norns.Supervisor
├── Repo (PostgreSQL)
├── PubSub
├── DynamicSupervisor
│   └── Agent processes (state machines)
├── WorkerRegistry (tracks connected workers)
├── TaskQueue (holds tasks for disconnected workers)
└── Phoenix Endpoint (REST, WebSocket, LiveView)
```

## Dashboard

LiveView UI at `/`:
- Agent list with live status
- Agent detail with config editing, message input, live event stream
- Run detail with event timeline, failure inspector, retry/cancel buttons
- Tools view showing worker-provided tools
- Tenant setup on first visit
