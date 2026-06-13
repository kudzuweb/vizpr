# Build notes

## Model authorship handoff

- **PR 0 (latency spike)** and the **initial setup of PR 1** (environment checks,
  signing identity, XcodeGen install, module-folder scaffold) were authored by
  **Claude Fable 5**.
- On **2026-06-13**, mid–PR 1, work transitioned to **Claude Opus 4.8**, which
  took over at the project-definition step: `project.yml`, the app sources
  (`AppDelegate`, `TranscriptLogger`), the build scripts, and all build/test/
  verification work for PR 1 onward.

## PR 2 — HotkeyMonitor (over-invest)

Per the plan, PR 2 got adversarial review before commit. Three independent Opus
reviewers (concurrency/races, fail-open safety, spec conformance) audited the
pure machine, the tap shell, the permission probe, and the tests. Real findings
fixed in the same PR:

- **Use-after-free (critical):** the tap held an unretained pointer to the
  monitor with no `deinit` teardown. Added a `deinit` backstop.
- **Stale edge state (medium):** `tapDisabled`/watchdog re-enable reset the
  machine but not the shell's Fn-edge tracking, so a missed up-event could strand
  `fnDown` true and swallow the next Fn press (globe fires, no dictation).
- **Dropped secondary edge (medium):** `handleFlagsChanged` early-returned after
  the Fn edge, losing a simultaneous secondary-combo edge.
- **False "granted but dead" (medium):** the permission probe reported a
  freshly-granted but idle tap as needing relaunch.

The two edge-tracking bugs lived in the untestable shell, so the fix extracted
the edge logic into a pure `FlagEdgeTracker` with its own unit tests — turning
shell logic the property tests couldn't reach into tested value-type code.

## Environment prerequisites discovered

- **Metal Toolchain** is required to build the mlx-swift dependency (it compiles
  Metal kernels). Install once with `xcodebuild -downloadComponent MetalToolchain`.
  This is a one-time dev-toolchain component (like Xcode itself), not part of the
  project's SPM resolve or app build, and not runtime network egress.
- Keychain needed Apple's **WWDR G3 intermediate** certificate imported before the
  free Apple Development identity validated for code signing.
