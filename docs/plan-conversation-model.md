# Plan: Task vs Conversation Agent Modes

## Context

Agents currently run in task mode only: receive message → run to completion → forget everything. A Slack bot, support agent, or any interactive agent needs to maintain context across multiple interactions. This plan adds a conversation mode where agents accumulate context across runs.

## What changes

**New concept: Conversation.** A conversation is a persistent message history attached to an agent. Multiple runs happen within one conversation. Each run adds to the conversation history. Between runs, the history is persisted to Postgres.

**Agent modes:**
- `:task` (default, current behavior) — each `send_message` starts fresh. Messages reset after completion. Runs are independent.
- `:conversation` — each `send_message` appends to an ongoing conversation. The LLM sees full history from previous runs. Conversation persists across process restarts.

## Data model

### New table: `conversations`

```
conversations
  id              bigint PK
  agent_id        bigint FK NOT NULL (unique — one conversation per agent for now)
  tenant_id       bigint FK NOT NULL
  messages        jsonb NOT NULL DEFAULT '[]'
  summary         text            — compressed summary of older messages
  message_count   integer DEFAULT 0
  token_estimate  integer DEFAULT 0
  inserted_at     utc_datetime_usec
  updated_at      utc_datetime_usec
```

One conversation per agent keeps it simple. If we need multiple conversations per agent later (e.g., per-channel in Slack), add a `channel` or `external_id` field.

### Schema changes

- `runs`: add `conversation_id` (nullable FK). Task-mode runs have no conversation. Conversation-mode runs link to one.
- `AgentDef`: add `mode: :task | :conversation`. Read from `model_config["mode"]` with default `:task`.

## Context management

When the conversation gets long, old messages need to be compressed. Two strategies, configured on AgentDef:

- `:sliding_window` (default) — keep last N messages (default N=20), discard older ones
- `:none` — keep everything (for short-lived conversations)

Future: `:summarize` — when messages exceed threshold, ask the LLM to summarize older messages into a paragraph, store in `conversations.summary`, drop the originals. Not in scope for initial build.

The summary (if present) is prepended as a system-level context block:

```
System prompt: "You are a product expert..."

[If summary exists]
"Summary of earlier conversation: {summary}"

[Recent messages]
user: "What does the pricing API return?"
assistant: "The pricing API returns..."
user: "What about error codes?"
```

## Process changes

### `init/1`

- If mode is `:conversation`, load (or create) the conversation record
- Populate `state.messages` from `conversation.messages`
- Store `conversation` in state

### `handle_cast({:send_message, content}, %{status: :idle})`

- Task mode: current behavior (create run, start fresh)
- Conversation mode: append message to existing history, create a new run linked to the conversation, enter LLM loop

### `complete_successfully/2`

- Task mode: current behavior (status → idle)
- Conversation mode: persist updated messages to the conversation record, status → idle, messages stay for next interaction

### `rebuild_state/2` (crash recovery)

- Task mode: current behavior (replay from events)
- Conversation mode: load conversation from DB first, then replay run events on top

## Agent lifecycle in conversation mode

```
First message ever:
  1. Create conversation (empty messages)
  2. Append user message
  3. Create run (linked to conversation)
  4. LLM loop → tool calls → completion
  5. Persist messages to conversation
  6. Agent idle

Second message:
  1. Load conversation (has history from first message)
  2. Apply context strategy (maybe compact old messages)
  3. Append new user message
  4. Create new run (linked to same conversation)
  5. LLM loop (sees full history) → completion
  6. Persist updated messages to conversation
  7. Agent idle

After crash:
  1. Orphan recovery finds run with status "running"
  2. Load conversation from DB (persisted after last completed run)
  3. Replay events from current run on top
  4. Resume
```

## AgentDef additions

```elixir
%AgentDef{
  mode: :task,                          # :task | :conversation
  context_strategy: :sliding_window,    # :sliding_window | :none
  context_window: 20,                   # max messages to keep
}
```

Read from `model_config`:

```json
{
  "mode": "conversation",
  "context_strategy": "sliding_window",
  "context_window": 20
}
```

## API changes

### REST

- `GET /api/v1/agents/:id/conversation` — view current conversation (messages, summary, token estimate)
- `DELETE /api/v1/agents/:id/conversation` — reset conversation (start fresh)

### UI

- Agent detail page shows conversation mode indicator
- "Reset conversation" button for conversation-mode agents
- Message count / token estimate displayed

## Files to create

| File | Purpose |
|------|---------|
| `lib/norns/conversations.ex` | Conversation context (CRUD) |
| `lib/norns/conversations/conversation.ex` | Schema |
| `lib/norns/conversations/context.ex` | Context management strategies |
| `priv/repo/migrations/..._create_conversations.exs` | Migration |
| `test/norns/conversations_test.exs` | Conversation CRUD tests |
| `test/norns/conversations/context_test.exs` | Context strategy tests |
| `test/norns/agents/process_conversation_test.exs` | Conversation mode process tests |

## Files to modify

| File | Change |
|------|--------|
| `lib/norns/agents/agent_def.ex` | Add `mode`, `context_strategy`, `context_window` |
| `lib/norns/agents/process.ex` | Conversation loading, persistence, mode branching |
| `lib/norns/runs/run.ex` | Add `conversation_id` field |
| `lib/norns_web/live/agent_live.ex` | Show conversation info, reset button |
| `lib/norns_web/controllers/agent_controller.ex` | Conversation endpoints |
| `lib/norns_web/router.ex` | New routes |

## Implementation order

1. Migration + Conversation schema
2. Conversations context module
3. Context management (sliding_window)
4. AgentDef additions
5. Process changes (conversation loading, persistence, mode branching)
6. Tests
7. API endpoints + UI

## What NOT to build

- Multiple conversations per agent (one is enough for now)
- Summarization strategy (sliding window covers the launch case)
- Conversation forking or branching
- Conversation export/import
- Per-message token counting (estimate from message count is fine)
