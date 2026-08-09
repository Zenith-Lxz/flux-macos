# Flux v1 Release Evidence — 2026-08-10

This record separates automated proof from the real-machine acceptance that
still requires the owner's point-of-execution authorization. It is not a
release-complete claim.

## Candidate identity

- Source commit: `2c352492d54bb21a6433cb73a5a3720a55b3ac01`
- Remote: `https://github.com/Zenith-Lxz/flux-macos`
- Branch: `main`
- Bundle: `dist/Flux.app`
- Bundle identifier: `com.zenith.flux`
- Version/build: `1.0.0 (1)`
- Signing: ad-hoc
- Executable SHA-256:
  `09a1f0c89708397d3390f7a4e28c545289038e931f5cee90532be941e5575d3a`
- Complete file manifest: `dist/Flux.app.sha256`
- Build metadata: `dist/build-info.txt`

The candidate must not be rebuilt between this record and real-machine
acceptance. A rebuild changes the ad-hoc identity and may require new macOS
Accessibility or Input Monitoring grants.

## Automated evidence — passed

The following commands passed against the source commit above:

```bash
./scripts/test.sh
./scripts/build-app.sh
./scripts/smoke-test.sh
```

Observed result:

- 403 tests in 93 suites passed.
- Release product compiled and `dist/Flux.app` was assembled.
- The staged app and a metadata-clean copy of the published app passed
  `codesign --verify --deep --strict`.
- The published bundle matched `dist/Flux.app.sha256`.
- Info.plist, bundle identifier, LSUIElement, arm64 Mach-O, version, and
  signing-method checks passed.
- The exact verified app completed a real AppKit startup with permissions
  forced unavailable, installed no HID/event-tap input path, printed the
  success marker, and exited within the smoke-test watchdog.
- The public remote `main` matched the source commit when the candidate was
  built; this evidence document was the only untracked repository file.

## Independent review

Hermes performed a bounded read-only specification audit and a second targeted
review of the final boundary/feedback changes. Codex independently verified
every reported item; the targeted review found no correctness or safety
regression:

- Event-tap recovery now verifies the enabled state and fails closed.
- No-permission startup is now an executable smoke test, not a static bundle
  inspection.
- An empty single-Caps Return now shows brief status-bar feedback.
- The current Apple SDK documents that setting AX messaging timeout on the
  system-wide object applies the timeout globally for the current process;
  no timeout defect remained.
- The approved `EventTapProviding`, `AXTreeReading`,
  `FrontmostAppProviding`, and `EventPosting` boundaries are injected and
  have permission-free substitute tests.
- Pause status now outranks the transient empty-Return indicator, so the
  keyboard escape state is immediately visible even during the 0.8-second
  feedback window.

## Real-machine evidence — pending

The app cannot be called “normally usable” until all items below pass with
the hash-bound candidate and Karabiner's overlapping mappings temporarily
disabled without uninstalling Karabiner or changing its configuration:

- [ ] Single Caps switches Codex ↔ Chrome and Chrome ↔ WeChat ten times each.
- [ ] All eight direct-app shortcuts work for running and stopped apps and
      restore the most recent window.
- [ ] Spatial focus works in Chrome, Hermes, Lark, and Finder; the focus ring
      remains non-activating and unobtrusive.
- [ ] WPS pointer fallback supports movement, acceleration, snapping, single
      click, and double click.
- [ ] Text-editing, Chrome, input-source, and ARES/terminal mappings match the
      approved table.
- [ ] Physical Caps never changes Caps Lock state.
- [ ] Pause/resume, quit, crash simulation, and event-tap disable leave the
      physical keyboard usable.
- [ ] Missing permissions show the correct state and swallow no keys.
- [ ] The installed copy preserves the recorded file manifest and passes
      signature verification after metadata-clean copying.
- [ ] The real `SMAppService` launch-at-login state, approval/error behavior,
      disable path, and logout/login behavior pass without a LaunchAgent
      fallback.

## Authorization boundary

As of this record, Karabiner remains running and `/Applications/Flux.app`
does not exist. Installation, launching the ordinary input path, changing
Karabiner runtime state, granting permissions, and logout/login testing are
not covered by automated verification and require the owner's current
authorization.
