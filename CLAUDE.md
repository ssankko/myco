# Myco

A macOS menu bar app (Swift 6 package, no Xcode project) that plays one audio stream to many outputs and mixes many microphones into one input. `ARCHITECTURE.md` explains the driver, the engine and the app; `DESIGN.md` is the visual design guide.

## Working here

- `make build` assembles `dist/Myco.app`; `make install` needs an administrator prompt, so never run it from an agent.
- `swift test --filter "MycoDSPTests|MycoTests"` needs no hardware. `make test-capture` runs everything in a Terminal.app window and needs the driver installed and a microphone; quit Myco first (`pkill -x Myco`).
- Tests must not depend on which devices are connected or enabled.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
