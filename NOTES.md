# Build notes

## Session state — paused 2026-07-03

**Where we are:** PRs 0–5 merged to `main`. PR 6 was split into 6a/6b.
- **PR 6a** (Vocabulary + CleanupEngine seam + CleanupPrompt + SmartCleanup) is
  COMMITTED on branch `pr-6-cleanup` (`5f58ddc`), 104 tests green, lint clean,
  app launches. **Unpushed — awaiting Mauria's review + okay to merge.**

**What's next (in order):**
1. Push `pr-6-cleanup`, open PR #6a, Mauria reviews + merges.
2. Start PR 6b from merged main: write the first-party **QwenTokenizer**
   (byte-level BPE) — golden-tested against `build/6b-hold/tokenizer-golden.json`
   (58 adversarial cases + ChatML, generated from the reference Qwen2Tokenizer).
   Then rewrite `MLXCleanup` to use it (dropping swift-transformers/MLXHuggingFace
   entirely — that path links network code, fails the zero-egress invariant),
   wire the model, dogfood real cleanup.
3. Then PRs 7–12 per PLAN.md.

**Held in `build/6b-hold/` for 6b** (NOT in git, NOT lost): `MLXCleanup.swift`
(the swift-transformers draft, to be rewritten), `gen-tokenizer-golden.py`,
`tokenizer-golden.json`, and `cleanup-llm/` (the 2.1 GB Qwen model, moved out of
Resources so 6a doesn't bundle it). `scripts/fetch-models.sh` cleanup section and
the MLXHuggingFace project.yml dep were reverted for 6a; re-add for 6b (but 6b
uses the first-party tokenizer, so MLXHuggingFace likely NOT needed after all).

**Key 6b decision (settled with Mauria):** first-party tokenizer, NOT
swift-transformers (links URLSession → fails binary egress scan) and NOT the Rust
swift-tokenizers (plan rejects Rust crates). Research on others' failure modes is
captured — design rules: `unicodeScalars` not `Character` for BPE symbols;
scalar/UTF-16 offsets for special-token slicing (swift-transformers #210/#355);
`NSRegularExpression` compiled once, not Swift `Regex`; expand `(?i:)` to explicit
cases; NFC first; split special tokens before BPE; integer-ID min-heap merge loop;
match the REFERENCE runtime (Qwen's shipped regex is officially buggy), enforced
by the golden corpus.

## Model timeline (Mauria noticed the switch went unmarked)

- **PR 0 + PR 1 setup:** Claude Fable 5.
- **Mid-PR 1 → PR 2 authored (2026-06-13):** switched to Claude Opus 4.8 (1M ctx)
  — "the government shut down fable."
- **PR 2 review → PR 4.5 (2026-07-02/03, "welcome back" stretch):** Fable 5,
  per Mauria's confirmation — the PR 2 second-pass review + fixes, PR 3
  (audio/VAD), the tap-callback crash fix, PR 4 (ASR engine), and PR 4.5 (the
  draft track) were one continuous Fable session.
- **Somewhere around PR 5/6a:** silently became Opus (Mauria's observation,
  2026-07-03). Exact turn undetermined — no marker was emitted, and the model
  can't reliably self-detect mid-session. PR 5 (TokenStream + adversarial
  review) and PR 6a (cleanup seam) are the plausibly-Opus span.
- **2026-07-03 (evening):** Mauria switched back to Fable 5 via /model. Fable
  re-verified the suite (104 tests), reviewed PRs 3–6a fresh (findings below in
  session state), and resumed. Also fixed a handoff error: three 6b artifacts
  had been parked in /tmp (volatile) instead of build/6b-hold — rescued.

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

## Carried forward to PR 11 (Settings)

From the second-pass review of PR 2 (Fable, 2026-07-02) — two menu/UX nits that
belong with the Settings work rather than the hotkey PR:

1. **Menu label wrong when capability is ready but the monitor isn't started**:
   `refreshMenu` falls through to "Grant Accessibility…" even though clicking it
   just calls `start()`. Needs a distinct "Enable hotkey" label/state.
2. **Menu goes stale on external grant**: capability is only re-evaluated at
   launch and after menu actions. If the user grants Accessibility directly in
   System Settings, the menu keeps showing the grant item until clicked. Fix
   with `NSMenuDelegate.menuNeedsUpdate` (re-evaluate on menu open) when the
   menu is rebuilt for Settings.

## Carried into PR 5 (TokenStream) from draft-track field testing

- Draft/final seam dedup: finals can start mid-phrase (leading commas, word
  overlap with adjacent drafts). PLAN already assigns seam tolerance to
  TokenStream; the field logs from 2026-07-03 are good fixture material.
- Tiny-tail draft suppression: the first draft of a fresh window decodes <2 s
  of audio and can be junk. Consider a minimum-tail threshold (~1.5 s) before
  emitting drafts — tune where display consequences are visible.
- Post-commit stragglers: the engine's flush emits a last draft/final after
  commit; TokenStream's generation checks must drop these (they arrive after
  the snapshot).

## Environment prerequisites discovered

- **Metal Toolchain** is required to build the mlx-swift dependency (it compiles
  Metal kernels). Install once with `xcodebuild -downloadComponent MetalToolchain`.
  This is a one-time dev-toolchain component (like Xcode itself), not part of the
  project's SPM resolve or app build, and not runtime network egress.
- Keychain needed Apple's **WWDR G3 intermediate** certificate imported before the
  free Apple Development identity validated for code signing.
