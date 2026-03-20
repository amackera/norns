# Decision Log

Last updated: 2026-03-19

## Product Decisions

### The product is the chat builder, not the engine
- The workflow engine is infrastructure; the differentiator is an LLM that generates workflows from conversation
- The builder needs the engine to exist first — hand-write workflows to understand what generated code should look like
- Ship the engine, validate with hand-written workflows, then build the builder

### Workflows are Lua scripts, not Elixir modules or config
- Previously: workflows were planned as Elixir modules. Reconsidered because the builder LLM generates workflows at runtime, and executing LLM-generated Elixir is an unsandboxable security risk.
- Evaluated three approaches:
  - **A) Data-driven step graphs** (JSON/YAML nodes) — too limited. Representing loops, conditionals, and variables in data means reinventing a bad programming language. This is what n8n/Zapier/Step Functions do and expressiveness hits a ceiling fast.
  - **B) LLM-as-orchestrator** (LLM decides each step at runtime) — infinitely flexible but non-deterministic, expensive (LLM call per decision), hard to replay. Other platforms already do this well.
  - **C) LLM-generated code + deterministic execution** — the LLM generates the workflow (at "design time", which can be runtime), then it executes deterministically. Best of both: flexible creation, deterministic execution, replayable, testable.
- **Chose C, with Lua as the language.** Lua via luerl (pure Erlang Lua 5.3 VM) gives us:
  - Real control flow (loops, conditionals, variables, functions) — no DSL expressiveness ceiling
  - LLMs are excellent at generating Lua — small language, well-represented in training data
  - Sandboxed by design — Lua code can only call functions explicitly exposed by the host
  - luerl runs on the BEAM with zero serialization cost, no NIFs, no ports
  - `luerl_sandbox` provides `max_reductions` and `max_time` to kill runaway scripts
  - Lua state is an immutable Erlang term — can be checkpointed/snapshotted between steps
- Workflows can mix deterministic and LLM steps: a Lua script calls `call_llm()` where it needs reasoning, and the surrounding control flow is pure code.

### Don't build integrations
- Use managed integration platforms (Nango, Composio) or plain HTTP
- Build zero connectors until the workflow builder is proven valuable
- The `http` step type covers most REST APIs

### LLM has two roles in the system
1. **Builder LLM** — translates natural language into Lua workflow scripts (the product)
2. **In-workflow LLM steps** — reasoning actions within a workflow (summarize, classify, decide)

---

## Implemented

### Multi-tenancy from day one
- Every table has `tenant_id` (NOT NULL, FK to tenants).
- Agent names unique per tenant.
- API keys stored per tenant.

### Schema simplification — defer version pinning
- Removed all version columns from runs, removed `run_decisions` table.
- Add back when policy gates or versioning logic exist.

### Synchronous agent execution via Oban
- `Runner.execute/3` is a plain function, Oban worker wraps it.
- No GenServers until multi-step or long-running workflows justify them.

### Anthropic API via Req
- `LLM.complete/5` wraps the Messages API. No streaming, no tool use.
- API key passed explicitly from tenant.

### Event-sourced run audit trail
- Every step logged as a `RunEvent` with sequence, event_type, payload.
- Unique constraint on (run_id, sequence).

### Docker Compose for all dev tooling
- No local Elixir install. `Dockerfile.dev` + app service in docker-compose.

---

### Error taxonomy (adopted from LangGraph)
- Four error categories, each with a different recovery path:
  1. **Transient** (network, rate limits) → automatic retry with backoff (Oban handles this)
  2. **LLM-recoverable** (bad tool call, parse failure) → feed error back to the LLM, let it retry
  3. **User-fixable** (missing info, needs approval) → pause workflow via `interrupt()`, wait for human input
  4. **Unexpected** → bubble up for developer debugging

### Separate state from context
- Workflow state (the data being transformed) is a mutable Lua table passed to the script
- Runtime context (API keys, tenant info, DB connections) is a separate read-only `ctx` object
- Adopted from LangGraph's state vs context separation

### Interrupt/resume primitive
- A workflow can pause at any point via `interrupt(payload)`, surfacing a payload to the caller ("I need approval for X")
- The run enters a `waiting` status, logged as a RunEvent
- An API endpoint resumes the run with a response value
- Unlike LangGraph, we can checkpoint the Lua VM state at the exact pause point and resume without re-executing the node

### Execution runtime: luerl via the `lua` hex package
- Use the `lua` hex package (wraps luerl) — not raw luerl
- `deflua` macro for exposing host functions to Lua
- `~LUA` sigil for compile-time Lua syntax validation
- Sandboxing: block all dangerous modules by default (io, os, file, require)
- Resource limits via `luerl_sandbox` (max_reductions, max_time)
- Known gap: memory usage cannot be capped (strings allocate on shared BEAM heap)
- Known gap: error messages from luerl are poor — need wrapper for better error context when feeding errors back to the builder LLM

---

## Open

### A) LLM provider abstraction
- Currently Anthropic-only. When/how to support multiple providers.

### B) Chat builder architecture
- How the builder LLM understands available Lua API functions and step types.
- How generated Lua scripts are validated before execution.
- How auth flows for integrations are handled in the builder conversation.

### C) Durability and replay mechanics
- Checkpoint after each side-effectful Lua call (call_llm, http, store)
- On replay, intercept side-effectful calls and return cached results from RunEvents
- Exact serialization format for Lua VM state snapshots — need to validate luerl state is serializable to Postgres
- Whether to snapshot full VM state or just the state table between steps

### D) Lua API surface design
- Which functions to expose: `call_llm()`, `http()`, `store()`, `emit()`, `interrupt()`, ...
- Argument conventions, return value shapes, error signaling
- How to handle streaming from `call_llm()` within a Lua script
