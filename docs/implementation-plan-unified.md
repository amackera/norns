# Norns Unified Implementation Plan

Last updated: 2026-03-25
Status: Active

This is the single, cohesive execution plan reconciled across all planning docs.

## Source docs reconciled
- `docs/plan-scope-reset.md`
- `docs/next-sprint.md`
- `docs/decision-log.md`
- `docs/architecture.md`
- `docs/checkpoint-restore-contract.md`
- `docs/event-taxonomy.md`
- `docs/error-taxonomy.md`
- `docs/plan-conversation-model.md`
- `docs/plan-worker-hosted-execution.md` (deferred)
- `docs/plan-ideas-to-steal-from-arbor.md` (secondary)
- `docs/plan-jido-inspired-adoptions.md` (secondary)

---

## 0) Product scope (locked)

Norns is a **reliable execution layer for agent runs**.

Primary value:
1. Correctness under failure
2. Operator control
3. Queryable execution state without re-inference

Not the goal right now:
- broad platform expansion
- worker-hosted execution mode
- advanced plugin framework
- dashboard feature sprawl

---

## 1) Current baseline (already implemented)

- Typed runtime event contract with schema versioning
- Error taxonomy + retry policy
- Replay conformance suite foundation
- Conversation mode + cross-conversation memory core
- Human-in-the-loop (`ask_user`) interrupt/resume path
- REST + WebSocket + LiveView operational surfaces

---

## 2) Active implementation priorities (now)

### Priority A — Side-effect idempotency contract

#### Objective
Guarantee no duplicate side effects under crash/retry/replay.

#### Build
- Define canonical idempotency key format for side-effecting tool calls
- Persist idempotency markers in run events
- Enforce idempotent execution path in tool executor/runtime
- Add explicit duplicate-detection behavior and telemetry

#### Acceptance
- Replaying the same run does not duplicate side effects
- Duplicate side-effect attempt is detected and logged as a deterministic event

---

### Priority B — Replay safety expansion

#### Objective
Harden replay behavior across additional failure windows.

#### Build
- Add tests for crash windows around side-effect persistence
- Ensure deterministic resume action selection (`:llm_loop`, `:resume_tools`, `:waiting`)
- Assert event sequence and state reconstruction invariants

#### Acceptance
- Replay conformance suite passes in Docker
- No side-effect duplication in all replay tests

---

### Priority C — Operator failure inspector

#### Objective
Make failures immediately actionable via API/UI.

#### Build
- Add/standardize run failure inspector response with:
  - `error_class`
  - `error_code`
  - `retry_decision`
  - `last_checkpoint`
  - `last_event`
- Wire into run detail endpoints and LiveView run page

#### Acceptance
- Operator can answer in <60 seconds:
  1) what failed
  2) why it failed
  3) what retry path exists

---

## 3) Secondary adoptions (only after priorities A-C)

### Arbor-inspired (targeted)
- lifecycle rigor and idempotent start/stop/resume
- structured event/error taxonomies (already mostly aligned)
- recovery/health signal polish

### Jido-inspired (targeted)
- typed directives/events discipline
- stronger runtime error policy boundaries
- checkpoint/restore invariants and conformance discipline

Constraint: no broad framework abstraction work until A-C are complete.

---

## 4) Deferred track (explicit)

### Worker-hosted execution mode
Deferred until core hosted-mode reliability is fully hardened.

Prerequisites before revisit:
- strict runtime↔worker protocol spec
- replay contract spec
- proven idempotent side-effect contract
- failure-injection conformance suite maturity

Reference: `docs/plan-worker-hosted-execution.md`

---

## 5) Execution order and gates

1. Priority A (idempotency contract)
2. Priority B (replay safety expansion)
3. Priority C (operator failure inspector)
4. Secondary Arbor/Jido adoptions (scoped)
5. Re-evaluate deferred worker-hosted mode

Do not skip order; each step depends on the prior contract.

---

## 6) Definition of Done (near-term)

Near-term plan is complete when:
- side-effect idempotency is enforced and test-proven
- replay conformance suite is green for crash/retry windows
- failure inspector output is complete and operator-usable
- no active roadmap items violate scope reset

---

## 7) One-line strategy check

If a proposed feature does not improve:
- correctness under failure,
- operator control,
- or queryability without re-inference,

it is out of scope for this cycle.
