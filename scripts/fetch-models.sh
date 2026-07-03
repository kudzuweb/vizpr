#!/usr/bin/env bash
# Fetch the bundled ASR model (Parakeet TDT 0.6B v2 CoreML, ~443 MB working set)
# into Vizpr/Resources/Models/, where the build copies it into the app bundle.
#
# This is DEV-TIME tooling: the shipped app never downloads anything (invariant
# 1) — it only loads what this script placed in the bundle at build time. The
# model directory is gitignored (too large for git); run this once after clone.
#
# Fast path: copies from the local FluidAudio CLI cache if present (the PR 0
# spike downloaded it there). Otherwise downloads the required files from
# Hugging Face (FluidInference/parakeet-tdt-0.6b-v2-coreml, CC-BY-4.0).
set -euo pipefail

cd "$(dirname "$0")/.."

DEST="Vizpr/Resources/Models/parakeet-tdt-0.6b-v2"
CACHE="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
REPO="FluidInference/parakeet-tdt-0.6b-v2-coreml"

# The v2 working set (what AsrModels.load requires — not the full HF repo).
FILES=(
  "Encoder.mlmodelc"
  "Decoder.mlmodelc"
  "JointDecision.mlmodelc"
  "Preprocessor.mlmodelc"
  "parakeet_vocab.json"
  "config.json"
)

complete() {
  for f in "${FILES[@]}"; do
    [[ -e "$DEST/$f" ]] || return 1
  done
}

if complete; then
  echo "ASR model already present at $DEST"
  exit 0
fi

mkdir -p "$DEST"

if [[ -d "$CACHE" ]]; then
  echo "Copying ASR model from FluidAudio cache ..."
  for f in "${FILES[@]}"; do
    if [[ -e "$CACHE/$f" ]]; then
      cp -R "$CACHE/$f" "$DEST/"
    fi
  done
fi

if ! complete; then
  echo "Downloading missing files from $REPO ..."
  if ! which hf >/dev/null; then
    echo "error: hf CLI not found. Install with: pip install huggingface_hub" >&2
    echo "       (or: spikes/cleanup-bench/.venv/bin/hf)" >&2
    exit 1
  fi
  INCLUDES=()
  for f in "${FILES[@]}"; do
    if [[ ! -e "$DEST/$f" ]]; then
      if [[ "$f" == *.mlmodelc ]]; then
        INCLUDES+=(--include "$f/*")
      else
        INCLUDES+=(--include "$f")
      fi
    fi
  done
  hf download "$REPO" "${INCLUDES[@]}" --local-dir "$DEST"
  rm -rf "$DEST/.cache"
fi

if complete; then
  echo "ASR model ready at $DEST ($(du -sh "$DEST" | cut -f1))"
else
  echo "error: model fetch incomplete — missing files remain in $DEST" >&2
  exit 1
fi
