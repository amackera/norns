# SDK Design Plan

## Architecture: Temporal-Style Client/Worker Split

Like Temporal, there are two separate concerns in the SDK:

- **`Norns` (worker)** — connects via WebSocket, registers agents/tools, handles LLM and tool tasks. Blocks forever. Runs in user infrastructure.
- **`NornsClient` (client)** — sends messages to agents, queries runs, streams events. Used by web servers, Slack bots, CLI tools.

These are architecturally separate. They can run in the same process but they don't have to.

```
Your Infrastructure                    Norns Runtime

  Worker (norns.run)                     Orchestrator
  ├── defines agents                    ├── dispatches tasks
  ├── defines tools                     ├── persists events
  ├── holds API keys                    ├── manages state machine
  ├── handles llm_task                  └── serves API + dashboard
  └── handles tool_task

  Client (NornsClient)
  ├── sends messages ──────────────────► POST /agents/:id/messages
  ├── queries runs ────────────────────► GET /runs/:id
  ├── streams events ──────────────────► WebSocket /socket
  └── manages conversations ───────────► GET/DELETE /conversations
```

## Python SDK (in progress)

Repository: `norns-sdk-python`

### Worker (implemented)

```python
from norns import Norns, Agent, tool

@tool
def search_docs(query: str) -> str:
    """Search product docs."""
    return db.search(query)

agent = Agent(name="support-bot", tools=[search_docs], ...)
norns = Norns("http://localhost:4000", api_key="nrn_...")
norns.run(agent, llm_api_key=os.environ["ANTHROPIC_API_KEY"])  # blocks forever
```

### Client (next)

```python
from norns import NornsClient

client = NornsClient("http://localhost:4000", api_key="nrn_...")

# Fire and forget
run = client.send_message("support-bot", "Where's my order?")

# Block for result
result = client.send_message("support-bot", "Where's my order?", wait=True)
print(result.output)

# Stream events
for event in client.stream("support-bot", "Research topic"):
    print(f"[{event.type}] {event.data}")

# Conversations
client.send_message("support-bot", "Hello", conversation_key="slack:U01ABC")
```

## Server-Side Changes Needed

1. **Return `run_id` in send_message response** — currently returns `{"status": "accepted"}`, needs `{"status": "accepted", "run_id": 42}` so the client can poll for completion
2. **Sync message mode** (optional) — `{"sync": true}` holds the HTTP connection until completion instead of requiring polling
3. **Agent lookup by name** (optional) — currently ID-only, SDK wants to address agents by name

## Implementation Order

1. Return run_id in send_message response (server-side)
2. NornsClient with REST methods (list agents, get run, get events)
3. send_message with fire-and-forget
4. send_message with wait=True (polling)
5. stream (WebSocket)
6. TypeScript SDK (same architecture)
