# Norns Implementation Plan (Simple)

Last updated: 2026-03-19

## Goal
Build a safe, durable Lua workflow runtime that can execute AI-enabled workflows with auditability and human-in-the-loop support.

---

## Phase 1 — Lua Runtime Foundation

### Build
- Add `lib/norns/workflow/runtime.ex`
- Execute Lua scripts via luerl (`lua` package)
- Enforce sandbox/resource limits (`max_reductions`, `max_time`)
- Return structured errors

### Done when
- A basic Lua script executes successfully in tests
- Infinite loop / unsafe calls are blocked or terminated safely

---

## Phase 2 — Lua Host API + Event Logging

### Build
- Add `lib/norns/workflow/api.ex`
- Expose initial safe host functions:
  - `call_llm(prompt, opts?)`
  - `http(method, url, opts?)`
  - `emit(value)`
  - `interrupt(payload)`
- Log each host function call to `run_events` with input/output/timing

### Done when
- Each host function emits a corresponding run event
- LLM + HTTP calls are traceable in the event log

---

## Phase 3 — Runner Integration

### Build
- Add `workflow_script` column on agents
- Update runner:
  - if `workflow_script` exists → execute Lua runtime
  - else → keep existing single-LLM fallback
- Preserve run state transitions (`pending -> running -> completed/failed`)

### Done when
- Agents with script execute via Lua path
- Agents without script still work via legacy path

---

## Phase 4 — Interrupt/Resume

### Build
- Add waiting/paused status handling
- Support `interrupt(payload)` to pause run and return control
- Add resume path (`POST /api/v1/runs/:id/resume`)
- Restore execution from checkpoint/state

### Done when
- Workflow can pause for human input and resume successfully
- Pause/resume lifecycle is reflected in run events

---

## Phase 5 — First Two Workflows

### Build
- Release notes workflow (Lua)
- URL summarizer workflow (Lua)
- Update mix task(s) to use workflow-script path

### Done when
- Both workflows run end-to-end
- Outputs are persisted and replay trail is complete

---

## Phase 6 — API Trigger Surface

### Build
- `POST /api/v1/runs` trigger endpoint
- API key auth -> tenant resolution
- Enqueue run job and return `{run_id, status}`

### Done when
- External caller can trigger a run for a tenant-scoped agent
- Triggered run appears in run/event logs

---

## Cross-Cutting Requirements
- No shell execution primitive
- Keep integrations third-party / HTTP-based
- Maintain multi-tenant isolation
- Keep deterministic control flow + auditable event trail

---

## Immediate Next 3 Tasks
1. Scaffold `workflow/runtime.ex` with a minimal testable Lua execution path
2. Add `workflow_script` migration + runner dispatch switch
3. Add `workflow/api.ex` with `call_llm` and `emit` first, then `http`
