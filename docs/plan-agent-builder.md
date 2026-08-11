# Plan: Agent Builder

**Status:** Direction agreed (2026-08-08); cloud boundary decided (2026-08-10) — builder ships as a Norns Cloud product, sequencing in `roadmap.md`
**Depends on:** per-agent tool selection (shipped 2026-08-10), cron triggers (shipped 2026-08-10), gards Phase 1 (core shipped 2026-08-10, `gards.md`)

The product direction: a builder that turns "create a Slack bot that posts the
current call count to #general every Friday" into a running, durable agent.
This doc records what that requires, the two modes it decomposes into, and what
we deliberately are not building.

---

## The central insight: compose vs fabricate

An agent on Norns is two things: a **definition** (prompt, model, config —
data) and **capabilities** (tools — worker code someone runs). The builder
story splits cleanly along that line:

| | Compose | Fabricate |
|---|---|---|
| When | The tools already exist in the tenant | A capability is missing |
| Output | An agent def — pure data | Worker code from a template |
| Deploy | Nothing. No repo, no process, no restart | A worker process must run somewhere |
| Loop | create def → test message → read events → iterate | scaffold → write tool → run worker → same loop |
| Cost | Minutes | The fallback, not the default |

**Compose is the default.** Workers are infrastructure — the tenant sets up
its capability layer once (the Slack worker, the DB worker, the email worker),
maintained like services. Agents are configuration: cheap, disposable
assemblies of prompt + tool selection + triggers, created and tested entirely
through the data plane. The builder's first move is always to read the tool
catalog (`GET /api/v1/tools`) and decide which mode it's in.

The worked example decomposes as:

| Fragment | Ingredient | Mode |
|---|---|---|
| "every Friday" | cron trigger | data (core feature) |
| "posts to #general" | `post_to_slack` tool | compose if a Slack worker exists |
| "the current call count" | `get_call_count` tool | fabricate only if missing |
| the agent itself | def: prompt + model + tool selection | data |

If the tenant already runs a Slack worker and a metrics worker, this entire
agent is compose — the builder ships it without deploying anything.

---

## What compose mode requires

### 1. Per-agent tool selection (the one core gap) — shipped 2026-08-10

Previously every agent saw every tool in the tenant: the LLM tool list was
builtins + def tools + **all** worker tools, unfiltered. "Assemble existing
tools differently" is impossible when every agent gets the same assembly —
and it's a safety problem independent of the builder (the call-count bot is
also offered `send_email` and `delete_record`).

Shipped as `Norns.Agents.ToolPolicy`: a tool allowlist in
`model_config["tools"]`, same shape as `SubagentPolicy` (default `open` for
backwards compatibility, explicit selection opts in), motivated by the same
incident class. It filters the advertised tool list and rejects
out-of-policy calls at dispatch with a `tool_call_denied` audit event. This
was the prerequisite for everything else in compose mode.

### 2. Cron triggers, as first-class Norns data — shipped 2026-08-10

A composed agent has no repo, so trigger config cannot live in one. Triggers
are Norns data: a `triggers` table (agent_id, cron expression, message,
optional persistent conversation key), fired by a minutely Oban job with an
atomic per-minute claim, managed via `/api/v1/triggers` (including
`POST /triggers/:id/fire` for testing outside the schedule). The SDK may
later grow `Agent(triggers: [...])` as sync sugar, but **Norns is the system
of record**.

This also put `trigger_type` to work: runs started by a trigger carry
`"schedule"`, improving filtering and debugging for free. `"webhook"`
arrives with inbound webhooks.

### 3. Inbound webhooks (Layer 2 of the trigger surface)

Many services just POST to a URL (Twilio, Mailgun/SES inbound email, GitHub,
Stripe). For those, a connector process is pointless glue. One small, pure
endpoint:

```
POST /api/v1/hooks/:hook_token   → creates a run on the mapped agent
```

A `hooks` table maps token → agent, with an optional conversation-key
extraction path (e.g. `From` for SMS, so each phone number is its own
persistent conversation). This is HTTP ingress creating runs — exactly what
the messages endpoint already is, with per-hook token auth. It does not bend
orchestrator purity.

The full trigger surface, for reference:

- **Layer 1 — connector workers**: Slack/Discord/anything needing credentials
  or a persistent connection. The same process that registers outbound tools
  runs the inbound listener and calls `client.send_message(...,
  conversation_key: thread_id)`. Credentials never touch Norns.
- **Layer 2 — native webhooks**: services that speak HTTP to us. Core feature.
- **Layer 3 — cron triggers**: time-based. Core feature.

The line: if it speaks HTTP to us, core can receive it; if we must hold
credentials or a connection, it's a connector.

---

## What fabricate mode requires

