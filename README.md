# vizpr

A local, on-device, streaming dictation app for macOS. Hold or tap the Fn key, speak, watch a live transcript in a floating glass HUD, and on release the text is injected into the focused app.

- ASR: Parakeet TDT 0.6B v2 (CoreML / Apple Neural Engine) via FluidAudio
- Cleanup: local LLM (Qwen3.5-4B) via mlx-swift
- Menu-bar app, macOS 15+, Swift 6 strict concurrency
- No network, ever. No telemetry, no transcript persistence.
