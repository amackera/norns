# Norns

## Project Overview

Open-source (MIT) durable agent runtime on BEAM. The orchestrator is a pure state machine — it dispatches tasks to workers and persists events, but never executes LLM calls or tools directly.

## Tech Stack

- **Language:** Elixir on BEAM/OTP
- **Web Framework:** Phoenix (REST + Channels + LiveView)
- **Database:** PostgreSQL via Ecto
- **Background Jobs:** Oban
- **Dev Environment:** Docker Compose (all mix commands run in containers)
- **License:** MIT

## Running Commands

```bash
docker compose run --rm -e POSTGRES_HOST=db app mix test
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.migrate
docker compose run --rm -e MIX_ENV=test -e POSTGRES_HOST=db app mix test
```

## Project Structure

```
lib/norns/
  tenants/          — Tenant schema + context (multi-tenancy)
  agents/           — Agent, AgentDef, Process (state machine), Registry
  conversations/    — Conversation schema + context (persistent chat history)
  runs/             — Run + RunEvent schemas, Runs context (event log)
  runtime/          — Event contracts, error taxonomy, retry policy
  workers/          — WorkerRegistry, TaskQueue, ResumeAgents
  llm.ex            — LLM dispatcher (used by workers via Fake in tests)
  llm/              — Behaviour, Anthropic adapter, Format (neutral ↔ Anthropic), Fake
  tools/            — Behaviour, Tool struct, Executor, Registry, Idempotency

lib/norns_web/
  endpoint.ex       — Phoenix endpoint (REST + WebSocket + LiveView)
  router.ex         — API routes + LiveView routes
  plugs/            — Auth (API bearer token), SessionAuth (browser cookies)
  controllers/      — AgentController, RunController, ConversationController
  channels/         — AgentSocket/Channel (streaming), WorkerSocket/Channel (task dispatch)
  live/             — AgentsLive, AgentLive, RunLive, ToolsLive, SetupLive
  components/       — Layouts (root + app)
  json.ex           — Serialization helpers
```

## Conventions

- The orchestrator NEVER executes anything — all work goes through connected workers
- No built-in tools — tools are defined and registered by workers
- Follow standard Phoenix project conventions
- Keep contexts in `lib/norns/`, web layer in `lib/norns_web/`
- Every table has `tenant_id` — multi-tenancy enforced at the data model level
- Provider-neutral LLM format on the wire — workers translate to their LLM provider

## Architecture

- **Agent process** is a pure state machine (GenServer): dispatches tasks, receives results, persists events
- **States:** `:idle`, `:awaiting_llm`, `:awaiting_tools`, `:waiting` (human input)
- **Workers** connect via `/worker` WebSocket, register capabilities `[:llm, :tools]`, receive task pushes
- **Conversations:** task mode (stateless) or conversation mode (persistent, keyed by external ID)
- **Events:** versioned (`schema_version: 1`), validated, provider-neutral format
- **Crash recovery:** replay from last checkpoint, re-dispatch pending tools
- **Idempotency:** deterministic keys for side-effecting tools, skip on replay
