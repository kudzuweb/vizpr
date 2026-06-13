# PR 0 Spike Report

Machine: Apple M3 Pro, 36 GB, macOS 15.6.1 (personal). Work M5/24 GB not yet
measured; M3 is treated as the floor.

## Gate (b): Cleanup p90 <= ~500 ms on two-sentence input

Method: `cleanup-bench/cleanup_bench.py`, mlx-lm 0.31.3, 15 timed runs per
fixture after 2 warmups, temp 0.1, ~214-token production-realistic system
prompt. "Cached" = KV cache prefilled over the constant system-prompt prefix
(deepcopied per run), which production MLXCleanup must replicate.

| Model (4-bit) | short phrase p90 | one sentence p90 | two sentences p90 | gate |
|---|---|---|---|---|
| Qwen3-4B-Instruct-2507 uncached | 655 ms | 865 ms | 1219 ms | FAIL |
| Qwen3-4B-Instruct-2507 cached | 348 ms | 532 ms | 938 ms | FAIL |
| Phi-4-mini-instruct uncached | 616 ms | 773 ms | 5249 ms | FAIL |
| Phi-4-mini-instruct cached | 349 ms | 498 ms | 5021 ms | FAIL |
| Qwen3-1.7B uncached | 343 ms | 431 ms | 518 ms | FAIL |
| Qwen3-1.7B cached | 218 ms | 302 ms | **401 ms** | **PASS** |

Quality observations (fixtures include vocab terms + a self-correction):

- **Qwen3-4B**: best overall. Fixed PostgreSQL/TypeScript/Kubernetes/API,
  removed disfluencies, applied "period". Mis-resolved the self-correction
  ("before... no wait after" kept "before") — prompt-tuning work for PR 6.
- **Qwen3-1.7B**: same output as 4B on the one-sentence fixture; vocab all
  fixed. But it *deleted* the self-correction clause instead of resolving it —
  the sub-2B failure mode the decision log predicted, and a minimal-edits
  violation.
- **Phi-4-mini**: disqualified. Degenerate repetition (5 s of trailing
  periods), dropped lead-in words, no capitalization.

### Verdict (provisional, judged per the plan's near-the-line clause)

Default stays **Qwen3-4B-Instruct-2507** despite the two-sentence FAIL:

1. Prefix caching is **mandatory** in MLXCleanup's design (-300 ms flat).
2. Confidence gating keeps the typical cleanup span at <= 1 sentence, where
   cached p90 is 532 ms — at the line, and the race design means raw text is
   already displayed; a correction landing ~500 ms later trails reading by a
   tolerable margin. Two-sentence spans are the tail case, not the norm.
3. Qwen3-1.7B passes the latency gate but its content deletion violates
   "fix, don't rewrite" — worse for trust than late corrections. Documented
   as a user-suppliable speed tier via ModelRegistry, not bundled.

Final call re-judged by felt experience once the real loop exists (PR 9
dogfooding). If 4B corrections feel laggy in practice, the recorded fallback
order is: tighten gating scope further, then 1.7B with a
deletion-discouraging prompt.

### Spec correction

The plan's "Qwen3.5-4B" is a multimodal VLM (mlx-vlm runtime, ~2.9 GB) that
does not match the plan's own constraints. The matching text-only model is
**Qwen3-4B-Instruct-2507** (natively non-thinking, Apache-2.0,
`mlx-community/Qwen3-4B-Instruct-2507-4bit`, 2.26 GB). All references to the
cleanup model resolve to this.

## Gate (a): ASR finalization <= ~150 ms p90 — PASS

Method: `fluidaudiocli asr-benchmark --model-version v2 --max-files 10`
(LibriSpeech test-clean) plus streaming/batch transcribe runs on local TTS
fixtures.

- **RTFx 66.2x median / 67.5x overall** on the ANE; WER 0.0% on the sample.
- At 67x, the worst-case full window (10 s) infers in ~150 ms; the 1 s
  incremental hypothesis chunks cost ~15 ms each. Finalization (window
  advance) is therefore comfortably inside the gate at the default config.
- Streaming transcript quality on the 21.6 s fixture: excellent — vocab terms,
  punctuation, capitalization, and the verbatim self-correction all correct.
- Per-token confidence confirmed available on the streaming path
  (`SlidingWindowTranscriptionUpdate.tokenTimings[].confidence`), resolving
  the research-phase open question — confidence gating has its signal.

**Locked window config** (SlidingWindowAsrManager library defaults):
`chunkSeconds=10.0, hypothesisChunkSeconds=1.0, leftContext=2.0,
rightContext=2.0, confirmationThreshold=0.80`. Caveat recorded: this is a
throughput-derived bound, not a directly instrumented p90; PR 4's acceptance
tests instrument true per-update finalization latency and re-check the gate.

## Gate (c): EOU promotion (>= 2x draft latency AND usable quality) — NOT PROMOTED (banked for v2)

- EOU 160 ms chunks: usable but error-prone on the TTS fixture ("posters
  migration", "ophth module", "no way" for "no wait").
- EOU 320 ms chunks: near-TDT quality on the same fixture (one error:
  "postgers").
- Draft cadence: EOU emits ~every 320 ms vs TDT volatile updates every 1 s
  hypothesis chunk — nominally ~3x, but `hypothesisChunkSeconds` is tunable
  downward, so the honest gap is < 2x at comparable quality settings.
- Evidence is TTS-only; no real-mic data. Promotion requires BOTH a >= 2x
  latency win AND subjectively usable drafts — neither is established.

Verdict: v1 ships TDT sliding-window only. The `TranscriptionEngine` seam
keeps EOU a drop-in second conformer if dogfooding shows draft cadence lags.

## Bottom line

| Gate | Result |
|---|---|
| (a) ASR finalization <= ~150 ms p90 | PASS at locked default config |
| (b) Cleanup p90 <= ~500 ms (two-sentence) | FAIL strict; 4B kept per near-line judgment (caching + gating); 1.7B recorded as speed fallback |
| (c) EOU promotion | Not promoted; banked for v2 |