When the catalog lacks a capability, the builder falls back to generating
worker code — but from **templates, not freeform**. Four of the five
ingredients in any agent are config or known-good shapes; the builder should
only ever write the one bespoke tool function.

1. **Templates in `nornsctl new`** — `--template slack-bot` (outbound tools
   only), `--template slack-connector` (adds the Socket Mode listener), etc.
   The scaffold already puts the agent def in code (`Agent(...)` synced by
   `norns.run(agent)`), so the repo is self-contained: repo + secrets fully
   reconstitute the agent anywhere.
2. **Scaffold ships an `AGENTS.md`** teaching any coding agent the full loop:
   scaffold → worker up → test message → read run events → iterate. This is
   distribution, not infrastructure — every scaffolded project makes Claude
   Code (or any coding agent) a competent Norns developer.
3. **`nornsctl` gaps**: `agents message --wait` (block until terminal state,
   print the run summary — the SDK client already has `wait=True`; the CLI
   doesn't).
4. **Hosting** — the fabricated worker must run somewhere durable. Interim:
   templates ship a Dockerfile and a deploy-shaped README ("you host it" is a
   documented step, not a shrug). End state: managed gards — and the first
   managed workload is connectors, not coding agents (`decision-log.md` § The
   cloud boundary): a connector needs no snapshots, tunnels, or code
   extraction, so hosting it is the provisioner's minimum viable form. The
   builder then arrives into a tenant whose capability layer is already
   hosted, making almost everything compose mode.
5. **Secrets** — the builder can scaffold Slack code but cannot conjure the
   bot token. The provisioner/gard design needs env-var secrets injection, and
   the builder flow needs a human step ("paste your token"). Norns core stays
   credential-free.

---

## Consequence: the roadmap fork is decided

`roadmap.md` posed the fork as "own the provisioner (sell compute) vs sell
durability (Durable MCP)". The builder vision settles it: fabricated workers
need somewhere durable to run, and that is exactly the provisioner/managed-
gards branch. Committing to the builder is choosing **own the provisioner**.
The coding-agent thread and the builder thread are the same thread — the
eventual builder is itself a coding agent, and gards are where its output
lives.

Durable MCP and custom workflows stay parked, per the roadmap's existing
recommendation.

---

## The builder itself

**Placement: the builder is a Norns Cloud product, not a core feature
(decided 2026-08-10).** The builder is an agent — it makes LLM calls and runs
a loop — which is exactly what the orchestrator must never do; it cannot live
in core without breaking purity. Structurally it is a client of the API, and
the hosted form runs as an agent *on* Norns with a cloud-operated worker
(dogfooding). Core ships the primitives; cloud ships the builder. See
`decision-log.md` § The cloud boundary.

The builder can start as low-tech as a skill: a coding agent following the
scaffold's `AGENTS.md` against the existing API is already a working
fabricate-mode builder, and `nornsctl` + REST already cover the compose loop.

Because compose mode is entirely data-plane — no process execution — a hosted
builder (a built-in agent or dashboard flow) becomes viable in a way it isn't
for fabricate. Two guardrails carried over from the introspection discussion:

- **Agent-write tools (`create_agent`, `update_agent`) are not exposed to
  agents** until a capability model exists. A builder agent that writes defs
  gates every write behind `ask_human` — which the runtime already does well.
- **No worker-side introspection toolkit.** A worker holding a tenant bearer
  token so agents can read all runs and mutate defs inverts the trust
  direction ("Norns never sees your data" ≠ "your worker holds a Norns admin
  credential") and has no per-agent scoping. Superseded by compose mode's
  data-plane loop.

Mid-build clarification ("call count from where?") is `ask_human` — the
builder dogfoods the runtime's own waiting state.

---

## Not building (pruned 2026-08-08)

- **Worker-side introspection toolkit** — wrong trust direction, no scoping.
- **Built-in introspection tools for agents** — revisit only if evidence shows
  agents (not humans/builders) need runtime reads mid-run.
- **A Norns MCP server** — for Claude Code it's redundant (`nornsctl` is the
  MCP server in CLI form); for GUI clients the loop doesn't close (they can't
  run workers). Revisit as a thin adapter over the REST API if
  prompt-tuning-from-Desktop demand appears.
- **Eval primitive / `diff_runs` / fixture runner** — good idea, premature.
  Let builder usage prove the loop first.
- **Speculative meta-agent infrastructure** — the builder rides on primitives
  that are each independently useful (tool selection, triggers, webhooks,
  templates, gards); no builder-only machinery.

---

## Sequencing

See `roadmap.md`. Short form: tool selection on defs → cron triggers →
gards Phase 1 (+ secrets requirement) → templates + scaffold `AGENTS.md` +
`--wait` → webhooks → provisioner.
