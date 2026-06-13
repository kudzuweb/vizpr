# Build notes

## Model authorship handoff

- **PR 0 (latency spike)** and the **initial setup of PR 1** (environment checks,
  signing identity, XcodeGen install, module-folder scaffold) were authored by
  **Claude Fable 5**.
- On **2026-06-13**, mid–PR 1, work transitioned to **Claude Opus 4.8**, which
  took over at the project-definition step: `project.yml`, the app sources
  (`AppDelegate`, `TranscriptLogger`), the build scripts, and all build/test/
  verification work for PR 1 onward.

## Environment prerequisites discovered

- **Metal Toolchain** is required to build the mlx-swift dependency (it compiles
  Metal kernels). Install once with `xcodebuild -downloadComponent MetalToolchain`.
  This is a one-time dev-toolchain component (like Xcode itself), not part of the
  project's SPM resolve or app build, and not runtime network egress.
- Keychain needed Apple's **WWDR G3 intermediate** certificate imported before the
  free Apple Development identity validated for code signing.
