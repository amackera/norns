# Norns

Durable agent runtime on BEAM. MIT licensed.

Norns is an orchestrator for LLM-powered agents. You define agents and tools in your language (Python, TypeScript, Elixir), and Norns handles the hard parts: crash recovery, checkpointing, retries, conversation state, and observability. The architecture is Temporal-style — your code runs on workers, Norns coordinates.

**Status:** Early. The runtime works, the Python SDK is in progress, the API is stabilizing. Not production-ready yet.

## Quickstart

```bash
git clone https://github.com/amackera/norns.git
cd norns
docker compose up -d
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.create
docker compose run --rm -e POSTGRES_HOST=db app mix ecto.migrate
docker compose up
```

Open `http://localhost:4000` to set up a tenant and start experimenting.

There's a durability demo you can run without an API key — it starts an agent, kills it mid-task, and resumes from the event log:

```bash
docker compose run --rm -e POSTGRES_HOST=db app mix demo.durability
```

## How it works

The orchestrator is a state machine. It never calls an LLM or executes a tool — it dispatches tasks to workers and persists every step as an event. Workers do the actual work: making API calls, running your tool functions, talking to your databases.

```
Orchestrator                         Worker (your code)
  │                                      │
  │  llm_task ─────────────────────────► │  calls Claude/GPT/etc
  │  ◄── response ─────────────────────  │
  │                                      │
  │  tool_task ────────────────────────► │  runs your function
  │  ◄── result ───────────────────────  │
  │                                      │
  │  (checkpoint, repeat)                │
```

A built-in DefaultWorker handles everything locally for development. For production, you run your own workers — Norns never touches your API keys or data.

## Python SDK

```bash
pip install norns-sdk
```

Define agents and tools in Python. The SDK connects to Norns as a worker.

```python
from norns import Norns, Agent, tool

@tool
def search_docs(query: str) -> str:
    """Search product documentation."""
    return db.vector_search(query)

agent = Agent(
    name="support-bot",
    model="claude-sonnet-4-20250514",
    system_prompt="You are a customer support agent.",
    tools=[search_docs],
    mode="conversation",
)

norns = Norns("http://localhost:4000", api_key="nrn_...")
norns.run(agent, llm_api_key=os.environ["ANTHROPIC_API_KEY"])
```

See [norns-sdk-python](https://github.com/amackera/norns-sdk-python).

## What you get

**Crash recovery.** Every LLM call and tool result is checkpointed. Kill the process, restart, and the agent resumes without re-executing anything.

**Conversations.** Agents can maintain context across messages, with automatic context window management. One agent can handle multiple concurrent conversations (e.g., different Slack channels).

**Agent memory.** Key-value store shared across all conversations. What the agent learns in #engineering, it can recall in #product.

**Human-in-the-loop.** The `ask_user` tool pauses the agent and waits for a human response. Fully durable — survives crashes while waiting.

**Observability.** Every run has a full event timeline. Failed runs include error classification, retry decisions, and the last checkpoint. There's a LiveView dashboard for browsing it all.

**Idempotent side effects.** Tools marked as side-effecting get deterministic idempotency keys. On replay, they're skipped instead of re-executed.

## REST API

```
POST   /api/v1/agents                         Create agent
GET    /api/v1/agents                         List agents
GET    /api/v1/agents/:id                     Show agent
POST   /api/v1/agents/:id/messages           Send message
GET    /api/v1/agents/:id/runs               List runs
GET    /api/v1/agents/:id/conversations      List conversations
GET    /api/v1/runs/:id                      Show run
GET    /api/v1/runs/:id/events               Event log
```

Auth via `Authorization: Bearer <token>`. Real-time events via WebSocket at `/socket`.

## Architecture

```
Norns.Supervisor
├── Repo (PostgreSQL)
├── PubSub
├── DynamicSupervisor
│   ├── Agent processes (state machines)
│   └── DefaultWorker (local LLM + tools)
├── WorkerRegistry
├── TaskQueue
└── Phoenix Endpoint (REST, WebSocket, LiveView)
```

The runtime is Elixir on BEAM/OTP, Phoenix for the web layer, PostgreSQL for persistence. See [docs/architecture.md](docs/architecture.md) for the full picture.

## License

MIT
