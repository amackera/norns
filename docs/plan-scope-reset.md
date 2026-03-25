# Plan: Scope Reset (Execution Reliability First)

Last updated: 2026-03-25
Status: Active

## Why this reset

Norns should not position itself as "deep state management" or a broad agent platform.
The durable value is simpler and more concrete:

1. Correctness under failure
2. Operator control
3. Queryable execution state without re-inference

Transcript persistence is often enough for simple single-agent flows. Norns exists for when execution reliability matters.

---

## Product framing (tight)

Norns is a **reliable execution layer for agent runs**:
- durable run lifecycle
- idempotent side effects
- retries + failure classification
- resumability + inspectable event timelines

Not in scope (for now): broad framework/platform ambitions.

---

## Keep / Build

- Run lifecycle contract (`pending|running|waiting|completed|failed`)
- Typed/versioned runtime events
- Error taxonomy + deterministic retry policy
- Replay/restore contract + conformance tests
- Conversation mode where it reduces re-inference and improves UX
- Memory where it is explicitly useful across conversations

## Defer / Avoid

- Worker-hosted execution mode (keep as deferred design)
- Large plugin/framework abstractions
- Broad integration catalog strategy
- Dashboard expansion beyond operational visibility
- New execution modes (e.g., code-mode) before reliability core is stable

---

## Reconciled near-term plan

### Phase A — Runtime contract hardening
- Finalize typed event contract (`schema_version` + validation)
- Finalize failure taxonomy + retry mapping
- Ensure all terminal failures persist class/code/retry metadata

### Phase B — Idempotency and side-effect safety
- Explicit idempotency key semantics for tool side effects
- Replay tests that prove no duplicate side effects on crash/retry
- Define canonical side-effect event markers

### Phase C — Operator reliability UX/API
- Run timeline and failure inspector outputs
- Resume/retry endpoints with explicit audit events
- Keep operator question answerable in under 60 seconds:
  - what happened?
  - why did it fail?
  - what can I do now?

---

## Immediate next 3 tasks

1. Add explicit side-effect idempotency key contract (doc + enforcement path)
2. Add/extend conformance tests for duplicate side-effect prevention
3. Add run-failure inspector response shape (`error_class`, `error_code`, `retry_decision`, last checkpoint/event)

---

## Success criteria

Scope reset is successful when:
- reliability guarantees are test-proven
- operators can debug and act quickly
- no roadmap drift into broad platform features
