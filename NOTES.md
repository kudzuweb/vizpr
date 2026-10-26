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
browser textarea ✓, password field skip+beep ✓ (beep confirmed audible),
clipboard restore ✓ ("works perfectly"). **Terminal: UNVERIFIED** — the ✓
was inferred from the .injected outcome, but Mauria's pastes targeted the
window running log stream, which doesn't echo tty input; retest at a clean
shell prompt in the PR 9 dogfood. If .injected + no text at a prompt, the
"chord posted but ignored" gap is real and the per-app fallback list
becomes a work item. Dvorak: NOT yet tested —
the one open cell; layout-resolution path is review-hardened, retest
opportunistically or at PR 12. One field catch fixed in-PR: the secure-skip
breadcrumb leaked dictated text into debug.log (now redacted).

**Restore rule (2026-10-21, after two lost dictations):** the prior clipboard
is restored only when the focused element plausibly accepted the paste.
Twice a commit landed with focus on a window with no text field (once
mid-drag of a screenshot): the chord was posted, the outcome was `.injected`,
and the 300 ms restore deleted the only other copy of the text. A paste
cannot be observed, so `FocusedFieldProbe` (Injection/SystemInjectionIO.swift)
makes one read-only AX query of the frontmost app's focused element, off the
main thread, started before the chord so it adds nothing to the commit path.
It counts as text-accepting when the element exposes
`kAXSelectedTextRangeAttribute`, has a settable `kAXValueAttribute`, or has
role text field, text area or combo box. Each AX call is bounded to 150 ms.
- The paste is attempted either way: terminals and Electron apps accept
  pastes while exposing poor AX trees, and a paste into a non-text window is
  harmless. Only the restore changes.
- Unknown counts as not accepting (AX error, no focused element, timeout):
  losing the old clipboard is the cheaper failure.
- When the restore is skipped for this reason the outcome is
  `.injected(usedFallback:clipboard: .keptNoTextField)` and the commit
  handler beeps once so she knows the text is on the clipboard. The setting
  off or concealed clipboard content give `.notCaptured` (no beep, no probe).
- Secure-input skip, the concealed-content rule and the ownership guard are
  unchanged.
- Unverified: the heuristic's accuracy across real apps (no web-content
  editable role exists in the AX headers; web editors are expected to pass
  through `kAXSelectedTextRangeAttribute`).

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

## PR 9 — Overlay (adversarial review, 2026-07-04)

Three lenses (focus/spec, concurrency/lifecycle, rendering/WYSIWYG). Fixed
in-PR: overlay rendered a RECONSTRUCTION of the display string (synthetic
joiner + plain-space draft join) instead of the exact bytes commit injects —
now renders settled + DisplaySnapshot.mutableSuffix verbatim; SettleGate
drains are epoch-keyed (stale drains from cancelled/capped sessions reopened
the quick-tap hole) and a cancelled timeout no longer fires resume; dismiss
fade racing a rapid re-show no longer blanks the new session; post-commit
stragglers can't repaint over dismissal; resting capsule width lives in
SwiftUI (was dead code); tail-follow re-pins on size changes; capsule-shaped
clipping; measurement short-circuits past the cap; window shadow off;
willTerminate unparks the settle waiter. Seam duplication fixed:
filler-tolerant overlap match (uh/um skipped in alignment, single-word match
allowed modulo trailing punctuation), pinned by field-case regressions.

**Second dogfood round (2026-07-05) caught two more, fixed + pinned:**
- **Cleanup context echo (serious):** the 4B model copied the settled-context
  tail into its rewrite; the echo duplicated a settled paragraph on screen AND
  in the commit. Structural fix: SeamMerger.stripContextEcho removes a leading
  echo (≥3 tokens, or the whole context verbatim) before applyCleanup; output
  that is echo-only fails open (live text survives, disposition=failed).
- **Contraction seam miss:** "going to" / "gonna" broke overlap alignment
  (words rendered twice); alignment now expands contractions (gonna/wanna/
  gotta/kinda/sorta/dunno).
- **Known artifact (recorded, not fixed): mid-word seam fragments.** A
  windowed final can cut INSIDE a word ("dict|ation"); the orphan fragment
  glues badly ("Theation", observed committed 2026-07-05). Token alignment
  can't see sub-word splits; candidate fix is fragment-aware gluing at the
  seam. Rare and cosmetic — future seam-tuning item.
- Felt-experience data: first draft appears ~2.5-3 s into a session (VAD arm +
  1.5 s min-tail + decode) — Mauria asks if it can be faster; min-tail is the
  lever, junk-draft risk is the cost → PR 11 tunable. Confirmed-color latency
  (~10 s+) is inherent to the locked sliding-window config; the trust color
  just makes it visible now.

**Accepted risks / deferred:** NSScreen.main is not "the active app's
display" for an LSUIElement app — multi-display placement lands with PR 10's
AX reader (single-display is correct today). Inline settle+restore awaits can
delay a rapid next mic start ~350-650 ms worst case — field-judge before
restructuring. failLoudly's modal can activate the app mid-session (rare,
terminal path). Screen-change mid-session not re-laid-out. `.secondary`
contrast over bright desktops in dark mode — check in dogfood.

**Color revisit (Mauria):** overall palette to be revisited at PR 11; the
intermediate-color trust mechanism itself is approved. The #A16FDF@13% tint
is §15-locked — reopening it there is a deliberate decision, not drift.

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

## Hotkey classified by event time, on its own thread (2026-10-23)

Field problem: the first Fn press after launch was sometimes misclassified (a
quick tap read as a hold, or the reverse). `debug.log` on 2026-10-21 at 01:22 and
01:56 EDT shows it. The event tap ran on the main run loop, which a cold
`AVAudioEngine.start()` blocks for about 2 s, so the callback was serviced late;
edges were stamped when they were handled, so a tap whose release was handled
late measured as long. A threshold timer that had already promoted the press to
`holding` also made the late release commit instead of latch.

- The tap source, the threshold timer and the watchdog run on a dedicated
  run-loop thread (`HotkeyRunLoopThread`, named `app.vizpr.hotkey`). The monitor's
  entry points hop onto it. `stop()` waits for teardown, bounded at 2 s, so a
  wedged thread cannot hang a permission flow or app quit. The tap port is shared
  with `isTapHealthy` behind a lock.
- Edges are classified by the event's own timestamp (`EventTimestamp`), which is
  nanoseconds since boot, the same clock as `nowMonotonic()`. The first version
  assumed mach ticks and scaled by the timebase; the first live run showed that
  put every stamp in the future, and the 2026-10-24 field log showed the raw stamp
  within 0.4 ms of uptime in nanoseconds. Commit 5e269ea removes the scaling.
- The stamp is used only if it is non-zero, not in the future, and at most 30 s
  old; otherwise the edge uses handling time, the old behavior. A zero stamp falls
  back even in the first 30 s after boot.
- In `holding`, a release runs the same duration check as in `pressed`, so a
  timer that fired late cannot turn a quick tap into a commit.
- `HotkeyInput.captureFailed` cancels from pressed, holding and latched and is
  inert from idle. `HotkeyMonitor.injectCaptureFailure()` feeds it from the audio
  side; nothing in this branch calls it yet.
