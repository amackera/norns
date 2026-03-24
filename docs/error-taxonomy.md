# Error Taxonomy

Runtime failures are classified into:

- `transient`
- `external_dependency`
- `validation`
- `policy`
- `internal`

`Norns.Runtime.ErrorPolicy` maps class/code pairs to deterministic retry decisions. Persisted `run_failed` payloads and `runs.failure_metadata` include `error_class`, `error_code`, and `retry_decision`.
