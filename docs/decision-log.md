# Decision Log

Last updated: 2026-03-22

## Product Decisions

### Durable agent runtime on BEAM
- Norns is an open-source (MIT), self-hostable, agent-native durable runtime
- The gap: no MIT-licensed, self-hostable, agent-native durable runtime exists. Temporal is MIT but general-purpose and operationally heavy. Everything else is platform-locked or BSL.
- BEAM is the differentiator: OTP supervisors, lightweight processes, built-in distribution, hot code reloading, GenServers as natural agent primitive

### Worker model, not HTTP callbacks
- Norns never calls out to user code via HTTP
- Workers make outbound persistent WebSocket connections to the runtime, register tools, receive tasks
- Like Temporal's activity workers but with persistent connections instead of polling
- Workers execute locally with full access to user's DBs, APIs, secrets
- Self-hosted mode: worker and runtime share the same BEAM VM, tool calls are local function calls

### Three tool layers
- Built-in tools (ship with norns), user-defined tools (via SDK/worker), MCP tools (future)
- From the agent's perspective all tools look identical: name, description, schema, execute
- Durability wraps all tools uniformly: checkpoint before calling, persist result, skip on replay
- Executor transparently handles local vs remote tools via `source` field on Tool struct

### Don't build integrations
- Use managed integration platforms (Nango, Composio) or plain HTTP
- Build zero connectors until the core runtime is proven valuable

### Business model: open core
- Runtime + SDKs are MIT open source
- Norns Cloud is the paid managed offering (dashboard, observability, teams)

---

## Implemented

### Multi-tenancy from day one
- Every table has `tenant_id` (NOT NULL, FK to tenants)
- Agent names unique per tenant
- API keys stored per tenant

### Durable agent GenServer (Phase 1)
- Agents run as GenServers (`Agents.Process`) under a DynamicSupervisor
- LLM-tool loop: call LLM → if tool_use, execute tools → loop; if end_turn, complete
- Every step persisted as a RunEvent BEFORE executing the next step
- State reconstruction from events enables crash recovery
- Orphan recovery on boot resumes interrupted runs

### REST API + WebSocket channels (Phase 2)
- Phoenix REST API: agent CRUD, start/stop, status, messaging, run history
- Bearer token auth matching against tenant api_keys
- Agent WebSocket channel (`/socket`): real-time event streaming via PubSub
- All endpoints scoped to authenticated tenant

### AgentDef + configurable policies (Phase 3)
- `AgentDef` struct: model, system_prompt, tools, checkpoint_policy, max_steps, on_failure
- `AgentDef.from_agent/2` builds from Agent schema, reads policies from model_config
- Checkpoint policies: `:every_step`, `:on_tool_call` (default), `:manual`
- Failure recovery: `:stop` (default) or `:retry_last_step` (exponential backoff, max 3 retries)
- Retry events logged for observability

### Module-based tool definitions (Phase 3)
- `Norns.Tools.Behaviour` with callbacks: `name/0`, `description/0`, `input_schema/0`, `execute/1`
- `use Norns.Tools.Behaviour` macro auto-generates `__tool__/0` returning a `%Tool{}` struct
- ETS-backed `Tools.Registry` for built-in tools, auto-registered on boot
- Backward compatible: `%Tool{}` struct still works for ad-hoc tools

### Worker protocol (Phase 4)
- Worker WebSocket at `/worker` with tenant token auth
- Workers join `"worker:lobby"` with worker_id and tool definitions
- `WorkerRegistry` GenServer tracks connected workers, their tools, and pending tasks
- Server pushes `tool_task` to workers via channel; workers reply with `tool_result`
- `TaskQueue` GenServer holds tasks when no worker available, flushes on reconnect
- Stale task sweep with configurable timeout
- Worker disconnect detected via process monitoring; cleanup automatic

### Remote tool execution (Phase 4)
- `Tool` struct has `source: :local | {:remote, tenant_id}` field
- `Executor` transparently dispatches to `WorkerRegistry` for remote tools
- Agent process blocks on `await_result/2` while worker executes
- From the agent's perspective, local and remote tools are identical

### LLM module with swappable backends
- `Norns.LLM` dispatches to configured backend via behaviour
- `Norns.LLM.Anthropic` — multi-turn Messages API with tool use support
- `Norns.LLM.Fake` — ETS-backed scripted responses for tests

### Event-sourced run audit trail
- Every step logged as a `RunEvent` with sequence, event_type, payload
- Unique constraint on (run_id, sequence)
- Event types: agent_started, llm_request, llm_response, tool_call, tool_result, checkpoint, retry, agent_completed, agent_error

### Docker Compose for all dev tooling
- No local Elixir install. `Dockerfile.dev` + app service in docker-compose

### Error taxonomy
- Four error categories:
  1. **Transient** (network, rate limits) → automatic retry with backoff (via on_failure policy)
  2. **LLM-recoverable** (bad tool call, parse failure) → feed error back to the LLM
  3. **User-fixable** (missing info, needs approval) → interrupt/resume (future)
  4. **Unexpected** → bubble up, mark run as failed

---

## Open

### A) SDK design (Phase 5)
- TypeScript and Python SDKs
- Developers define agents and tools in their language
- SDK talks to Norns runtime over the REST/WS API
- Worker SDK wraps the WebSocket connection and tool registration protocol

### B) LLM provider abstraction
- Currently Anthropic-only via behaviour pattern
- Add OpenAI implementation when needed

### C) Checkpoint storage at scale
- Currently inline as event_type="checkpoint" in run_events
- Separate `checkpoints` table may be needed when payloads get large

### D) Multi-node distribution
- Current Registry + DynamicSupervisor are single-node
- Port to Horde for multi-node when clustering is needed
- PubSub already supports distributed Erlang or Redis backend