- `stop()` clears the shared port on the caller's thread before the teardown is
  queued, and the teardown removes only the tap it stopped. A `start()` after a
  timed-out stop therefore creates a fresh tap that the older teardown leaves
  alone.
- `setSecondaryMask` runs on every settings change. An unchanged mask is now a
  no-op, and a changed one carries over `fnDown`, `secondaryActive` and the
  post-reset baseline state (`FlagEdgeTracker.replacingSecondaryMask`). Before,
  a settings change while Fn was held lost the Fn-up edge and left the session
  stuck.
- Debug builds log `hotkey event stamp:` once per launch, on the first Fn edge,
  with `converted` or `fell back to handling time` and the raw numbers. Numbers
  only, no typed text.

Fail-open invariant, unchanged: `.consume` is emitted only for Fn events. A
packet without an Fn edge is never deleted. A packet with an Fn edge is deleted
whole, including any secondary-combo edge in the same packet; that edge is still
processed by the machine, but the app that would have received it does not see
the packet.

Verification: the 2026-10-24 once-per-launch log line read `converted` on
Mauria's machine. In use on her machine since 2026-10-23 inside a combined dev
build.

Not exercised: `HotkeyMonitor` itself has no tests (the pure pieces do:
`HotkeyStateMachine`, `FlagEdgeTracker`, `EventTimestamp`, `HotkeyRunLoopThread`),
and `VizprTranscriptLogger` is now called from the hotkey thread rather than the
main thread.

## PR 10 — FieldContextReader (field matrix, 2026-07-05)

Matrix passed via JSONL verification: VS Code -> mode=code (surrounding nil,
Electron/AX expected), Terminal -> mode=code WITH real surrounding text (its
buffer is AX-readable), Chrome textarea -> mode=default (surrounding nil),
TextEdit -> default. Fail-soft acceptance held: context-less sessions fully
functional. Multi-display placement untested (single display); pure geometry
is table-tested.

## PR 11 design decisions (Mauria, 2026-07-05)

- **Tint:** keep #A16FDF @13% as the DEFAULT, expose a tint picker in
  Settings. This deliberately amends the §15 lock: the decision becomes
  "lavender default, user-tunable" rather than a fixed constant.
- **Text colors:** the settled/mutable pair is changeable — even derivable
  from the background tint like a theme — but their RATIO is locked: the
  contrast relationship between final and provisional text is the trust
  contract and no theme may collapse it. v1 shape: "System" theme (primary/
  secondary label colors, adaptive) or "Custom" (one base color; settled =
  base, mutable = base at a fixed opacity ratio).

## Inviz mode (Mauria, 2026-07-05 — implemented in PR 11)

No live transcript preview: a small theme-tinted "talking is happening"
pill mid-screen; text appears finalized in place at commit. An EXPLICIT
opt-out of proofread-as-you-speak (§ WYSIWYG's premise) — the pipeline
(settle window, commit snapshot, seams, cleanup) is unchanged; only the
rendering differs. Shares the active look's tint (PR 14).

## PR 14 — Looks replace color settings (2026-10-21)

The overlay's appearance is a **look**: a named bundle of surface (`glass` or
`slab`), corner radius, tint, tint strength, text base color, link-to-tint flag,
slab parameters, font design and size, and a word-appearance field reserved for
a later PR. This supersedes the PR 11 tint and text-theme settings and the
six color presets (the PR 11 decisions above still hold for what a look may
change: the settled:mutable ratio stays locked in
`VizprSettings.mutableOpacityRatio` and no look can alter it).

- Two built-ins, Glass (exactly the old defaults) and Slab (dark, with its own
  text color because system label colors turn black in light mode), are
  constants with fixed ids. They are never persisted and are read-only; a user
  duplicates one to edit it.
- `VizprSettings.looks` holds the user's looks (max 12). `activeLookID` picks
  the one rendered; an id that matches nothing resolves to Glass. Reset keeps
  the user's looks and returns the active look to Glass. The menu bar item
  "Look: <name>" cycles built-ins then user looks.
- Tint also colors the recording dot and the inviz pill on every surface.

