# Decision Log

Last updated: 2026-03-29

## Product Decisions

### Pure orchestrator — no execution
- Norns is a state machine and event log. It never makes LLM calls or executes tools.
- All execution happens on workers. You need a connected worker to do anything.
- No built-in tools, no DefaultWorker, no memory layer. These belong in the SDK / user code.
- The orchestrator's job: dispatch tasks, persist events, manage state, crash recovery.

### Workers own everything
- Workers hold API keys, database credentials, tool implementations.
- Workers connect outbound via WebSocket — works behind firewalls, no public endpoints needed.
- Norns never sees user data or secrets.
- Provider-neutral LLM format — the worker translates to/from whatever API it uses.

### Inspired by Temporal
- Worker/client split matches Temporal's model.
- Orchestrator manages workflow state, workers execute activities.
- Built for AI agents specifically — conversations, tool dispatch, LLM checkpointing.

### Multi-tenancy
- Every table has `tenant_id` (NOT NULL, FK).
- Agent names unique per tenant.
- API keys per tenant.
- Workers scoped to tenant.

---

## Implemented

### Durable agent process
- Agents run as GenServers under DynamicSupervisor.
- States: idle → awaiting_llm → awaiting_tools → idle (or waiting for human input).
- Every step persisted as a RunEvent before the next step executes.
- State reconstruction from event log on crash recovery.
- Orphan recovery on boot resumes interrupted runs.

### Orchestrator/worker split
- Agent process dispatches all work via WorkerRegistry.
- LLM tasks: `dispatch_llm_task` → worker calls LLM API → returns neutral response.
- Tool tasks: `dispatch_task` → worker executes function → returns result.
- Agent is never blocked — always responds to status queries, stop, messages.
- TaskQueue holds tasks when no worker is connected, flushes on reconnect.

### Provider-neutral LLM format
- Tool calls: separate `tool_calls` array with `arguments`, not Anthropic content blocks.
- Tool results: `role: "tool"` messages with `tool_call_id`, not content blocks in user messages.
- `finish_reason`: `stop` / `tool_call` / `length` — not Anthropic-specific values.
- `Norns.LLM.Format` translates neutral ↔ Anthropic at the worker boundary.

### Conversations
- Task mode (default): each message starts fresh.
- Conversation mode: persistent history across runs, identified by external key.
- Sliding window context management.
- Multiple concurrent conversations per agent.

### Runtime contracts
- All events versioned (`schema_version: 1`) and validated before persistence.
- 5-class error taxonomy with deterministic retry policy.
- Idempotent side effects via deterministic keys.
- Failure inspector: error_class, error_code, retry_decision, last checkpoint/event.
- Replay conformance test suite.

### API + Dashboard
- REST API with bearer token auth, returns run_id from send_message.
- WebSocket channels for real-time events and worker connections.
- LiveView dashboard: agent list, agent detail with config editing, run timeline with event details, cancel/retry buttons.

### SDKs
- Python SDK: worker (`Norns`) + client (`NornsClient`). 29 tests.
- Elixir SDK: worker (`NornsSdk.Worker`) + client (`NornsSdk.Client`). 10 tests.

---

## Open

### SDK maturity
- Python SDK needs end-to-end integration test against running Norns.
- Elixir SDK needs the same.
- Neither published to PyPI/Hex yet.

### Multi-node
- Registry + DynamicSupervisor are single-node.
- Port to Horde when clustering is needed.

### Policy enforcement
- Pre-dispatch hook point in the orchestrator (not built, architecture supports it).
- Rule-based (orchestrator evaluates) and LLM-evaluated (worker evaluates) flavors.

### Multi-agent orchestration
- Agents as tools pattern (supervisor agent calls sub-agents).
- `parent_run_id` for run lineage tracking (not built).
