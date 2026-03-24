# Event Taxonomy

Core runtime events are versioned payloads with `schema_version: 1`.

- `run_started`
- `llm_request`
- `llm_response`
- `tool_call`
- `tool_result`
- `checkpoint_saved`
- `run_failed`
- `run_completed`

Runtime code should construct persisted events through `Norns.Runtime.Events` so payload validation happens before insert.