**Loading merges the saved JSON over the defaults (bug fix).** `VizprSettings`
used synthesized `Decodable`, which throws `keyNotFound` for any key missing
from `settings.json`; `SettingsStore.init` answered by falling back to
`.default`. Adding any field therefore silently reset every setting for an
existing user. `SettingsStore` now parses the file, merges it over the encoded
`VizprSettings.default` (`SettingsMerge.merged`, recursing into nested objects
such as a look's `slab`) and decodes the result with plain synthesized
`Codable`. A new field needs no loading code: a file without it takes the
default. Saved `looks` have no default of their own, so each is merged over
`OverlayLook.mergeTemplate`. **A new look field's value in that template must be
its no-visible-change value** (an effect at 0, a feature off, the existing
behavior kept); built-in looks opt into new effects explicitly. Otherwise adding
a field would silently restyle looks Mauria already made.

Tradeoff: a wrong-typed value (`"autoStopSeconds": "soon"`) fails the whole
load. The file is first copied to `settings.json.bad` (replacing an earlier
copy) and defaults take over, so a bad load never destroys the saved settings.

**Migration.** A file with no `looks` key is read as legacy. Each legacy
`colorPresets` entry becomes a glass look (named by its tint hex when it had no
name). If the legacy top-level colors differ from the old defaults (`A16FDF`,
0.13, no text base, unlinked), they become a glass look "My colors", which
becomes active. Migration runs after the merge, from a separate decode of the
legacy keys, and the store saves once when the file carried any, so migrated
look ids stay stable and the legacy keys leave the file.

## Audio capture off the main thread, and the silent-mic check (2026-10-23)

A cold `AVAudioEngine.start()` blocked the main thread for about 2 s, which also
stalled the hotkey event tap. Capture start, stop and failover now run on one
serial queue owned by `CaptureEngineController`, which takes an engine factory
so its ordering is unit-tested with fake engines.

- `CaptureSource.start()/stop()` are not `@MainActor`. `stop()` returns at once
  and bumps a generation counter; a start or failover requested under an older
  generation does nothing when it reaches the queue, and a stop queued behind a
  start tears that start's engine down. No stop can leave a live engine for a
  cancelled session.
- The silent-microphone failover never fired as intended: it read the raw peak
  at chunk 5, but the tap measured the peak only every 8th buffer, so the peak
  read 0 on every route, including the built-in mic. The tap now measures every
  buffer. `SilentRouteDecision` fails over only when at least 1.3 s of measured
  audio (frames / hardware sample rate) is exactly zero, the route is positively
  identified as non-built-in, and no attempt was made. An unidentifiable input
  device does not trigger it.
- The failover builds and prepares the replacement engine before touching the
  running one, and returns `FailoverResult` (`switched`, `unchanged`, `lost`).
  `AudioPipeline.onCaptureFailure` fires when `source.start()` throws or a
  failover is `lost`. `AppDelegate` connects it to the hotkey: it beeps and
  calls `HotkeyMonitor.injectCaptureFailure()`, which cancels the session.
- Debug builds log `main stall Nms` when the main run loop is blocked over
  100 ms (`MainStallProbe`).

Known gaps, left as they are: a tap buffer with no `floatChannelData` is not
measured, so the stop-time silent-session notice would report silence while the
failover never fires; and an input device that disappears mid-session ends capture without a failover.
Not exercised on hardware: a real cold start, a second microphone, an AirPods
route.
## PR 15 — Sculptable looks (2026-10-21)

### Rendering

`OverlayLook.style` (`LookStyle`, `Vizpr/Overlay/LookStyle.swift`) holds every
adjustable aspect of a look beyond its surface body, and every field renders on
every surface. Every default is the no-visible-change value, so `.neutral` is
today's Glass and `OverlayLook.mergeTemplate` carries it.

| Group | What it does |
|---|---|
| `fill` | Frost: Glass gets `colorHex` at opacity `frost` over the material (0 is the old Glass); the new `solid` surface fills at `max(frost, 0.05)`. |
| `light` | One transparent layer (`LightLayer`, `PaneLight.metal`) over any surface: edge light, bevel, gloss (still highlight, matte 0 to shiny 1), moving sheen, grain. It draws nothing when all are 0 and ticks only for sheen or grain. |
| `border`, `outerGlow`, `dropShadow` | `PaneEffects`. |
| `pane` | Reading width and text padding. |
| `text` | Font family (system font in the look's design when unset or not installed), weight, line spacing, text glow. |
| `dot` | Recording dot color, size and pulse. |

`SlabStyle` is now only the mesh body. The built-in Slab look carries its old
light and shadow in `style.light` and `style.dropShadow`.

**Glow and shadow draw only outside the pane.** Each is a blurred copy of the
pane shape masked to the region outside the pane shape (`blendMode(.destinationOut)`
in a `compositingGroup`), because a copy left behind see-through glass would
tint its interior. The overlay panel grows on every side by the largest enabled
effect extent (`PaneEffects.margin(for:)`), and the pane's frame inside it does
not move.

**Backdrop.** `style.backdrop` (`BackdropLayer`) is a neutral dimming layer drawn
below the surface, light and border. The fill is both the glass's color and its
blocker, so raising its opacity to quiet busy content behind the pane turns the
glass into tinted plastic. The backdrop blocks without touching the glass: it
is a uniform `colorHex` at `strength` inside the pane, fading to nothing over
`feather` points outside it (a blurred, slightly grown copy of the pane shape,
masked to the outside like glow and shadow). It is off by default, and
`PaneEffects.margin(for:)` includes its reach when enabled.

**Measurement.** `OverlayLook.paneWidth(fitting:)` and `paneHeight(fitting:)` are
the one place that measures: width, padding, font, and line spacing (through
`NSParagraphStyle`) all come from the look, matching how `OverlayView` lays the
text out. The pill is 220 pt wide at rest and grows with the single-line text
width (plus padding and 2 pt of slack) up to the look's pane width; only then
does the text wrap and the pane grow taller. AppKit supplies the line count and
each line is priced at the height SwiftUI gives it, because `boundingRect`
alone runs about a point short per line. The height carries 2 pt of slack
under the last line, so the gap below equals the gap above to within that.
(The first version of the measurement added a whole extra line "so growth leads
the text"; with an accurate per-line height that headroom is no longer
needed.) The text is laid out at the final width and the capsule animates over
it, so it does not re-wrap mid-growth.

**Offscreen renders.** `NSHostingView.cacheDisplay` does not run Metal shader
effects, so the light layer is absent from such frames. `ImageRenderer` runs
them but cannot draw a `ScrollView`.
### Look editor and fonts

The Appearance pane edits every field of `LookStyle` (`Vizpr/Overlay/LookStyle.swift`,
held in `OverlayLook.style`) with sliders, toggles and color pickers, one file
per section in `Vizpr/App/Appearance/`. A live preview pinned above the
controls renders the real `OverlayView` with the active look over a checkerboard
while sample text types itself (`PreviewTranscript`); the typing runs in a
`.task`, so it stops when the tab is left, and closing the Settings window
releases the window and its views. Slider ranges live in `LookRanges` and a
test fails when one drifts from its field's `clamped()` bound.

**Fonts.** `FontLibrary` registers every `.ttf`, `.otf` and `.ttc` in
`Application Support/Vizpr/Fonts` at launch with
`CTFontManagerRegisterFontsForURL(url, .process, &error)`: Vizpr only, never
installed system-wide. A file that is already registered returns error 105
(`alreadyRegistered`), which counts as success. `NSFontManager.availableFontFamilies`
does not list a newly registered family until a later run-loop turn (the
CoreText family list does, at once), so `FontLibrary.families` adds the
families it registered itself. A look stores a family name in
`style.text.fontFamily`; nil is the system font in the look's `fontDesign`.

## Draggable overlay (Mauria, 2026-10-21)

**Focus invariant.** The overlay panel never takes keyboard focus and never
activates Vizpr: `PreviewPanel` is `.nonactivatingPanel` and `canBecomeKey` and
`canBecomeMain` return false. Click-through was dropped on purpose so the pane
can be dragged, so a click on the pane now lands on the pane and not on the app
behind it. The transparent stage around the pane takes clicks too.

**Dragging.** `DragHostingView` (`Vizpr/Overlay/DragHostingView.swift`) answers
every hit inside the panel and calls `PreviewPanel.drag(with:)`, which runs
`performDrag(with:)` and reports the new frame through `onDragEnd`.

**Placement (§13).** The pane is anchored by its bottom-center, stored as
fractions (`OverlayAnchor`, 0...1) of the display's visible frame, so a position
survives a resolution change. A nil anchor is the old lower-center
(0.5, 0.25). The pane grows upward from the anchor; its maximum height is the
smaller of half the screen and the distance from the anchor to the top of the
screen minus `OverlayLayout.topInset`, and its horizontal position is held
inside the screen. The effects margin wraps the pane and does not move it.
`OverlayLayout.anchor(forPaneFrame:)` is the inverse and pulls a frame dragged
partly off-screen back on.

**Persistence.** `VizprSettings.overlayAnchors` maps a display's UUID
(`NSScreen.displayUUID`, from `CGDisplayCreateUUIDFromDisplayID`) to its anchor.
The target screen is still chosen as before (the display holding the focused
window); that display's anchor positions the pane. Dropping the pane on another
display saves the anchor for that display. The inviz pill sits in the same
stage, so it follows the same anchor. The menu item "Reset Overlay Position"
clears every anchor.

## Target app indicator (Mauria, 2026-10-22)

The overlay shows the frontmost app's icon, and its name when asked, so it is
clear where the text will land (twice, dictation went to a window with no text
field). `VizprSettings.targetAppDisplay` is `off`, `icon` (the default) or
`iconAndName`, a global behavior outside the looks.

**Tracking.** `TargetApp` (`Vizpr/Overlay/TargetApp.swift`) observes
`NSWorkspace.didActivateApplicationNotification` from `OverlayController.show`
until `dismiss`, so focus moving mid-dictation moves the icon, because that is
where the commit now injects. Vizpr itself never replaces the target: its
Settings window in front keeps the last other app.

**Placement.** On the resting pill and the expanded pane the icon (24 pt)
is tucked into the top-left corner: it hangs 5 pt outside the pill's left and
top edges (`TargetAppMetrics.cornerOverhang`), whatever the corner radius, so
the 19 pt inside the pill sit within a point of the pane's default 18 pt
horizontal padding and the icon never covers the first line of text. It overlays the pill outside the
clip, so it changes neither the pill's size nor the text column.
`OverlayLook.panelMargin` is the larger of the glow/shadow reach and the
icon's overhang, and the panel, the view and
`dragEnded` all use it. With `iconAndName` the resting pill shows the name
(11 pt, the look's mutable style) inside the pill, starting just past the icon;
the expanded pane shows the icon only, because there is no room beside wrapped
text. The recording dot stays at the bottom left. The inviz pill (84 x 36) is
too small for the icon, so it keeps the badge outside its left edge (20 pt
icon, 6 pt gap, name when asked). Opacity is 0.85. Sizes live in
`TargetAppMetrics`.

**Margin.** Only inviz mode reserves `sideInset` on both sides of the pane for
the badge beside the pill, so the badge is not clipped and the pill stays
centered where it was; resting and expanded panels have no side inset.
`dragEnded` subtracts the same inset when it reads the pane's frame, so the
pane, not the badge, is what the anchor positions. Toggling inviz re-places
the panel.

## Future directions (Mauria, 2026-07-05 — recorded, not scheduled)

1. **Verbatim mode:** "I should be able to talk casually and have it show up
   how I said it, just like I can type it that way." Cleanup/normalization
   (and ASR inverse-normalization: gonna→going to, spoken numbers→digits)
   should be suppressible. Relates to §14's cleanup on/off toggle but goes
   further — verbatim fidelity is partly model behavior, so it needs its own
   design pass. The seam matcher's contraction expansion is ALIGNMENT-only
   (never rewrites surface forms) and stays regardless.
2. **PR 13 — optimization pass (post-PR-12):** bird's-eye latency audit of
   the whole harness once feature-complete. Constraints: MODEL-AGNOSTIC and
   ACCURACY-PRESERVING — "the fastest VTT harness for whatever model gets
   dropped in," fastest WITHOUT losing accuracy (speed gains that cost
   transcription quality are rejected): pipeline overhead,
   decode scheduling, draft cadence, settle timing, engine-swap cost — never
   model-specific tricks. Feedstock already exists: the dev JSONL timings and
   the PR 0 spike harness.
3. **Context-dependent vocabularies / "code switching" (Mauria,
   2026-07-05):** different dictionaries may work better in different
   contexts; switching between named vocabulary sets — eventually
   automatically (per-app, per-mode) — could be a signature dictation
   feature. **Hierarchical, not flat (Mauria's refinement): a GLOBAL
   dictionary plus context-specific ones, with definitions movable/
   propagatable between levels — "like a global claude.md and
   project-level, but for how to interpret speech in context."**
   **Refined design (Mauria): three layers with an indirection —
   (1) global, (2) named generic buckets the user creates ("coding",
   "casual", "professional email"), (3) app -> bucket assignments.**
   Dictionaries belong to CONTEXTS, not apps; apps are assigned to a
   context to inherit its dictionary. Resolution: global + assigned
   bucket, bucket wins conflicts. PR 11 ships the storage + per-session
   resolution (bundle id from FieldContextReader picks the bucket);
   bucket-management/propagation UI grows over time. **Plus manual
   override: hotkey CYCLING between dictionaries (Mauria) — resolution
   order is manual override > app assignment > global-only; a cycle
   chord rotates buckets (incl. back to automatic). Plus STYLE RULES per
   bucket (Mauria): buckets are full context profiles — casual = no
   caps, professional email = proper punctuation + expanded contractions
   — injected into the cleanup prompt when active (global rules +
   bucket rules, bucket last). Caveat recorded: prompt-enforced
   (best-effort on a 4B) and only where cleanup runs; a per-bucket
   "always clean" flag is the future lever for aggressive restyling.**
4. **Mistake-driven vocabulary capture (Mauria, 2026-07-07):** an easier
   way to add vocab from mistakes actually experienced, rather than typing
   entries cold. Shape TBD (she explicitly deferred designing it until the
   app is finished) — the dev JSONL's raw-vs-injected pairs are the obvious
   feedstock, and the injector's post-injection edit capture idea (parked
   in the plan) is adjacent.
5. **Preflight-edit toggle:** optionally edit the transcript before injection
   (hold at the overlay, edit, then commit). Motivating case: TUIs — can't
   select-and-delete in a terminal input line, only backspace. Interacts
   carefully with WYSIWYG (an edited preview is still displayed==injected)
   and with the overlay's non-activating panel (an editable field needs key
   focus — likely a separate activating edit window summoned on demand).
   Adjacent to the plan's parked "post-injection edit capture" idea.

## PR 13 — latency audit (2026-07-09, from the PR 12 dogfood log + code read)

Constraints (Mauria): MODEL-AGNOSTIC, ACCURACY-PRESERVING. Harness speed
only; anything trading transcription quality is rejected.

Measured budget, Fn-down → first preview (~2.1 s observed against a user
who starts speaking immediately; she waited ~0.4 s):

| Segment | Cost | Verdict |
|---|---|---|
| Fn-down → startDictation action | ~0 (fires at keyDown) | already optimal |
| action → capture start begins | ~245 ms | FIX: synchronous AX field read + session begins run BEFORE the pipeline starts; reorder so capture starts first, AX/overlay follow concurrently |
| capture setup (engine build, route query) | ~218 ms | PARTIAL: AVCaptureDevice.default device-name lookup is dev-log-only decoration on the hot path — move off. Engine build cost is real |
| engine.start() (HAL spin-up) | ~74 ms | leave (keeping the mic hot is a privacy non-starter) |
| speech → first draft | draftMinTailMs floor (1.5 s default) | leave — user lever, quality-bound (sub-1.5 s tails decode junk, field-observed); since 2026-10-25 a constant in `Tuning.swift`, see "Tuning values and single defaults" |
| draft refresh cadence | fixed 1 s + decode inline in the audio pump | DONE in PR 13: the cadence is adaptive with a 500 ms floor (a decode starts when the previous finishes and 500 ms of new audio has arrived), and decoding is decoupled from ingestion. Same decoder, same tail = accuracy unchanged |
| commit → inject | ~170 ms observed (settle window worked) | already good |
| engine swap (Models pane) | pipeline rebuild + warm | rare; acceptable |

Also: before PR 13 the dev JSONL carried no timings (the "feedstock" claim
in Future Directions was wrong). PR 13 adds session timing marks to the
dictation record (DICT_DEV_LOG builds only), so every dogfood measures
itself. Each `t_*` field is integer milliseconds since the startDictation
action, or `null` when the mark never happened: `t_capture_ms` (first audio
chunk), `t_speech_onset_ms` (first VAD speech start), `t_first_draft_ms`
(first draft reaches the tracker), `t_first_preview_ms` (first non-empty
display snapshot rendered), `t_first_settled_ms` (first snapshot with
non-empty settled text, added by windows by pause), `t_commit_ms` (commit action received) and
`t_injected_ms` (inject returned). `draft_count` counts drafts;
`draft_interval_mean_ms` and `draft_interval_max_ms` give the gaps between
consecutive drafts, `null` below two drafts. Baseline to beat: first preview
~1.6 s after speech onset, cadence ~1 s, commit→inject ~170 ms.

## PR 12 — entitlement cross-check (recorded per acceptance)

Every entitlement traced to the API that requires it; every capability the
app uses traced to its consent mechanism. Checked 2026-07-09 against HEAD.

| Key | Required by | Where in code |
|---|---|---|
| `com.apple.security.device.audio-input` | AVAudioEngine mic input under Hardened Runtime | `MicrophoneCapture` (AudioCapture.swift) |
| `com.apple.security.automation.apple-events` | NSAppleScript → System Events under Hardened Runtime | `SystemInjectionIO.fallbackPaste` (§12.6) |

NOT entitlements (TCC prompts, identity-bound): Accessibility (event tap +
read-only AX), Input Monitoring (conditional, tap creation), Microphone
(prompt on first capture), Automation (prompt per target app, pre-granted at
hotkey readiness — see below). Zero exception entitlements: no
library-validation disable, no JIT, no unsigned-memory, no sandbox (the tap,
synthetic paste chord, and AX reads are incompatible with App Sandbox).

**Spec deviation, recorded:** PLAN §PR-12 said "`audio-input` and nothing
else", but it also ships §12.6's AppleScript fallback, which Hardened Runtime
blocks without `automation.apple-events` — the entitlement list was
incomplete, not the code wrong. "Written against actual API usage" is the
governing clause. Also amended (agreed earlier): NO notarization / Developer
ID — signed with the free Apple Development identity, distribution is
build-it-yourself; the "Gatekeeper on a clean machine" acceptance is waived
accordingly.

**Automation pre-grant (PR 12, from PR 8 accepted-risks):** the fallback's
first NSAppleScript use raised the Automation prompt synchronously
mid-injection. `preGrantAutomationIfNeeded` now fires an innocuous System
Events no-op ONCE at hotkey readiness (the moment the user just finished
granting), so the prompt lands at a consent moment, not under dictated text.
UserDefaults-flagged; TCC remembers a decline, we never re-ask.

**Dvorak: CLOSED as accepted-untested (Mauria, 2026-07-09):** "I'm never
testing the Dvorak keyboard. That's just not gonna happen." The PR 8 matrix
cell is closed, not deferred. Confidence rests on the code path, not field
proof: keyCodeForV scans the ASCII-capable layout's translation table (unit-
tested), and the AppleScript fallback types layout-independently. If a Dvorak
user ever reports a mis-paste, that report is the field test.

