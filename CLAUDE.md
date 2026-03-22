# Norns

## Project Overview

Open-source (MIT) durable agent runtime on BEAM. Infrastructure for running LLM-powered agents that survive crashes, restarts, and infrastructure failures by checkpointing every LLM call and tool execution. Think Temporal, but purpose-built for AI agents and running on the Erlang VM.

Product surface: REST API + WebSocket streaming + SDKs. No UI.

## Tech Stack

- **Language:** Elixir on BEAM/OTP
- **Web Framework:** Phoenix (REST + Channels)
- **Database:** PostgreSQL via Ecto
- **Background Jobs:** Oban
- **LLM:** Anthropic Messages API via Req (multi-turn + tool use, swappable via behaviour)
- **Dev Environment:** Docker Compose (all mix commands run in containers)
- **License:** MIT

## Running Commands

All Elixir/mix commands must run through docker compose:

```bash
docker compose run --rm app mix test
docker compose run --rm app mix ecto.migrate
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

## Project Structure

```
lib/norns/
  tenants/          — Tenant schema + context (multi-tenancy)
  agents/           — Agent, AgentDef, Process (GenServer), Registry
  runs/             — Run + RunEvent schemas, Runs context (event log)
  workers/          — ResumeAgents, WorkerRegistry, TaskQueue, RunAgent (Oban)
  llm.ex            — LLM dispatcher
  llm/              — Behaviour, Anthropic adapter, Fake (test double)
  tools/            — Behaviour, Tool struct, Executor, Registry, WebSearch

lib/norns_web/
  endpoint.ex       — Phoenix endpoint (REST + two WebSocket mounts)
  router.ex         — API routes under /api/v1
  plugs/auth.ex     — Bearer token auth
  controllers/      — AgentController, RunController
  channels/         — AgentSocket/Channel (streaming), WorkerSocket/Channel (tool dispatch)
  json.ex           — Serialization helpers
```

## Conventions

- Follow standard Phoenix project conventions
- Keep contexts (Ecto schemas + business logic) in `lib/norns/`
- Keep web layer (controllers, channels, plugs) in `lib/norns_web/`
- Define tools as modules with `use Norns.Tools.Behaviour`
- Minimal, clean code — avoid over-engineering
- Every table has `tenant_id` — multi-tenancy is enforced at the data model level

## Architecture Notes

- Agents are configured via `AgentDef` struct: model, tools, checkpoint_policy, on_failure, max_steps
- Agents run as GenServers (`Agents.Process`) under a DynamicSupervisor
- Core loop: receive message → call LLM → if tool call, execute tool → checkpoint → repeat
- Every step persisted as a RunEvent BEFORE executing the next step (durability)
- State reconstruction from events enables crash recovery (replay from last checkpoint)
- Checkpoint policies: `:every_step`, `:on_tool_call`, `:manual`
- Failure recovery: `:stop` or `:retry_last_step` (exponential backoff, max 3 retries)
- Tools can be local (function call) or remote (dispatched to connected worker via WebSocket)
- Workers connect to `/worker` WebSocket, register tools, receive task pushes
- `WorkerRegistry` tracks connected workers; `TaskQueue` holds tasks when no worker available
- Orphan recovery on boot resumes interrupted runs
- PubSub broadcasts agent events → WebSocket channels forward to clients

## Build Phases

1. **Core Primitive** ✓ — durable agent GenServer, event sourcing, crash recovery
2. **API + Transport** ✓ — Phoenix REST API + WebSocket channels
3. **Agent Definitions** ✓ — AgentDef, module-based tools, tool registry, checkpoint policies, retry
4. **Worker Protocol** ✓ — persistent WebSocket connections, remote tool execution, task queue
5. **SDKs** — TypeScript/Python clients
