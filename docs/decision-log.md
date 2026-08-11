# Decision Log

Last updated: 2026-08-10

## Product Decisions

### Pure orchestrator — no execution
- Norns is a state machine and event log. It never makes LLM calls or executes tools.
- All execution happens on workers. You need a connected worker to do anything.
- Built-in tools (wait, ask_human, launch_agent, list_agents) are intercepted by the orchestrator, never sent to workers. All other tools are worker-provided.
- The orchestrator's job: dispatch tasks, persist events, manage state, crash recovery.
- Purity means the orchestrator never touches the outside world — no credentials, no user data, no third-party APIs. Reading/writing the runtime's own state (runs, defs, events) does not break it; holding a Slack token would.

### Tools are infrastructure, agents are configuration
- Workers are the tenant's long-lived capability layer (the Slack worker, the DB worker), maintained like services.
- Agents are cheap, disposable data: prompt + model + tool selection + triggers, created and tested entirely through the API.
- The agent builder composes existing tools by default and only falls back to generating worker code (from templates) when a capability is missing. See `plan-agent-builder.md`.

### Triggers are Norns data
- Cron schedules and inbound webhook mappings live in Norns tables, managed via API — not in worker repos. Composed agents have no repo.
- Connector workers (Slack, Discord — anything needing credentials or a persistent connection) stay outside core. The line: if it speaks HTTP to us, core can receive it; if we must hold credentials or a connection, it's a connector.

### The fork: own the provisioner (decided 2026-08-08)
- We sell compute (managed gards), not just durability semantics. Fabricated workers need somewhere durable to run; that somewhere is ours to operate.
- The orchestrator stays pure — the provisioner is a separate product, per `gards.md`.
- Durable MCP → custom workflows is parked, not dead.

### The cloud boundary (decided 2026-08-10)
- The builder is an agent — it makes LLM calls and runs a loop — which is exactly what the orchestrator must never do. It cannot live in core without breaking purity. Structurally it is a client of the API: read the tool catalog, write defs, send test messages, read events.
- Open-core split: **core (OSS)** is the runtime plus the primitives — tool selection, triggers, webhooks, tool catalog, gard registry. Each is independently useful; none is builder-only. **Cloud** is the builder (run as an agent on Norns with a cloud-operated worker), the provisioner, managed gards, and managed connectors.
- Cloud sells "you don't run anything," not withheld features.
- **Managed connectors are the provisioner's first product.** A connector worker needs none of the hard parts of the coding-agent workload — no snapshots, no tunnels (Socket Mode is outbound), no code extraction. It is "run this container with these env vars, restart it if it dies": the provisioner's minimum viable form, answering a pain that exists before any builder does. Coding-agent gards come after.

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
- Python SDK: worker (`Norns`) + client (`NornsClient`). Published to PyPI.
- Elixir SDK: worker (`NornsSdk.Worker`) + client (`NornsSdk.Client`). Published to Hex.

### Multi-agent orchestration
- Built-in `launch_agent` and `list_agents` tools.
- Child agents launched via PubSub, tracked in `pending_subagents` (keyed by child run id).
- `subagent_launched` event type with replay support.
- Agents can discover and delegate to other agents within the same tenant.
- Run lineage: `parent_run_id` + `depth`, `max_depth` recursion bound (not a cost control).

### Human in the loop
- Built-in `ask_human` parks the run durably in `:waiting`; `POST /runs/:id/reply` (or `reply_to_human`) resumes it.
- `waiting_for_user` event + broadcast lets any surface (dashboard, connector, client SDK `wait=True`) relay the question and the answer.

### Subagent allowlists
- `Norns.Agents.SubagentPolicy` — per-agent authorization for `launch_agent` / `list_agents`, with audit events. Defaults open; existing agents unaffected.
- Phase 1 of `plan-subagent-allowlists.md`; phases 2–3 remain proposed.

### Sub-agent crash recovery
- A resumed parent reattaches to its in-flight child by run id instead of relaunching it — a pending `launch_agent` is a reference to work already underway, not a request.
- Subscribe-before-read closes the completion race; `run_id` rides on every agent broadcast; a parent resumed alone restarts its own orphaned child.
- See `architecture.md` § "Recovering a parent that was awaiting a sub-agent".

---

## Open

### Multi-node
- Registry + DynamicSupervisor are single-node.
- Port to Horde when clustering is needed.

### Policy enforcement
- Pre-dispatch hook point in the orchestrator (not built, architecture supports it).
- Rule-based (orchestrator evaluates) and LLM-evaluated (worker evaluates) flavors.
- `SubagentPolicy` and the planned per-agent tool selection are both bespoke policy checks; a third one is the signal to build the generic hook.

### Per-agent tool selection
- Every agent currently sees every tool in the tenant (`process.ex` builds the LLM tool list unfiltered). Decided: add a tool allowlist to `AgentDef`, same shape as `SubagentPolicy`. Not built. First step in `roadmap.md`.

### Cloud readiness
Gaps that become real the moment there is a hosted product (see `roadmap.md` § Cloud readiness):
- **API key scoping** — one bearer token is full tenant power today. A hosted builder holding a tenant token is the same trust problem the worker introspection toolkit was pruned for; scoped keys (read-only, def-write-only) are the pre-cloud form of the capability model.
- **Tenant self-serve** — signup → tenant → key issuance is cloud-repo work, but the core API must not preclude it.
- **Retention** — cron-triggered agents generate events unboundedly; needs a plan before cloud launch, not before growth.
- **Webhook signature verification** — per-hook tokens plus provider signatures (Slack signing secret, Stripe signature) belong in the hooks design from the start.
- **SDK hardening** — the Python serial-task bug and missing graceful shutdown are tolerable for dev workers, not for connectors running 24/7 in managed gards.