**Egress scan interpretation:** "target zero findings" cannot be literal for
the linked binary — FluidAudio links statically and its never-invoked
download code imports URLSession and carries endpoint URLs. The scan is
therefore: stage 1 first-party source = literal zero; stage 2 binary =
every network symbol/URL must match scripts/egress-allowlist.txt (each entry
annotated with provenance), so anything NEW fails. The download paths are
runtime-disarmed (`DownloadUtils.enforceOffline = true` at launch, checked as
a precondition in `FluidAudioASR.prepare` before any model API).

## Trigger reassignment (shipped 2026-10-26)

Mauria asked on 2026-07-07 for the trigger to be reassignable ("maybe other
people want other button. especially vim guys"). Her ruling on 2026-10-25
superseded the earlier staging (modifier triggers first, keycode triggers
last): Fn stays the default, the user can choose another key or a combination,
and a collision with another app's shortcut is the user's problem. The
engineering demands stand: the state machine is parameterized over the
trigger, and the fail-open property tests were regenerated around it.

**A trigger** is `HotkeyTrigger` (`HotkeyTrigger.swift`): one physical key as a
Carbon virtual keycode, plus the modifier families (`control`, `option`,
`shift`, `command`) that must be held when it goes down. Fn is keycode 63 with
no modifiers. A key in `HotkeyTrigger.modifierKeys` (Left/Right Command,
Shift, Option, Control) or Fn is a modifier-key trigger, tracked on
`flagsChanged`; any other keycode is a regular-key trigger, tracked on
`keyDown` and `keyUp`. Settings stores it as `trigger`
(`{"keyCode": 105, "modifiers": ["control"]}`). The old `primaryTrigger`
string is dropped from a file on its next load (`VizprSettings.removedKeys`).
A malformed `trigger` decodes as Fn instead of failing the file, which would
cost every other setting. `clamped()` resets to Fn a trigger that cannot
work: a keycode outside 0...127, Caps Lock (it toggles), Esc (it cancels
dictation), an unknown modifier, Fn with modifiers, a sided modifier key
listing its own family, or a trigger that holds every modifier of the
secondary chord, counting a sided key's own family (pressing it also starts
the chord, so the chord would start dictation on a trigger press).

