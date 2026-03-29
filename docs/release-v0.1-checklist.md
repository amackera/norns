# Norns v0.1 Release Checklist

## 1) Version + changelog
- [ ] Bump version in project metadata
- [ ] Add `CHANGELOG.md` entry for v0.1
- [ ] Tag release (`v0.1.0`)

## 2) Runtime/API contract freeze
- [ ] Confirm 2-week freeze window completed (protocol payloads, AgentDef schema, failure inspector shape)
- [ ] Document any exceptions and migration notes

## 3) Test + quality gates
- [ ] `mix test` passes in Docker
- [ ] Replay/idempotency conformance tests pass
- [ ] Tenant isolation/auth tests pass

## 4) Docs and examples
- [ ] README quickstart verified from clean environment
- [ ] SDK links verified (Python, Elixir, hello-agent, Mimir)
- [ ] Architecture + SDK plan docs current

## 5) Release ops
- [ ] Create GitHub release notes
- [ ] Include known limitations and next priorities
- [ ] Announce in README/discussion/discord

## 6) Post-release sanity
- [ ] Verify dashboard and API health on fresh boot
- [ ] Verify orphan run recovery path
- [ ] Capture first external feedback issues
