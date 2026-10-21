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

## PR 15 — Sculptable looks: `LookStyle` renders (2026-10-21)

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

**Measurement.** `OverlayLook.paneHeight(fitting:)` is the one place that
measures: width, padding, font, and line spacing (through `NSParagraphStyle`)
all come from the look, matching how `OverlayView` lays the text out.

**Offscreen renders.** `NSHostingView.cacheDisplay` does not run Metal shader
effects, so the light layer is absent from such frames. `ImageRenderer` runs
them but cannot draw a `ScrollView`.

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
| speech → first draft | draftMinTailMs floor (1.5 s default) | leave — user lever, quality-bound (sub-1.5 s tails decode junk, field-observed) |
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
display snapshot rendered), `t_commit_ms` (commit action received) and
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

## Trigger reassignment (Mauria, 2026-07-07 — designed-in, deliberate follow-up)

"I guess you should be able to reassign the trigger too. I like Fn but maybe
other people want other button. especially vim guys."

Deliberately NOT shipped in the PR 11 hotkey slice. The fail-open invariant
("consume a keystroke ONLY if it's our trigger") is written specifically
around Fn's flagsChanged behavior — Fn arrives as a modifier-flag transition,
not a keyDown, so the current HotkeyStateMachine never has to decide whether
to swallow a character-producing key. Reassignment to an arbitrary key (or a
modifier chord as primary) means parameterizing that state machine, and the
property tests that pin fail-open (`HotkeyStateMachineTests`) must be
regenerated around the parameterized trigger, not just extended. **Do NOT
rush this one** — a wrong trigger match eats user keystrokes system-wide.

Plan when it lands:
1. Parameterize `HotkeyStateMachine` over a trigger descriptor (flag-based
   like Fn, chord-based like the secondary, or plain-keycode).
2. Modifier-mask triggers first (Right-Option, Right-Command, Globe) — same
   flagsChanged shape as Fn, smallest step, covers most "other button" asks.
3. Plain-keycode triggers (the vim ask) last: these require keyDown
   consumption and a new class of fail-open property tests (never swallow a
   key that ISN'T the trigger; always swallow one that IS; secure-input and
   tap-timeout behavior re-proven).

Already provisioned NOW so the settings format is stable:
`VizprSettings.primaryTrigger: String = "fn"` — reserved field, decode-clamps
to "fn" until the machine is parameterized. The Behavior pane displays the
binding read-only with a "Trigger reassignment is coming." caption.

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