**The invariant**, restated: the machine consumes only primary-trigger inputs
(down, up, repeat), and the only physical events that become primary inputs
are the trigger key's own, identified by keycode and, for sided modifiers, by
that key's device bit in the event flags. Nothing else is ever consumed.
The secondary chord is unchanged: at least two family modifiers, never
consumed.

**Matching** (`FlagEdgeTracker`):

- *Exact modifiers.* The held families, masked to the four families, must
  equal the trigger's modifiers. Every other flag bit is ignored, so ⌘D does
  not fire on ⌘⇧D. For a modifier-key trigger the held set excludes the
  trigger key's own family. Fn ignores held modifiers, as it always has.
- *Sided modifiers by device bit.* Right Option is down exactly when
  `NX_DEVICERALTKEYMASK` (0x40) is set in the flags of a `flagsChanged`
  carrying keycode 61. A sibling key keeping the family flag set cannot turn
  a release into a press. Right Option as a trigger therefore coexists with
  Left Option in the chord.
- *Fn by flag.* Fn keeps the field-tested snapshot comparison of the Fn flag,
  including the silent re-seed on the first `flagsChanged` after a reset,
  whatever keycode the packet carries. An Fn held at a re-seed is treated as
  the trigger's own press unless the tracker saw it pass through earlier.
- *Autorepeat.* Only a non-repeat `keyDown` can take a key. A repeat of the
  taken key is `primaryRepeat`, which the machine swallows in every state
  without changing it. A repeat of a key that was not taken is never an edge,
  so a typed key that gains the trigger's modifiers while repeating is not
  eaten, and a held trigger repeating after its commit press starts nothing.
- *Taken keys.* The tracker emits an up edge only for a key it took. A trigger
  change while the key is held keeps the taken key, so its up is still
  consumed; the new trigger applies from the next press.
- *Reset.* A reset clears a taken modifier key (its release is
  self-correcting, since the event carries the full flag state) and keeps a
  taken regular key that is still physically down, so its repeats and its
  `keyUp` are still consumed after a blind window. After the tap is
  re-enabled and after the recorder resumes the monitor, the shell asks the
  system whether the key is down (`CGEventSource.keyState`). A taken regular
  key that is already up is cleared, because its release was missed and a
  stale take would leave a newly chosen trigger dead until the old key was
  pressed again.
- *Timestamps.* `flagsChanged`, `keyDown` and `keyUp` all go through one
  handler that converts the event's own timestamp, so a late-serviced
  callback cannot turn a quick tap into a hold.

