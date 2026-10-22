# vizpr

A local, on-device, streaming dictation app for macOS. Hold or tap the Fn key,
speak, watch a live transcript in a floating HUD (glass, an opaque animated slab,
or a look of your own), and on release the text
is injected into the focused app. You proofread as you speak — what the overlay
shows at the moment you stop is exactly what gets injected. The overlay also
shows the icon of the app that will receive the text (and, if you like, its
name); Settings → Behavior → Show target app turns that off or adds the name.

- ASR: Parakeet TDT 0.6B v2 (CoreML / Apple Neural Engine) via FluidAudio
- Cleanup: local LLM (Qwen3-4B-Instruct-2507) via mlx-swift-lm
- Menu-bar app, macOS 15+, Swift 6 strict concurrency
- **No network, ever.** No telemetry, no transcript persistence.

## Building

Requirements: macOS 15+, Xcode 26 SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and optionally [SwiftLint](https://github.com/realm/SwiftLint)
(`brew install swiftlint`).

```sh
./scripts/bootstrap.sh        # generates Vizpr.xcodeproj from project.yml, resolves deps
open Vizpr.xcodeproj          # or build from the command line:
xcodebuild -project Vizpr.xcodeproj -scheme Vizpr -configuration Debug build
```

The Xcode project and `Vizpr/Info.plist` are generated from `project.yml` and are
gitignored — `project.yml` plus the Swift sources are the source of truth. Run
`scripts/bootstrap.sh` again whenever `project.yml` changes.

Debug builds include a compile-gated dev transcript logger (`DICT_DEV_LOG`);
Release builds exclude it entirely.

## Design

`design/renders/` holds rendered stills of the overlay's looks, committed so the
look's evolution is visible in history. `design/references/` holds inspiration
images; they are third-party work, so the folder is gitignored and stays local.

A look can use any installed font, and any `.ttf`, `.otf` or `.ttc` file you put in
`~/Library/Application Support/Vizpr/Fonts` (Settings → Appearance → Open Fonts
Folder). Those fonts load into Vizpr only and are never installed system-wide;
Reload Fonts picks up files added while the app is running.

## Installing (for others)

This app is not notarized. To run a downloaded build, macOS Sequoia requires you
to allow it once under **System Settings → Privacy & Security → Open Anyway**.
Because the app requests microphone and Accessibility access (system-wide text
injection), the most trustworthy path is to **build it yourself** from source as
above — Xcode signs it with your own local identity and Gatekeeper stays quiet.

## License

vizpr is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md):
**free for personal and noncommercial use** (hobby, study, personal
productivity, charitable/educational/government organizations), and free to
modify and share on the same terms. **Any commercial use requires a paid
commercial license** — contact mauria.d.parker@gmail.com.

Bundled third-party components keep their own licenses; see
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
