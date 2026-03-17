# Orchestration Path: Temporal-Compatible, Elixir-First

## Decision Summary

Automaton should **not commit to Temporal as an immediate backbone**.

Instead, we will:

1. Keep implementation in Elixir for now
2. Adopt **Temporal-style durable workflow semantics**
3. Build a clean orchestration boundary so backend can be swapped later
4. Define explicit migration triggers for when Temporal is justified

This preserves speed and control now while maintaining a low-regret path to Temporal later.

---

## Why this path

### Benefits now (Elixir-first)

- Faster iteration in current stack
- Full control over runtime behavior and data model
- Lower operational complexity in early product phase
- Easier to evolve domain model (agent versioning, policy gates, audit records)

### Risks of committing to Temporal too early

- Higher infrastructure and operational complexity
- Early lock-in to SDK/runtime assumptions
- Potentially large rewrite before product semantics stabilize
- Opportunity cost vs shipping customer-facing value

---

## Required Semantics (must-haves regardless of backend)

Automaton runtime must support:

- Durable run contexts (workflow-like execution)
- Signals (asynchronous external input into active runs)
- Queries (read-only state inspection)
- Timers/retries/timeouts
- Replayable event history
- Deterministic policy gate enforcement
- Version pinning per run:
  - `agent_version`
  - `policy_version`
  - `prompt_bundle_version`
  - `model_config_version`
  - `tooling_config_version`

---

## Architecture Boundary (internal orchestration interface)

Define and program against a backend-agnostic orchestration API:

- `start_run(agent_id, trigger, input)`
- `append_signal(run_id, signal)`
- `query_state(run_id)`
- `schedule_timer(run_id, timer_spec)`
- `resume_run(run_id)`
- `record_activity_result(run_id, step_id, result)`
- `replay(run_id)`
- `abort_run(run_id, reason)`

Initial implementation: Elixir + Postgres + Oban.
Future implementation option: Temporal backend adapter.

---

## Control Plane vs Reasoning Plane

To preserve replayability and auditability:

- **Deterministic control plane**
  - state machine transitions
  - gate evaluations
  - escalation/approval paths
- **Nondeterministic reasoning plane**
  - LLM/tool activities that produce proposals/artifacts
  - outputs persisted as immutable run events

The workflow remains deterministic even if reasoning steps are probabilistic.

---

## Migration Triggers (when to revisit Temporal)

Reevaluate adopting Temporal if one or more become true:

1. Long-running workflow complexity materially slows delivery
2. Retry/timer/recovery bugs become recurring operational burden
3. On-call load from orchestration failures exceeds acceptable threshold
4. Multi-team scale requires stronger built-in workflow guarantees
5. Backend orchestration work consistently displaces product differentiation

At that point, implement a Temporal adapter behind the orchestration boundary.

---

## Near-Term Plan

1. Implement orchestration boundary in Elixir
2. Build signal/query/timer/replay semantics on event-sourced run log
3. Enforce deterministic gate model (policy vs confidence/risk split)
4. Persist complete audit trail with version pinning
5. Validate with 1–2 production-like workflow agents before backend changes

This keeps the system Temporal-shaped while avoiding premature infrastructure commitments.
