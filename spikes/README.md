# PR 0 — Latency spike (throwaway)

Probes that gate the pipeline constants. Nothing here is imported by the app.
Results land in `REPORT.md` (numbers per machine, locked window config, 4B
verdict, EOU verdict, explicit pass/fail per gate).

## Gates (fixed in advance, from PLAN.md)

1. ASR finalization <= ~150 ms p90 at the chosen config -> config locked.
2. Cleanup p90 <= ~500 ms on a two-sentence input.
3. EOU promoted to v1 draft engine only if draft latency beats TDT windowing
   by >= 2x AND draft quality is subjectively usable.

## Layout

- `cleanup-bench/` — spike (b): mlx-lm latency benchmark for the cleanup LLM.
  `cleanup_bench.py [model_repo]`; defaults to Qwen3-4B-Instruct-2507-4bit,
  pass `mlx-community/Phi-4-mini-instruct-4bit` for the A/B candidate.
- `FluidAudio/` — clone of FluidAudio v0.15.2 (gitignored); its CLI
  (`fluidaudiocli`) drives spikes (a) ASR benchmark and (c) EOU probe.
- `fixtures/` — locally generated WAVs (macOS `say`) for latency probes.

## Spec corrections discovered during research (carry into PLAN usage)

- The plan's cleanup model "Qwen3.5-4B" is a multimodal VLM (mlx-vlm runtime,
  ~2.9 GB) and does not match the plan's own requirements. The matching
  text-only model is **Qwen3-4B-Instruct-2507** (natively non-thinking,
  `mlx-community/Qwen3-4B-Instruct-2507-4bit`, 2.26 GB). Benchmarked here.
- FluidAudio streaming window sizes are fixed enums bound to pre-trained
  weights (EOU: 160/320/1280 ms), not freely tunable window/hop values. The
  spike picks among discrete configs.
- Per-token confidence is confirmed on the batch API
  (`ASRResult.tokenTimings[].confidence`); streaming managers expose token
  strings + timestamps only. Spike must verify where confidence-gated cleanup
  gets its signal.
- Swift LLM runtime is `ml-explore/mlx-swift-lm` (v3.31.3), a separate package
  from core `mlx-swift`. Transitive-dependency inventory needed in PR 1
  against the two-dependency invariant.

## Pins established by research (PR 1 will use these)

- FluidAudio v0.15.2 (`7f963cdc43ba89c5993654f1e138047d517a818d`)
- mlx-swift-lm v3.31.3
- ASR model: `FluidInference/parakeet-tdt-0.6b-v2-coreml` (2.58 GB, CC-BY-4.0)
- EOU candidate: `FluidInference/parakeet-realtime-eou-120m-coreml` (1.34 GB)
- Cleanup model: `mlx-community/Qwen3-4B-Instruct-2507-4bit` (2.26 GB, Apache-2.0)
