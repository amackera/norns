# Architecture

## What Is This

Norns is an open-source (MIT), Elixir/BEAM-based durable agent runtime. Developers define AI agents that survive crashes, restarts, and infrastructure failures by checkpointing every LLM call and tool execution. Think Temporal, but purpose-built for AI agents and running on the Erlang VM.

## Why BEAM

BEAM provides properties that no other durable agent runtime has:

- **OTP supervisors** are native durable process managers. "Let it crash" is the original durable execution philosophy.
- **Lightweight processes** mean thousands of concurrent agents per node, each with isolated state.
- **Built-in distribution** enables agent migration across nodes and free clustering (future phase).
- **Hot code reloading** allows updating agent logic without stopping running agents.
- **GenServers** are a natural primitive for stateful, long-lived agent processes.

Every competitor (Temporal, Restate, Inngest, Cloudflare, Vercel) is built on Go, Rust, JS, or JVM. Nobody is building on BEAM.

## Core Primitive

Each agent is a GenServer managed by a DynamicSupervisor, configured by an `AgentDef` struct:

```elixir
%AgentDef{
  model: "claude-sonnet-4-20250514",
  system_prompt: "You are a research assistant...",
  tools: [MyTools.WebSearch, MyTools.WriteDoc],
  checkpoint_policy: :on_tool_call,
  max_steps: 50,
  on_failure: :retry_last_step
}
```

The agent process runs the core loop:

```
receive message → call LLM → if tool call, execute tool → checkpoint → repeat
```

State is persisted to Postgres at each checkpoint as an event log. On restart, the process replays events rather than re-executing LLM calls.

## Process Model (Temporal-style Workers)

Norns never calls out to user code via HTTP. Instead, workers pull tasks — like Temporal's activity workers, but using persistent connections instead of polling.

```
Norns Runtime (BEAM)                     User's Infrastructure
  │                                         │
  Agent GenServer                           Norns Worker
  │  runs LLM loop                          │  connects via WebSocket /worker
  │  checkpoints state                      │  registers available tools
  │  hits tool call                         │  waits for tasks
  │    ↓                                    │
  │  puts task on queue ─── persistent ───► │  receives tool_task push
  │                         connection      │  executes locally
  │                                         │  (full access to user's DBs,
  │  ◄── tool_result ─────────────────────  │   APIs, secrets)
  │                                         │
  │  checkpoint result                      │
  │  continue LLM loop                     │
```

Key properties:
- **Workers make outbound connections only** — works behind firewalls/NATs, no public endpoints needed
- **Norns never touches user data** — it orchestrates; workers execute
- **If a worker disconnects**, TaskQueue holds pending tasks and resumes when it reconnects
- **Self-hosted mode**: worker and runtime share the same BEAM VM, tool calls are local function calls with no network hop

### Worker Protocol

Workers connect to `/worker` WebSocket, authenticated via tenant API key.

| Direction | Event | Payload |
|-----------|-------|---------|
| Worker → Server | join `"worker:lobby"` | `{worker_id, tools: [{name, description, input_schema}]}` |
| Server → Worker | push `"tool_task"` | `{task_id, tool_name, input, agent_id, run_id}` |
| Worker → Server | `"tool_result"` | `{task_id, status: "ok"/"error", result/error}` |

`WorkerRegistry` (GenServer) tracks connected workers, dispatches tasks, routes results. `TaskQueue` (GenServer) holds tasks when no worker is available, flushes on reconnect, sweeps stale tasks with timeout.

## Tool System

From the agent's perspective, all tools look identical. The `Executor` transparently handles both local and remote tools.

### Tool Definition

Tools are modules implementing `Norns.Tools.Behaviour`:

```elixir
defmodule MyTools.LookupCustomer do
  use Norns.Tools.Behaviour

  def name, do: "lookup_customer"
  def description, do: "Look up a customer by email"
  def input_schema, do: %{"type" => "object", "properties" => %{"email" => %{"type" => "string"}}}

  def execute(%{"email" => email}) do
    {:ok, "Customer: #{email}"}
  end
end
```

### Three Sources of Tools

1. **Built-in tools** — ship with norns, registered in `Tools.Registry` (ETS) on boot. Currently: WebSearch (stub).
2. **User-defined tools** — registered via workers over WebSocket. Tracked in `WorkerRegistry`. Represented as `%Tool{source: {:remote, tenant_id}}`.
3. **MCP tools** (future) — norns connects to external MCP servers as a client, discovers tools automatically.

### Execution Path

`Tools.Executor.execute/2` checks the tool's `source` field:
- `:local` → calls the handler function directly
- `{:remote, tenant_id}` → dispatches via `WorkerRegistry`, blocks on `await_result/2`

## API Surface

### REST API (`/api/v1`)

Authenticated via `Authorization: Bearer <token>` matched against tenant `api_keys`.

