# Norns

## Project Overview

Open-source (MIT) durable agent runtime on BEAM. Infrastructure for running LLM-powered agents that survive crashes, restarts, and infrastructure failures by checkpointing every LLM call and tool execution. Think Temporal, but purpose-built for AI agents and running on the Erlang VM.

Product surface: REST API + WebSocket streaming + LiveView dashboard + SDKs.

## Tech Stack

- **Language:** Elixir on BEAM/OTP
- **Web Framework:** Phoenix (REST + Channels + LiveView)
- **Database:** PostgreSQL via Ecto
- **Background Jobs:** Oban
- **LLM:** Anthropic Messages API via Req (multi-turn + tool use, swappable via behaviour)
- **Dev Environment:** Docker Compose (all mix commands run in containers)
- **License:** MIT

## Running Commands

All Elixir/mix commands must run through docker compose:

```bash
docker compose run --rm -e POSTGRES_HOST=db app mix test
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.migrate
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

## Project Structure

```
lib/norns/
  tenants/          — Tenant schema + context (multi-tenancy)
  agents/           — Agent, AgentDef, Process (GenServer), Registry
  conversations/    — Conversation schema + context (persistent chat history)
  memories/         — Memory schema + context (cross-conversation knowledge)
  runs/             — Run + RunEvent schemas, Runs context (event log)
  workers/          — ResumeAgents, WorkerRegistry, TaskQueue, RunAgent (Oban)
  llm.ex            — LLM dispatcher
  llm/              — Behaviour, Anthropic adapter, Fake (test double)
  tools/            — Behaviour, Tool struct, Executor, Registry, built-in tools

lib/norns_web/
  endpoint.ex       — Phoenix endpoint (REST + WebSocket + LiveView)
  router.ex         — API routes + LiveView routes
  plugs/            — Auth (API bearer token), SessionAuth (browser cookies)
  controllers/      — AgentController, RunController, ConversationController
  channels/         — AgentSocket/Channel (streaming), WorkerSocket/Channel (tool dispatch)
  live/             — AgentsLive, AgentLive, RunLive, ToolsLive, SetupLive
  components/       — Layouts (root + app)
  json.ex           — Serialization helpers
```

## Conventions

- Follow standard Phoenix project conventions
- Keep contexts (Ecto schemas + business logic) in `lib/norns/`
- Keep web layer (controllers, channels, plugs, live views) in `lib/norns_web/`
- Define tools as modules with `use Norns.Tools.Behaviour`
- Minimal, clean code — avoid over-engineering
- Every table has `tenant_id` — multi-tenancy is enforced at the data model level

## Architecture Notes

### Agent Configuration
- Agents are configured via `AgentDef` struct: model, tools, mode, checkpoint_policy, on_failure, max_steps
- Two modes: `:task` (stateless, each message starts fresh) and `:conversation` (persistent context across messages)
- Conversation mode uses sliding window context management (configurable window size)

### Execution
- Agents run as GenServers (`Agents.Process`) under a DynamicSupervisor
- Registry key: `{tenant_id, agent_id, conversation_key}` — supports multiple concurrent conversations per agent
- Core loop: receive message → call LLM → if tool call, execute tool → checkpoint → repeat
- Every step persisted as a RunEvent BEFORE executing the next step (durability)
- State reconstruction from events enables crash recovery (replay from last checkpoint)
- `send_message` auto-starts the agent process if not already running

### Tools
- Built-in: `web_search` (DuckDuckGo), `http_request`, `shell`, `ask_user`, `store_memory`, `search_memory`
- Tools can be local (function call) or remote (dispatched to connected worker via WebSocket)
- `ask_user` pauses the agent and waits for human input (interrupt/resume)
- `store_memory` / `search_memory` provide cross-conversation knowledge persistence

### Policies
- Checkpoint policies: `:every_step`, `:on_tool_call`, `:manual`
- Failure recovery: `:stop` or `:retry_last_step` (exponential backoff; rate limits get 15s+ delays)
- Context strategy: `:sliding_window` (default, last N messages) or `:none`

### Infrastructure
- Workers connect to `/worker` WebSocket, register tools, receive task pushes
- `WorkerRegistry` tracks connected workers; `TaskQueue` holds tasks when no worker available
- Orphan recovery on boot resumes interrupted runs
- PubSub broadcasts agent events → WebSocket channels + LiveView forward to clients

### Web UI
- LiveView dashboard at `/` — agents list, agent detail, run timeline, tools view
- Session auth: first visit to `/setup` creates tenant + API key
- Agent creation form in UI; start/stop/message controls
- Real-time event streaming via PubSub subscriptions in LiveView

## Build Phases

1. **Core Primitive** ✓ — durable agent GenServer, event sourcing, crash recovery
2. **API + Transport** ✓ — Phoenix REST API + WebSocket channels
3. **Agent Definitions** ✓ — AgentDef, module-based tools, tool registry, checkpoint policies, retry
4. **Worker Protocol** ✓ — persistent WebSocket connections, remote tool execution, task queue
5. **Conversations + Memory** ✓ — task vs conversation mode, sliding window context, cross-conversation memory
6. **Dashboard** ✓ — LiveView UI, tenant setup, agent management
7. **SDKs** — TypeScript/Python clients
