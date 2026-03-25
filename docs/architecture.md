# Architecture

## What Is This

Norns is an open-source (MIT), Elixir/BEAM-based durable agent runtime. Developers define AI agents that survive crashes, restarts, and infrastructure failures by checkpointing every LLM call and tool execution.

Current scope is intentionally tight: Norns is a **reliable execution layer** (durability, retries, idempotency, inspectability), not a broad agent platform.

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
  mode: :conversation,
  context_strategy: :sliding_window,
  context_window: 20,
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

## Agent Modes

### Task Mode (default)
Each `send_message` starts a fresh run. No conversation history between runs. Good for one-shot queries and fire-and-forget tasks.

### Conversation Mode
Messages append to a persistent conversation. The LLM sees full history from previous runs. Conversations are identified by an external key (e.g., Slack channel ID) so one agent can handle multiple concurrent conversations.

Registry key: `{tenant_id, agent_id, conversation_key}` — a product expert bot tagged in #engineering, #support, and a DM simultaneously gets three independent GenServer processes with separate conversation state.

Context management prevents unbounded token growth:
- **Sliding window** (default): keep the last N messages, discard older ones
- Conversation summary (if present) prepended to the system prompt for historical context

## Agent Memory

Agents have persistent key-value memory shared across all conversations. When the agent learns something in #engineering, it can recall it in #product.

Backed by the `memories` table scoped to `agent_id`. Two built-in tools:
- **`store_memory`** — the agent decides what's worth remembering (upserts by key)
- **`search_memory`** — keyword search across memory keys and content

The LLM decides what to store and when to search — this mirrors how humans take notes.

## Human-in-the-Loop

The `ask_user` tool enables interrupt/resume. When the LLM needs clarification:

1. LLM returns `tool_use` calling `ask_user` with a question
2. Agent logs the question, sets run status to `"waiting"`, broadcasts via PubSub
3. Agent process parks itself — no more LLM calls until the user responds
4. User sends a response via API/UI/WebSocket
5. Response is delivered as a `tool_result`, agent resumes the LLM loop

Fully durable: if the process crashes while waiting, it resumes to waiting state from the event log.

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
- **Workers make outbound connections only** — works behind firewalls/NATs
- **Norns never touches user data** — it orchestrates; workers execute
- **If a worker disconnects**, TaskQueue holds pending tasks and flushes on reconnect
- **Self-hosted mode**: worker and runtime share the same BEAM VM, tool calls are local function calls

## Tool System

From the agent's perspective, all tools look identical. The `Executor` transparently handles both local and remote tools.

### Built-in Tools

| Tool | Description |
|------|-------------|
| `web_search` | DuckDuckGo search, returns top 5 results with titles/URLs/snippets |
| `http_request` | GET/POST via Req, HTML stripped to text, body truncated |
| `shell` | Execute allowlisted shell commands with timeout |
| `ask_user` | Pause agent, surface question, wait for human response |
| `store_memory` | Save a fact to persistent agent memory (upsert by key) |
| `search_memory` | Keyword search across agent memory |

### Three Sources of Tools

1. **Built-in tools** — ship with norns, registered in `Tools.Registry` (ETS) on boot
2. **User-defined tools** — registered via workers over WebSocket. Tracked in `WorkerRegistry`. Represented as `%Tool{source: {:remote, tenant_id}}`
3. **MCP tools** (future) — norns connects to external MCP servers as a client

### Tool Definition

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

## API Surface

### REST API (`/api/v1`)

Authenticated via `Authorization: Bearer <token>` matched against tenant `api_keys`.

```
POST   /api/v1/agents                         — create agent
GET    /api/v1/agents                         — list agents
GET    /api/v1/agents/:id                     — show agent
POST   /api/v1/agents/:id/start              — spawn GenServer
DELETE /api/v1/agents/:id/stop               — stop GenServer
GET    /api/v1/agents/:id/status             — process state
POST   /api/v1/agents/:id/messages           — send message (auto-starts, optional conversation_key)
GET    /api/v1/agents/:id/runs               — run history
GET    /api/v1/agents/:id/conversations      — list conversations
GET    /api/v1/agents/:id/conversations/:key — show conversation
DELETE /api/v1/agents/:id/conversations/:key — delete conversation
GET    /api/v1/runs/:id                      — run details
GET    /api/v1/runs/:id/events               — event log
```

