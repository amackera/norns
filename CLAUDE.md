# Automaton

## Project Overview

Agent builder and hosting platform. Users build, test, debug, and interact with AI agents through a chat-first interface.

## Tech Stack

- **Backend/Frontend:** Elixir, Phoenix LiveView
- **Database:** PostgreSQL
- **Styling:** Tailwind CSS (Phoenix default)
- **Background Jobs:** Oban
- **Agent Processes:** OTP GenServers with supervision trees

## Conventions

- Follow standard Phoenix project conventions
- Use LiveView for all interactive UI — no separate frontend framework
- Keep contexts (Ecto schemas + business logic) in `lib/automaton/`
- Keep web layer (controllers, live views, components) in `lib/automaton_web/`
- Minimal, clean code — avoid over-engineering

## Architecture Notes

- Sleeping/idle agents are database rows, not running processes
- Agents are hydrated into GenServers on trigger, terminate when done
- Oban handles scheduled triggers and long-running deterministic work
- OTP supervision trees provide fault tolerance
- All external integrations implement a common inbound behaviour
- Agent-to-agent trigger chains must have depth limits to prevent loops
