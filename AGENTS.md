# Flux Repository Rules

## Scope

These rules apply to the entire Flux repository. Inherit the user's global
agent rules; this file only narrows project-specific engineering choices.

## Product Contract

- Flux is a native macOS keyboard-first navigation utility.
- The frozen product behavior lives in
  `docs/superpowers/specs/2026-08-09-flux-design.md`.
- ARES is an ordinary launch target. Do not add ARES-specific integration.
- Do not recreate all of Karabiner-Elements. Implement only the mappings and
  navigation behavior named in the frozen design.
- Do not add Vim-style letter overlays, command palettes, workspaces, telemetry,
  accounts, synchronization, or cloud services.

## Engineering Contract

- Use Swift 6, Swift Package Manager, AppKit, ApplicationServices, and
  CoreGraphics. Do not add third-party runtime dependencies without explicit
  approval.
- Keep platform event handling behind small protocols so key routing, spatial
  scoring, and context history remain unit-testable without macOS permissions.
- Source-code identifiers, comments, test names, and commit messages are in
  English. User-facing copy and documentation may be Chinese.
- Treat Accessibility and global input interception as privileged boundaries.
  Never alter System Settings, launch-at-login state, Karabiner configuration,
  or another app's files automatically.
- A crash or disabled event tap must leave the physical keyboard usable.
  Synthetic events must carry a private marker and must not be reprocessed.

## Verification

Run the narrowest relevant checks during development and the full local gate
before handoff:

```bash
./scripts/test.sh
swift build -c release
./scripts/build-app.sh
./scripts/smoke-test.sh
```

Real-device acceptance must be reported separately from unit/build evidence.
Never claim Accessibility, application switching, or global key interception
works solely because compilation succeeded.

## Git and External Workers

- Preserve unrelated work and use one writer per owned path.
- External workers may edit only an explicitly assigned linked worktree and may
  not commit, merge, push, publish, deploy, or change credentials.
- Codex reviews and verifies every worker diff, creates the small feature
  commits, and is the only actor allowed to push this repository.
