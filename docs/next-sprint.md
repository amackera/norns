# Norns Next Sprint Plan

Last updated: 2026-03-25
Sprint goal: tighten execution reliability and operator clarity.

Reconciled with: `docs/plan-scope-reset.md` and `docs/implementation-plan-unified.md`

## Completed Baseline (previous sprint)

- Typed Event Taxonomy v1
- Error Taxonomy + Retry Policy
- Replay Conformance Suite

## Current Priority 1 — Side-Effect Idempotency Contract

### Objective
Prevent duplicate side effects under crash/retry/replay.

### Scope
- Define idempotency key format for side-effecting tool calls
- Persist idempotency markers in run events
- Enforce idempotent write path in executor/runtime

### Acceptance Criteria
- Duplicate execution of same side-effect key is prevented
- Conformance tests prove exactly-once behavior at runtime boundary

---

## Current Priority 2 — Replay Safety Expansion

### Objective
Prove replay behavior for more failure windows.

### Scope
- Add cases for crash before/after side-effect persistence
- Add sequence integrity assertions across replay/resume
- Ensure resume action selection is deterministic

### Acceptance Criteria
- Replay suite passes in Docker
- No duplicate side effects in all replay tests

---

## Current Priority 3 — Operator Failure Inspector

### Objective
Make run failure state immediately actionable.

### Scope
- API response shape for failure inspection:
  - `error_class`
  - `error_code`
  - `retry_decision`
  - `last_checkpoint`
  - `last_event`
- Wire to existing run detail endpoints and tests

### Acceptance Criteria
- Operator can answer in <60 seconds:
  1) what failed
  2) why it failed
  3) what retry path exists

---

## Out of Scope (explicit)

- Worker-hosted execution mode
- Broad plugin framework expansion
- Dashboard feature expansion beyond run reliability UX
- New execution modes (e.g., code-mode)
