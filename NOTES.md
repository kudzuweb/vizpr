# Build notes

## Session state — 2026-07-03 (evening)

**Where we are:** PRs 0–6a merged to `main`. **PR 6b is done and field-tested**,
on branch `pr-6b-cleanup-engine` (unpushed, awaiting Mauria's okay):
- `7d2759c` — first-party QwenTokenizer (all 58 golden cases pass against the
  reference Qwen2Tokenizer) + MLXCleanup on mlx-swift-lm; full live wiring.
- `5fcff20` — engine warms parallelized; dictation no longer gated on warmup
  (single-flight `prepare()` on both engines; sessions await it internally).
- 111 tests / 20 suites green. Dogfood log (2026-07-03 19:07) verified: WYSIWYG
  commit byte-exact, live cleanup rewrote the display in place, a post-commit
  straggler final was correctly dropped by the generation gate.

**What's next (in order):**
1. Mauria's okay → push `pr-6b-cleanup-engine`, open PR, merge.
2. Delete `build/6b-hold/` (its artifacts are all in the repo/bundle now).
3. PR 7 (dev logger, §14): JSONL appender incl. cleanup disposition records
   (`applied|stale|cancelled`) — the designated fix for SmartCleanup's `try?`
   error swallowing. Then PRs 8–12 per PLAN.md.

**Handoff doc:** `HANDOFF.md` (repo root, gitignored) carries the full resume
state, agreements, and solved-problem catalog for a fresh session.

**Key 6b decision (settled with Mauria):** first-party tokenizer, NOT
swift-transformers (links URLSession → fails binary egress scan) and NOT the Rust
swift-tokenizers (plan rejects Rust crates). Research on others' failure modes is
captured — design rules: `unicodeScalars` not `Character` for BPE symbols;
scalar/UTF-16 offsets for special-token slicing (swift-transformers #210/#355);
`NSRegularExpression` compiled once, not Swift `Regex`; expand `(?i:)` to explicit
cases; NFC first; split special tokens before BPE; integer-ID min-heap merge loop;
match the REFERENCE runtime (Qwen's shipped regex is officially buggy), enforced
by the golden corpus.

## PR 8 — Injection (adversarial review, 2026-07-04)

Three review lenses (spec/WYSIWYG, races/pasteboard-security, concurrency/API)
before commit. Real findings fixed in the same PR:

- **Inline 300 ms restore stalled the action loop** (would eat the first
  300 ms of a rapid re-dictation) → restore runs as a tracked child task;
  the NEXT inject awaits it before writing, so back-to-back dictation can't
  defeat the prior restore.
- **CGEvent.post silently no-ops without Accessibility** (false success →
  fallback never tried → restore clobbers the dictation) → postPasteChord
  gates on AXIsProcessTrusted(), untrusted now routes to the fallback.
- **org.nspasteboard conventions**: our write is marked TransientType
  (clipboard managers don't record dictation); concealed clipboard content
  (password managers) is never snapshotted or restored; snapshots skip
  promise-backed and marker types.
- **.privateState event source** so physically-held secondary-chord modifiers
  can't contaminate the synthesized Cmd+V.
- **Cancellation no longer restores EARLY** (app-terminate mid-delay raced
  the target app's paste) — cancelled restore = no restore.
- **Atomic restore claim**: clearContents()-returns-count verify, aborting if
  a writer raced between guard check and claim.
- Layout scan hardening: ASCII-capable input source (CJK input methods),
  withExtendedLifetime (interior-pointer UAF), NoDeadKeysMask (bit vs mask),
  accepts V as well as v, Unmanaged.fromOpaque + bindMemory.
- Spacing memory resets on cancel and secure-input skip; combining-mark
  leaders never get a joiner; secure-input check outranks the empty check.
- Secure-input re-checked between chord failure and the slower fallback.
- Dev log never records text dictated at a password field.

**Manual matrix results (Mauria, 2026-07-04):** TextEdit ✓, VS Code ✓,
Terminal ✓, browser textarea ✓, password field skip+beep ✓ (beep confirmed
audible), clipboard restore ✓ ("works perfectly"). Dvorak: NOT yet tested —
the one open cell; layout-resolution path is review-hardened, retest
opportunistically or at PR 12. One field catch fixed in-PR: the secure-skip
breadcrumb leaked dictated text into debug.log (now redacted).

**Accepted risks (documented, not fixed):**
- "Chord posted but target app ignored it" is undetectable without AX; the
  fallback fires on untrusted/creation-failure only. The PR 8 manual matrix
  (Terminal/Electron) decides whether a per-app fallback list is needed.
- NSAppleScript fallback is synchronous through the first-use Automation TCC
  prompt (freezes the run loop until answered). Rare path; pre-grant during
  onboarding lands with PR 12.
- NSSound.beep can be inaudible (muted alerts); the visible notice is PR 9's.
- Secure-input TOCTOU between probe and HID delivery is inherent; window is
  microseconds on the chord path, re-checked before the fallback.

## Dev-log analysis notes (PR 7, for prompt tuning later)

- **`stale` near a commit timestamp usually means "cancelled, politely":**
  mlx-swift's decode loop can notice cancellation and end its stream
  gracefully instead of throwing, so clean() returns a truncated result and
  the generation gate drops it as `stale` (observed live: gen-9 record,
  2026-07-04 dogfood). True `cancelled` appears when the throw wins the race.
  Either way the result never reached the display.
- Dictation records are the WYSIWYG-lag signal: e.g. injected "we're gonna
  head into it." vs raw flush "we're gonna end the tap." — the engine's
  correction landed just after commit. Feedstock for the PR 9 settle-window/
  felt-experience verdict.

## PR 9 design candidate: flush-settle window (Mauria's proposal, 2026-07-04)

Close the WYSIWYG-lag gap by holding commit briefly after release: overlay
stays up, the ASR flush updates the draft (intermediate color), THEN snapshot
and inject. Mechanism: commit awaits session-drained (the PR 7 hook — fires
exactly when flush events are delivered) OR a ~350 ms cap, whichever first.
Measured flush latency after release: 144–212 ms (2026-07-04 dogfood), so
drain wins the race in practice.

- WYSIWYG preserved as displayed==injected; "at stop" becomes "at stop +
  settle" — a §15 amendment to record if adopted (pending Mauria's call).
- Cleanup stays STRICT-CANCEL (unbounded LLM decode; the §15 rejection of a
  cleanup grace period is untouched). The settle applies only to the bounded
  ASR flush.
- Tune with the overlay in PR 9 (timing + intermediate color are one felt
  experience); judge with the dev log's raw-vs-injected gap before/after.
- **Confirmed motivating case (PR 8 field test, 2026-07-04): short
  utterances are LOST today.** Quick tap-speak-release under ~2 s commits
  before the first draft decodes → display empty → `skippedEmpty` → the
  speech vanishes ("Oh hell yeah" ×3; Mauria had to learn "hold the key
  down a little bit longer after I stop talking"). The settle window fixes
  exactly this: commit awaits session drain, the flush populates the
  display, the snapshot is non-empty. This upgrades the settle window from
  accuracy polish to a data-loss fix.
- ADOPTED in principle (Mauria, 2026-07-04): settle may run slightly longer
  than the minimum as long as it never *feels* slow. Her design rationale,
  verbatim intent: the color is the trust contract — her complaint with other
  cleanup apps was "no idea I was proofreading a draft or what was subject to
  change, so I'd send it and then see something I'd have wanted to change."
  Rule for PR 9: anything that can still change MUST be visibly intermediate;
  anything final-colored is guaranteed immutable. Never let text change after
  it reads as final.

## Carried to PR 9 (overlay) from 6b dogfood, 2026-07-03

- **Window-boundary word truncation:** window 1's final arrived as
  "**m** everything…" — the 10 s window split mid-word ("Um" → "m"). Cleanup
  happened to repair it, but the seam itself is the tiny-tail/seam-tuning item
  already parked for PR 9; the dogfood log is fixture material.
- **Raw tail at commit (by design):** trailing live text ("Um see, yeah, um")
  committed uncleaned because commit strictly cancels in-flight cleanup. The
  felt-experience verdict on this (and cleanup latency overall, incl. the 1.7B
  fallback question) is scheduled for PR 9, where display makes it visible.

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

3. **Clipboard-keep toggle (Mauria, PR 8 field test):** "a setting where you
   can have the transcript stay in the clipboard for pasting." Already
   provisioned: §14 lists a clipboard-restore toggle and
   `TextInjector.restoreEnabled` is the wired flag — the pane just exposes
   it (restore ON = clipboard comes back; OFF = transcript stays).


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
