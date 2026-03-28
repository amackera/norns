# Plan: Provider-Neutral LLM Wire Format

## Problem

The `llm_task` payload and the internal message format are Anthropic-specific. Tool calls are embedded as `{"type": "tool_use"}` content blocks, tool results are `{"type": "tool_result"}` content blocks inside user messages, tool definitions use `input_schema`, and stop reasons are Anthropic values (`"end_turn"`, `"tool_use"`). This makes multi-LLM support in the SDK unnecessarily complex.

## What needs to change

### 1. llm_task dispatch payload (orchestrator → worker)

**Current (Anthropic-shaped):**
```json
{
  "messages": [
    {"role": "assistant", "content": [
      {"type": "tool_use", "id": "toolu_123", "name": "search", "input": {"q": "test"}}
    ]},
    {"role": "user", "content": [
      {"type": "tool_result", "tool_use_id": "toolu_123", "content": "results"}
    ]}
  ],
  "opts": {"tools": [{"name": "search", "input_schema": {...}}]}
}
```

**Proposed (neutral):**
```json
{
  "messages": [
    {"role": "assistant", "content": "", "tool_calls": [
      {"id": "tc_123", "name": "search", "arguments": {"q": "test"}}
    ]},
    {"role": "tool", "tool_call_id": "tc_123", "name": "search", "content": "results"}
  ],
  "tools": [{"name": "search", "description": "...", "parameters": {...}}]
}
```

Key changes:
- Tool calls as a separate `tool_calls` field on assistant messages, not content blocks
- Tool results as `role: "tool"` messages, not content blocks inside user messages
- Tool definitions use `parameters` not `input_schema`
- Tools at top level, not nested in `opts`

### 2. llm_result response (worker → orchestrator)

**Current:**
```json
{
  "content": [{"type": "text", "text": "..."}, {"type": "tool_use", ...}],
  "stop_reason": "end_turn" | "tool_use",
  "usage": {...}
}
```

**Proposed:**
```json
{
  "content": "The answer is...",
  "tool_calls": [{"id": "tc_456", "name": "search", "arguments": {...}}],
  "finish_reason": "stop" | "tool_call" | "length" | "error",
  "usage": {...}
}
```

Key changes:
- `content` is a string (text response), not an array of typed blocks
- `tool_calls` is a separate array (may be empty or absent)
- `finish_reason` with neutral values instead of Anthropic-specific `stop_reason`

### 3. Internal message history (in the agent process)

This is where it gets tricky. The agent's `state.messages` list currently uses Anthropic format. It's also what gets persisted in checkpoint events and used for replay.

Options:

**A) Convert at the boundary.** Keep Anthropic format internally, translate to/from neutral format only at the dispatch/receive boundary. The orchestrator stays Anthropic-shaped internally but the wire format is neutral.

**B) Switch internal format to neutral.** Change the message history, checkpoint events, and replay logic to use the neutral format. Cleaner long-term but bigger refactor.

**Recommendation: Option A first.** Add a translation layer at the dispatch and receive boundaries. The internal format can migrate later (or never — it doesn't leak outside the orchestrator).

## Implementation: Translation Layer

### New module: `Norns.LLM.Format`

```elixir
defmodule Norns.LLM.Format do
  @doc "Convert internal (Anthropic) messages to neutral wire format."
  def to_neutral(messages, tools)

  @doc "Convert neutral wire format response to internal format."
  def from_neutral(response)

  @doc "Convert internal tool definitions to neutral format."
  def tools_to_neutral(tools)
end
```

### Where it's applied

**Dispatch (orchestrator → worker):**
In `handle_continue(:llm_loop, ...)`, after building the messages and before dispatching:

```elixir
# Current
llm_task = %{messages: messages_for_llm, opts: llm_opts, ...}

# New
llm_task = %{
  messages: Format.to_neutral_messages(messages_for_llm),
  tools: Format.to_neutral_tools(api_tools),
  ...
}
```

**Receive (worker → orchestrator):**
In `handle_info({:task_result, ...})`, convert the response back:

```elixir
# Current
{:ok, %{"content" => content, "stop_reason" => stop_reason, ...}} ->

# New
{:ok, neutral_response} ->
  response = Format.from_neutral(neutral_response)
  # response has .content (Anthropic-shaped), .stop_reason, .usage
```

**Tool results (orchestrator → messages):**
When building tool result messages to append to history after tool execution, convert from neutral tool results to internal format.

### What stays the same

- Internal message history format (Anthropic-shaped — it works, it's in the DB)
- Event payloads (already persisted, backward compatible)
- Replay logic (reads internal format from events)
- DefaultWorker (will need to translate neutral → Anthropic API call → neutral response)

## Migration

1. Add `Norns.LLM.Format` with translation functions
2. Apply at dispatch boundary (outgoing llm_task)
3. Apply at receive boundary (incoming llm_result)
4. Update DefaultWorker to accept neutral format and translate to Anthropic API
5. Update SDKs to use neutral format
6. Old format still accepted during transition (check for `stop_reason` vs `finish_reason`)

## Neutral format spec

### Messages

| Role | Fields |
|------|--------|
| `user` | `role`, `content` (string) |
| `assistant` | `role`, `content` (string), `tool_calls` (optional array) |
| `tool` | `role`, `tool_call_id`, `name`, `content` (string) |

### Tool calls

```json
{"id": "tc_123", "name": "search", "arguments": {"query": "test"}}
```

### Tool definitions

```json
{"name": "search", "description": "Search the web", "parameters": {"type": "object", ...}}
```

### Finish reasons

| Value | Meaning |
|-------|---------|
| `stop` | Normal completion |
| `tool_call` | Model wants to call tool(s) |
| `length` | Max tokens reached |
| `error` | Model error |

### Usage

```json
{"input_tokens": 150, "output_tokens": 30}
```

## Files affected

| File | Change |
|------|--------|
| `lib/norns/llm/format.ex` | NEW — translation layer |
| `lib/norns/agents/process.ex` | Apply format at dispatch/receive boundaries |
| `lib/norns/workers/default_worker.ex` | Accept neutral, translate to Anthropic for API call |
| `lib/norns/tools/tool.ex` | `to_api_format` should use `parameters` |
| `test/norns/llm/format_test.ex` | NEW — round-trip translation tests |
