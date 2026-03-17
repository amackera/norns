# UX Design

## Principles

- **Chat-first** — the chat interface is the primary way to build, configure, and interact with agents
- **Minimal** — sparse, clean, no clutter
- **Monochrome** — simple color scheme with sparse, intentional color accents
- **Blueprint aesthetic** — subtle grid influence, like an architectural drawing or engineer's blueprint

## Chat Interface

The chat interface serves three roles:

1. **Builder** — create and configure agents through conversation ("create an agent that monitors my PRs")
2. **Configuration** — modify agent settings via chat ("add this Slack token to the PR agent")
3. **Interaction** — talk directly to a running agent ("summarize yesterday's activity")

### Context Switching

The chat defaults to a **builder context**. To talk to a specific agent, you explicitly enter that agent's context — like SSH-ing into a machine. This keeps the boundary clear between "I'm configuring things" and "I'm talking to an agent."

## Agent Management

Agents can also be configured through a simple web UI:

- View agent status (inactive / idle / running)
- Edit name, purpose, prompt
- Configure integrations (add Slack token, set up GitHub webhook, etc.)
- View run history and logs
- Start / stop agents

The web UI and chat interface are equivalent — anything you can do in one, you can do in the other.

## Visual Language

- Monochrome base with minimal accent colors for status indicators
- Subtle grid lines as a background texture
- Clean typography, generous whitespace
- Status colors: muted and functional, not flashy