```
POST   /api/v1/agents              — create agent
GET    /api/v1/agents              — list agents
GET    /api/v1/agents/:id          — show agent
POST   /api/v1/agents/:id/start   — spawn GenServer
DELETE /api/v1/agents/:id/stop    — stop GenServer
GET    /api/v1/agents/:id/status  — process state
POST   /api/v1/agents/:id/messages — send message (202)
GET    /api/v1/agents/:id/runs    — run history
GET    /api/v1/runs/:id           — run details
GET    /api/v1/runs/:id/events    — event log
```

### WebSocket Channels

Two socket endpoints:

- **`/socket`** (AgentSocket) — clients join `"agent:<id>"` to receive real-time agent events (llm_response, tool_call, tool_result, completed, error). Can also send messages via channel.
- **`/worker`** (WorkerSocket) — workers join `"worker:lobby"` with tool registrations, receive `tool_task` pushes, send `tool_result` replies.

PubSub connects agent processes to channels. Agent processes publish events, channels subscribe and forward.

## Data Model

Event-sourced persistence in Postgres via Ecto.

Core tables:
- `tenants` — name, slug, api_keys (multi-tenancy enforced at schema level)
- `agents` — name, purpose, system_prompt, model, model_config, tools_config, max_steps, status
- `runs` — status, trigger_type, input, output, agent_id, tenant_id
- `run_events` — sequence, event_type, payload, source, metadata, run_id, tenant_id

Event types: `agent_started`, `llm_request`, `llm_response`, `tool_call`, `tool_result`, `checkpoint`, `retry`, `agent_completed`, `agent_error`

On restart: find last checkpoint event, replay events since that checkpoint.

## Agent Configuration

`AgentDef` struct configures agent behavior:

- **`checkpoint_policy`**: `:every_step` (after every LLM call), `:on_tool_call` (after tool execution, default), `:manual` (no automatic checkpoints)
- **`on_failure`**: `:stop` (default, mark run as failed) or `:retry_last_step` (exponential backoff, max 3 retries)
- **`max_steps`**: safety limit on LLM-tool loop iterations (default 50)

`AgentDef.from_agent/2` builds from an Agent schema record. Checkpoint and failure policies read from `model_config` map.

## Crash Recovery

State reconstruction from the event log:
1. Find the last `checkpoint` event (full message snapshot)
2. Replay events after the checkpoint to rebuild message history
3. Resume the LLM-tool loop from where it left off

On boot, `Workers.ResumeAgents` finds runs with status "running" and no live process, and resumes them.

## Supervision Tree

```
Norns.Supervisor (one_for_one)
├── Norns.Repo (Ecto/PostgreSQL)
├── Oban (background jobs)
├── Phoenix.PubSub (Norns.PubSub)
├── Registry (Norns.AgentRegistry, unique keys)
├── DynamicSupervisor (Norns.AgentSupervisor)
│   └── [Agents.Process] (spawned dynamically per agent)
├── Workers.WorkerRegistry (tracks connected workers)
├── Workers.TaskQueue (pending tasks for disconnected workers)
├── NornsWeb.Telemetry
└── NornsWeb.Endpoint (Phoenix — REST + WebSocket)
```

On boot: init tool registry, register built-in tools, resume orphaned runs.

## Build Phases

### Phase 1: Core Primitive ✓
Durable agent GenServer, event-sourced persistence, crash recovery, orphan recovery.

### Phase 2: API + Transport ✓
Phoenix REST API for lifecycle management. WebSocket channels for real-time streaming. Bearer token auth.

### Phase 3: Generic Agent Definitions ✓
`AgentDef` struct with configurable checkpoint policies and failure recovery. Module-based tool definitions via `use Norns.Tools.Behaviour`. ETS-backed tool registry.

### Phase 4: Worker Protocol ✓
Worker WebSocket at `/worker`. Tool registration on join. Task dispatch and result collection via `WorkerRegistry`. `TaskQueue` for pending tasks. Reconnection handling.

### Phase 5: TypeScript/Python SDKs
Developers define agents and tools in their language, SDK talks to Norns runtime over the API. BEAM is the engine, not the interface.

### Skip For Now
- Multi-node clustering
- MCP tool integration
- Agent builder / chat UI
- Dashboard / observability UI
- Auth, teams, billing
- LLM streaming

## Business Model

- **Norns Runtime** (open source, MIT) — the durable agent execution engine
- **Norns SDKs** (open source, MIT) — define agents in TypeScript/Python
- **Norns Cloud** (hosted, paid) — managed runtime, dashboard, observability, team features

## Integrations

Norns is complementary to real-time media platforms like LiveKit. Norns owns the reasoning/durability plane; LiveKit owns the audio/video plane. A LiveKit agent worker acts as a thin voice I/O adapter that forwards transcripts to a Norns agent and streams responses back through TTS. The Norns agent maintains full context across calls, disconnections, and multi-hour waits.

Same pattern applies to other transports: Slack adapter, Twilio SMS adapter, web chat — all pointing at the same durable agent process.