**Where the decision lives.** `HotkeyEventRouter.route` is the pure per-event
function: tracker edges fed to the machine, with the event deleted when any
edge was consumed. `HotkeyMonitor` only builds the event value and calls it.
`HotkeyMonitor.setSuspended` makes the callback pass every event unchanged
and cancels any session; the recorder uses it.

**Recorder** (`HotkeyTriggerRecorder`, Behavior pane). Clicking the trigger
button suspends the monitor and listens through a local `NSEvent` monitor for
`keyDown` and `flagsChanged`; the monitor returns nil for the events it
captures, so ⌘W does not act on the window. A `keyDown` of a non-modifier key
captures it with the held families. Modifier-only presses capture the last
modifier key that went down, with the other held families, when all
modifiers are released. Fn is tracked by keycode 63. Recording ends on a
capture, Esc, the window closing or losing key, and the app going inactive.
Each refusal shows a one-line reason: Fn held with another key, Esc in any
combination, Caps Lock, a keycode outside 0...127, a combination that holds
the whole chord (a trigger's modifiers plus, for a sided key, its own
family, so Left Option with Control held is refused under the default
chord). The pane disables a chord toggle whose change would make the trigger
hold the whole chord. The reason a refused capture showed is cleared when
recording ends.

A capture made while Fn is physically down is refused, except for the keys a
laptop keyboard reaches only through Fn: F1 to F20, Home, Page Up, Forward
Delete, End and Page Down (`HotkeyTrigger.fnReachedKeyCodes`). For these the
stored trigger is the key alone with its family modifiers, never Fn, and the
tracker matches it with or without Fn held, since it ignores the Fn flag on
a regular key. This is the orchestrator's ruling on PR review finding 6
(2026-10-26). `clamped()` has no mirror of the Fn-down refusal, because it
only sees the stored value and an F-key trigger is an ordinary regular key.

**Tests.** `HotkeyStateMachineTests` runs over primary inputs including the
repeat. `FlagEdgeTrackerTests` carries the Fn cases through the new event
API and pins the sequences above. `HotkeyEventRouterTests` runs the router
over random streams of physical presses on sided modifiers, Fn and regular
keys with resets, trigger changes and chord changes, and asserts that only
the trigger's or the taken key's events are consumed, that no press has a
consumed event after a passed down except the two cases under Known limits,
which the test models by name, that a consumed down gets a consumed up, and
that every autorepeat of a consumed press is consumed.

**Known limits.**

- Events during secure input bypass the tap entirely, so a press that spans
  secure input can reach the app as repeats and an up with no down. This
  cannot be avoided.
- A taken regular key survives a reset. If its release and a second press
  both fall inside one blind window, the second press's release is consumed
  although the app saw its down. The alternative, clearing the key on reset,
  lets a held key's repeats reach the app without a down.
- An Fn held at a silent re-seed (pressed in a blind window, or the first
  packet after a reset) while Fn is the trigger is taken as the trigger's own
  press. Its up is consumed although the app saw its down. This is today's
  production behavior, kept by ruling on 2026-10-26.
- A sided modifier trigger needs a keyboard that reports device bits.
  Debug builds log when a `flagsChanged` for the trigger key carries none.

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

## Tail integrity at commit (2026-10-25)

At commit, the gray tail draft the user proofread used to be replaced by
FluidAudio's end-of-stream flush, which decodes the same audio differently:
it splits the unconfirmed tail at 10 s window boundaries, decodes the last
fragment with no right context, and hands sub-threshold windows to an
un-gated draft path. Two field cases from `debug.log`:

- **Words lost, 2026-10-24T00:17:17Z.** The last draft read "...logging so you
  can look"; the flush emitted finals "...so you." and "."; the injected text
  ended "so you." The session was 11.26 s with no confirmation, so the flush
  decoded [0, 10 s) and then [8 s, 11.26 s) as separate windows.
- **Words invented, 2026-10-24T18:18:50Z.** The last real final was "...in the
  CLI." (confidence 0.99), the VAD reported probability 0.00 from chunk 388
  on, and tail drafts read "So it's uh yeah." After `audio stream ended` the
  flush emitted a draft ". to spend half of my", which was injected and
  confirmed by Mauria as a hallucination.

Decisions:

- **The tail's final text is a draft-style decode.** On end of input,
  `FluidAudioASR` closes drafts, awaits the draft task, calls the manager's
  `cancel()` (not `finish()`, which is the flush), awaits the update stream,
  then decodes everything past the confirmed boundary once with the same
  no-context batch decoder the drafts use and emits it as `.finalized`. The
  commit range is capped at 15 s (`ASRConstants.maxModelSamples`), wider than
  the 12 s draft cap, because `cancel()` drops a window decode still in
  flight and, for the session's first window, nothing else covers its first
  seconds. The decode is fresh every time: the last draft plan rarely ends at
  the final sample, so reusing a finished draft would be the rare path.
- **Every sliding-window update is finalized.** The manager advances its
  window whether or not a decode met the 0.80 threshold and overwrites the
  volatile text on the next update, so an unconfirmed window's text had no
  later chance to appear. Its confidence travels with the event and
  SmartCleanup's 0.85 gate sends weak text to cleanup. The boundary stays
  `windowsProcessed x 10 s`, without the 2 s right context: the tail
  re-decodes that 2 s and `SeamMerger` trims the repeat, while a boundary
  past it would cut words straddling the window's audio end.
- **Late work from a finished session is ignored.** `AudioPipeline.stop()`
  clears its session task at once, so a new `transcribe` can begin while the
  previous one still finishes. `beginSession()` returns a session number and
  every actor call the finishing task makes carries it and does nothing once
  it has moved on. The guard is at the engine level only: a window the old
  session delivers late still reaches its own stream and `TokenStream`, which
  is the pipeline-level follow-up.
- **The ASR no longer hears long silence.** `SpeechGate` sits between the VAD
  and the engine in `AudioPipeline`. While the VAD reports speech it forwards
  audio; otherwise it holds the latest 1 s (pre-roll, because a soft onset
  often scores under the 0.85 trigger on its first 256 ms chunk). Until the
  VAD first triggers the hold is 4 s, so a quiet utterance it missed is not
  lost. At the end of the stream the hold is released only when the session
  never triggered or a batch still in the hold completed a chunk scoring at
  least 0.5 while the gate was already inactive (the batch that flips the gate
  to inactive never counts, and a flagged batch trimmed out of the hold no
  longer counts). The detector keeps
  `speechActive` true for 0.75 s after speech stops, so about 1 s of trailing
  audio is forwarded; before this change the engine received the whole 6 s
  auto-stop silence.
- **Subscribe to updates before streaming.** The manager builds its update
  continuation when the stream is built, so subscribing before
  `startStreaming` means a quick tap's `cancel()` always finishes it.