### WebSocket Channels

Three socket endpoints:

- **`/socket`** (AgentSocket) — clients join `"agent:<id>"` for real-time events. Can also send messages.
- **`/worker`** (WorkerSocket) — workers join `"worker:lobby"` with tool registrations
- **`/live`** (LiveView) — dashboard WebSocket

### LiveView Dashboard

- `/` — agents list with live status badges, create agent form
- `/agents/:id` — agent detail, message input, live event stream, run history
- `/runs/:id` — run timeline with color-coded events
- `/tools` — built-in and worker-provided tools
- `/setup` — tenant creation (first visit)

## Data Model

Event-sourced persistence in Postgres via Ecto.

```
tenants        — name, slug, api_keys
agents         — name, purpose, system_prompt, model, model_config, max_steps, status
conversations  — agent_id, key, messages (jsonb), summary, message_count, token_estimate
memories       — agent_id, key (unique per agent), content, metadata
runs           — status, trigger_type, input, output, agent_id, conversation_id
run_events     — sequence, event_type, payload, source, metadata, run_id
```

Event types: `agent_started`, `llm_request`, `llm_response`, `tool_call`, `tool_result`, `checkpoint`, `retry`, `waiting_for_user`, `user_response`, `agent_completed`, `agent_error`

## Crash Recovery

1. Find the last `checkpoint` event (full message snapshot)
2. Replay events after the checkpoint to rebuild message history
3. For conversation mode: load persisted conversation as the base, then replay run events on top
4. Resume the LLM-tool loop from where it left off (or resume to waiting state if interrupted)

On boot, `Workers.ResumeAgents` finds runs with status `"running"` and no live process, and resumes them with the correct conversation key.

## Supervision Tree

```
Norns.Supervisor (one_for_one)
├── Norns.Repo (Ecto/PostgreSQL)
├── Oban (background jobs)
├── Phoenix.PubSub (Norns.PubSub)
├── Registry (Norns.AgentRegistry, keys: {tenant_id, agent_id, conversation_key})
├── DynamicSupervisor (Norns.AgentSupervisor)
│   └── [Agents.Process] (one per agent conversation)
├── Workers.WorkerRegistry (tracks connected workers)
├── Workers.TaskQueue (pending tasks for disconnected workers)
├── NornsWeb.Telemetry
└── NornsWeb.Endpoint (Phoenix — REST + WebSocket + LiveView)
```

On boot: init tool registry, register built-in tools (including memory tools), resume orphaned runs.

## Build Phases

### Phase 1: Core Primitive ✓
Durable agent GenServer, event-sourced persistence, crash recovery, orphan recovery.

### Phase 2: API + Transport ✓
Phoenix REST API, WebSocket channels, bearer token auth.

### Phase 3: Agent Definitions ✓
AgentDef struct, module-based tools, tool registry, checkpoint policies, failure recovery with retry.

### Phase 4: Worker Protocol ✓
Worker WebSocket, tool registration, task dispatch, TaskQueue for disconnected workers.

### Phase 5: Conversations + Memory ✓
Task vs conversation mode, sliding window context, persistent agent memory, `ask_user` interrupt/resume.

### Phase 6: Dashboard ✓
LiveView UI, tenant setup, agent creation, live event streaming, run timeline.

### Phase 7: SDKs
TypeScript/Python clients for defining agents and tools in other languages.

### Skip For Now
- Multi-node clustering (port Registry to Horde)
- MCP tool integration
- LLM streaming
- Vector memory (pgvector)

## Business Model

- **Norns Runtime** (open source, MIT) — self-hosted durable agent framework
- **Norns SDKs** (open source, MIT) — define agents in TypeScript/Python
- **Norns Cloud** (hosted, paid) — managed runtime, dashboard, observability

Self-hosted first. The framework builds trust and adoption. The cloud offering monetizes convenience.

## Integrations

Norns is complementary to real-time media platforms like LiveKit. Norns owns the reasoning/durability plane; LiveKit owns the audio/video plane. Same pattern applies to Slack, Twilio, web chat — thin transport adapters pointing at the same durable agent process.
