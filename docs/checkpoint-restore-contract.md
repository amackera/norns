# Checkpoint Restore Contract

- `checkpoint_saved` snapshots `messages` and `step`.
- Replay restores from the latest checkpoint, then replays later events in sequence order.
- If replay ends with unresolved `tool_call` work and no matching `tool_result`, resume executes the pending tool blocks once without writing duplicate `tool_call` events.
- If replay ends after `tool_result` but before `checkpoint_saved`, reconstructed state must match the pre-crash message history derived from the event stream.