- **Settle cap default is 500 ms (was 350).** The commit now waits for one
  tail decode of up to 15 s, and a cap below the decode time commits the last
  draft and drops the decode, losing the last second of speech in the cases
  this change exists to fix. Rule: 2 x p90(15 s decode) + 100 ms, rounded up
  to 50 ms, clamped to 350-1000, where the 2 covers a draft decode still
  running when the input ends plus the commit decode behind it on the
  `AsrManager` actor. Batch decode of the bundled model, 10 runs each after a
  warm-up, 2026-10-25:

  | Clip | p50 | p90 |
  |---|---|---|
  | 3 s | 113.2 ms | 115.8 ms |
  | 6 s | 122.9 ms | 125.9 ms |
  | 12 s | 142.9 ms | 150.0 ms |
  | 15 s | 174.1 ms | 180.6 ms |

  Saved settings replace defaults on load: Mauria's persisted `settleCapMs`
  of 350 overrides the new 500 default. The worst case, a running draft decode
  plus the commit decode, is about 360 ms at p90, so she should set the Commit
  settle cap slider to 500 in Settings.
  *(2026-10-25, later: the setting and its slider are gone; the cap is
  `Tuning.settleCapMs`. See "Tuning values and single defaults".)*
  Each commit writes `settle: drained|capped after N ms` and
  `commit tail: decoded N ms over M samples` (or `commit tail: empty N ms over
  M samples` when the decode returned no text) to the dev log, which show how
  often the cap fires.

Measuring it: `python3 -I scripts/tail-integrity-report.py
~/Documents/dictation-dev/debug.log` reads the dev log and prints, over
committed sessions, how many had a draft after `audio stream ended`, how many
committed text ending in two words no pre-commit draft showed, how many lost
the last draft's final two words at commit, and, among sessions under 10 s,
how many had an `asr final` logged after the COMMIT record (its text missed
the injected snapshot). A late draft can be harmless when it finished after
`audio stream ended` but before the engine closed drafts, since it lands
before the settle. The matching is rough (a
re-decode that changes a word counts as both a loss and an invention), so the
counts are upper bounds. Baseline on the 2026-10-25 log, before this change:
37 of 107 committed sessions had a late draft, 4 had an invented tail, 4 had
a lost tail, and 0 of 60 short sessions had a final after the injected
snapshot. The same command
after a week of use gives the comparison.

Live validation, 2026-10-25, six checks on Mauria's machine: a quick tap; an
11 s utterance; a release on a word, where the commit decode added "and now no
worries", which the last draft lacked; a pause followed by one word; auto-stop,
with nothing invented; and Escape, which injected nothing. In every case the
injected text matched or extended the last draft, and the settle wait was
released by drain in 131 to 203 ms.

One seam duplication was observed at 2026-10-25T19:26Z. A window's text ended
"pushes are." because its audio ended mid-word at 12 s. The tail decode, which
has no left context, heard "are ready" as "already", and the text-based seam
trim could not match the two, so both stayed. This is deferred to the follow-up
that cuts windows by token timing and gives the tail decode left context.

Known limits:

- The settle cap can still fire before the commit decode finishes; the last
  draft is then committed and the decode dropped, as before.
- An unconfirmed tail longer than 15 s loses its front. That needs a window
  decode more than 3 s late, which the field cadence does not show.
- A quiet utterance the VAD never triggers on is decoded only from the last
  4 s of the session and shows no live draft while it is spoken.
- Soft speech inside a long pause that never reaches 0.5 probability is
  dropped (11 of 3,173 sampled chunks were inactive while scoring 0.3-0.85).

## Windows by pause (2026-10-25)

FluidAudio's sliding window confirmed a 10 s window after 2 s of further
audio, so the first final text landed at about 12 s and every 10 s after it.
Windows were cut on a clock, so a cut landed mid-word about half the time; the
window kept its 2 s of right context, the next decode heard those words again,
and a text match was the only thing stopping a duplicate. Field case,
`debug.log` 2026-10-25T19:26Z: the window's text ended "pushes are." because
its audio ended at 12 s in the middle of "ready", the tail decode heard "are
ready" as "already" with no words before it, the match failed, and the
injected text read "whatever pushes are. whatever pushes already."

The app now owns its windows: a window closes at each pause the VAD reports,
and every decode is cut by token timing, so no decode repeats another's words.
This replaces the sliding-window decisions in "Tail integrity at commit" (the
window boundary, the seam trim, cancelling the manager); its other decisions
stand. The decisions, by step:

- **The engine's input carries pause marks.** `TranscriptionEngine.transcribe`
  takes `AsyncStream<AudioInput>`, where `AudioInput` is `.samples([Float])` or
  `.pause`. `AudioPipeline` yields `.pause` after the gate's batches for a
  capture batch whose VAD updates contain a `speechEnd` event, one per event.
  The mark carries no position: the gate forwards about 1 s of audio after
  speech stops and then nothing, so the engine's own sample count when the
  mark arrives is the pause. The VAD still never decides commits; a mark only
  lets the engine close a window.

- **The engine owns its windows.** `SlidingWindowAsrManager` is gone; the
  batch `AsrManager` does every decode, in one decode task per session.
  `WindowTracker` (renamed from `DraftTailTracker`) plans three kinds of
  decode, each over a range that starts 2 s before its window for acoustic
  context:
  - *pause*: the last `.pause` mark closes a window from the confirmed
    boundary to the mark, if it follows at least 0.5 s of unconfirmed audio. A
    shorter pause is dropped, not deferred.
  - *forced*: 12 s of unconfirmed audio without a pause closes a window of
    10 s, decoded to 12 s so the cut can land between words. The forced check
    runs first, so a pause window never covers more than 12 s of unconfirmed
    audio plus context, which keeps every decode under FluidAudio's 240,000
    sample single-pass limit.
  - *commit*: as on tail integrity, with the 2 s of context and the cut.
- **Words are cut by token timing, not matched by text.** `TimedCut` groups a
  decode's `tokenTimings` into words (a word starts at a token whose text
  starts with a space; a punctuation piece stays with its word) and keeps the
  words whose first token starts inside the window. The text is rebuilt by
  joining the kept tokens. A forced window is cut at the midpoint of the widest
  gap between words that lies inside 9 to 11 s after the boundary; with no such
  gap it cuts at the first word starting at or after 10 s, else at 10 s.
- **Where the boundary moves.** A forced window confirms through the end of
  its last kept word: a word it omitted at its edge is decoded whole by the
  next window, and a word it kept starts before the boundary, so the next
  window drops it. A pause window confirms through the pause, because the
  silence between its last word and the pause was heard and yielded nothing;
  leaving it unconfirmed would make every dictation that ends after a pause
  run a commit decode over context plus silence. A window that kept no word
  (an empty cut) confirms through its end, or a forced window would plan again
  on every wake. A failed decode confirms nothing and emits nothing: a forced
  window is retried on the next wake, and a pause window, whose pause is
  consumed, leaves its audio in the tail for the next window or the commit
  decode.
- **A pause pending when the input ends is not run.** The commit decode covers
  everything past the boundary, so planning stops when the input ends and one
  decode replaces a window plus the commit decode behind it.
- **Draft de-duplication restarts at each window.** The engine suppressed a
  draft equal to the previous one; that memory now clears at each confirm, so
  a phrase repeated in the next window is not hidden.
- **Timings.** Each window logs one line, numbers only:
  `window: pause|forced, decoded N ms, cut M samples`.

- **Seam merging no longer matches words.** Finals do not repeat each other's
  words, so `SeamMerger.trimOverlap` is removed and `appendix(context:new:)`
  keeps only its punctuation and spacing rules. A phrase repeated across two
  finals ("I really" / "really mean it") is kept. The filler and contraction
  tables stay because `stripContextEcho` aligns a cleanup rewrite with its
  settled context through them: cleanup drops fillers and may expand
  contractions when it copies the context.

- **Text turns white when its cleanup resolves.** Finalized text used to
  settle only when two more sentences arrived. Now the cleanup launched for the
  live region's current generation settles the complete sentences of the live
  region when it resolves, and a trailing sentence fragment stays live, so a
  pause mid-sentence never settles half a sentence before the sentence-end
  cleanup sees the whole. Resolution means: the rewrite applied
  (`applyCleanup` settles the prefix of what it wrote), the cleanup failed
  (including an echo-only rewrite), the gate skipped cleanup, or cleanup is
  off (the last two through `resolveLive(generation:)`). A skip while another
  cleanup is in flight settles nothing at that moment, so an earlier
  low-confidence span keeps its cleanup, and the refusal is retried when the
  running cleanups finish if the generation is still current; a result for an older generation settles nothing;
  commit is unchanged (strict cancel, the display is committed as shown).
  The two-sentence rule stays as `settledSentenceBacklog`, so text still
  settles when cleanups keep going stale under fast speech.
- **The space before the next final goes with the settled text.** When a
  resolution settles all of live, the next final's leading space is appended
  to settled, not live. Cleanup returns trimmed text, so a space left at the
  front of live would be lost when cleanup rewrites it, and the display would
  read "Hello there.Next one".
- **`launchCleanup` hands its operation its own id.** A failed cleanup resolves
  the live region from inside its own task, which is still registered; the id
  lets it stop counting itself as in flight.
- **The "Settle window" setting is gone.** `settleSentences` leaves
  `VizprSettings` and the Behavior tab; an old `settings.json` that has the
  key still loads, because decoding ignores unknown keys (since 2026-10-25 the
  next load also drops it from the file). Cleanup latency on the
  bundled model with an empty context (10 runs after a warm run, 2026-10-25):
  one 13-word sentence p50 680 ms, p90 689 ms; two sentences (27 words) p50
  1,024 ms, p90 1,032 ms; three sentences (41 words) p50 1,348 ms, p90
  1,370 ms. Text therefore turns white about 0.7 to 1.4 s after a window's
  cleanup starts.

- **The dictation record measures settling.** `t_first_settled_ms` is the
  time from the startDictation action to the first snapshot whose settled text
  is non-empty, next to `t_first_preview_ms`. Dev-log builds only.

Known limits:

- A VAD `speechEnd` needs 0.75 s of silence, so a window closes only at a real
  pause. Text turns final no sooner than 0.75 s after the pause plus the
  decode; speech with no pauses waits for the forced 10 s window.
- White text waits for cleanup, so the lag after a pause is the cleanup time
  above; the two-sentence backstop bounds it while cleanup lags.
- A forced window cuts on the clock, at the widest gap between words near
  10 s. Two decodes can place the same word's start a frame or more apart
  (FluidAudio's emission-delay correction is a median shift, not a per-token
  alignment). Confirming through the end of the last kept word makes the next
  window the one that decides any word the previous one omitted. A word the
  earlier window kept, even truncated, starts before the boundary and is
  dropped by the next window; only a word the earlier window omitted is
  recovered.
- A decode can stamp a word's start a frame or more before its true position.
  Live (2026-10-25T20:40Z), speech resumed 50 ms after a pause mark and the
  first word was stamped before the boundary and dropped as context. A window
  or commit decode whose cut starts at a pause (or the session's start)
  therefore keeps words starting up to 0.25 s before the boundary
  (`WindowTracker.pauseStartToleranceSamples`). That is safe because the
  0.75 s of audio before a pause scored as silence, so no word of the previous
  window can start inside it. A forced boundary is the end of the previous
  window's last kept word, inside speech, so its tolerance is 0.
- The decode task is single, so a confirm delays the next draft refresh by one
  decode, about 150 ms.
- A pause pending when the input ends is not run as a window; the commit
  decode covers it. A pause less than 0.5 s past a forced window's cut is
  cleared with it; a pause further past survives and closes the next window.
## Test runs no longer write the dev log (2026-10-25)

The test host is the Debug app, so suites with fake engines (AudioPipelineTests,
FluidAudioASRTests) appended their traffic to `~/Documents/dictation-dev/debug.log`
and `transcripts.jsonl`. Under tests, `VizprDevLogDirectory` now points both
writers at `vizpr-tests-<pid>` in the temporary directory, and the existing
"dev transcript log target:" line says where. Production paths are unchanged.

`VizprTranscriptLogger.note` is also called from several threads, and each call
opened, seeked and wrote the file unserialized: two callers at the same instant
sought to the same end offset and one line overwrote the other (a `window:` line
and an `asr final` line never both landed). A lock now wraps the open-write-close;
the call stays synchronous so a caller's next line follows its own previous one.

## Tuning values and single defaults (2026-10-25)

The two development levers, the commit settle cap and the draft minimum tail,
are no longer settings. They are `Tuning.settleCapMs` (500) and
`Tuning.draftMinTailMs` (1500) in `Vizpr/App/Tuning.swift`, each with the rule
it comes from. Change one there and every consumer follows: `AppDelegate`
reads the cap at each commit, and `FluidAudioASR` derives its first-draft
sample count from the draft minimum. Their two Behavior sliders are gone. An
old `settings.json` that still carries `settleCapMs`, `draftMinTailMs` or
`settleSentences` loads normally and sheds those keys on that load
(`VizprSettings.removedKeys`, which also lists the retired `primaryTrigger`).

The rule from here on: a tuning value lives in `Tuning.swift`, a user choice
lives in `VizprSettings`, and every default is written once. The hold
threshold, the secondary chord and the auto-stop timeout have their default
only in the `VizprSettings` field; `HotkeyStateMachine`, `HotkeyMonitor` and
`AudioPipeline` take them as required arguments, and `AppDelegate` builds the
monitor and the pipeline from the loaded store. `WindowTracker`'s
`minTailSamples` is required too. The hold-threshold and auto-stop clamp
ranges are `VizprSettings.holdThresholdRangeMs` and `autoStopRangeSeconds`,
used by `clamped()` and by the sliders.

## Plain display names for settings (2026-10-25)

Every remaining control in the Behavior and Models panes now says what it does
in a full phrase, for example "Hold the hotkey this long for push-to-talk" with
the caption "A shorter tap keeps listening until you press again." The hold
threshold's wording says "the hotkey" because it governs the secondary chord
as well as Fn, and "press again" because any next press of either key commits.
The auto-stop wording says "hands-free mode" because auto-stop is ignored while
a key is held. The names are proposals to rename later; the keys and the saved
file are unchanged.

## Environment prerequisites discovered

- **Metal Toolchain** is required to build the mlx-swift dependency (it compiles
  Metal kernels). Install once with `xcodebuild -downloadComponent MetalToolchain`.
  This is a one-time dev-toolchain component (like Xcode itself), not part of the
  project's SPM resolve or app build, and not runtime network egress.
- Keychain needed Apple's **WWDR G3 intermediate** certificate imported before the
  free Apple Development identity validated for code signing.
