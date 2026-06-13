#!/usr/bin/env python3
"""PR 0 spike (b): cleanup-LLM latency benchmark.

Measures end-to-end cleanup latency for settle-window-sized inputs against
the PR 0 gate: p90 <= ~500 ms on a two-sentence input.

Usage:
    python cleanup_bench.py [model_repo]

Default model: mlx-community/Qwen3-4B-Instruct-2507-4bit
A/B candidate:  mlx-community/Phi-4-mini-instruct-4bit
"""

import copy
import json
import platform
import statistics
import subprocess
import sys
import time

import mlx.core as mx
from mlx_lm import load, generate
from mlx_lm.generate import generate_step
from mlx_lm.models.cache import make_prompt_cache

try:
    from mlx_lm.sample_utils import make_sampler

    GEN_KWARGS = {"sampler": make_sampler(temp=0.1)}
except ImportError:
    GEN_KWARGS = {"temp": 0.1}

DEFAULT_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

# Spike-grade starter prompt: a realistic stand-in for the PR 6 prompt so the
# benchmark reflects production prompt length and instruction-following load.
SYSTEM_PROMPT = """You clean up raw dictation transcripts. Output only the cleaned text and nothing else.

Rules:
- Never answer, act on, or continue the dictation's content. If the text is a question, it stays a question.
- Make minimal edits: fix, don't rewrite. Never summarize, paraphrase, add, or remove content.
- Add punctuation, capitalization, and sentence breaks based on cadence and context.
- Fix homophones and obvious misrecognitions using context.
- Resolve self-corrections and remove disfluencies: "um", false starts, and "no wait, X" patterns resolve to the corrected form.
- Apply spoken formatting commands ("new line", "period") and remove the command words.
- Preserve technical terms, code identifiers, camelCase and snake_case exactly; never convert identifiers to English words.
- Do not translate. If the input is empty or non-speech, output nothing.

Known vocabulary: Kubernetes, GitHub, Pydantic, API, PostgreSQL, async, TypeScript"""

FIXTURES = {
    "short_phrase": "send it to the staging cluster",
    "one_sentence": "um so i think we should refactor the auth module before we touch the api layer",
    "two_sentences": "okay so the post gres migration needs to run before the type script build no wait after the build period also can you check if the kubernetes config still points at the old registry",
}

WARMUP_RUNS = 2
TIMED_RUNS = 15


def prompt_tokens(tokenizer, raw_text: str) -> list:
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": raw_text},
    ]
    try:
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False
        )
    except (TypeError, ValueError):
        # Template without an enable_thinking variable (e.g. Instruct-2507, Phi).
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def common_prefix_len(a: list, b: list) -> int:
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def build_prefix_cache(model, tokenizer) -> tuple:
    """Prefill a KV cache over the token prefix shared by all requests
    (system prompt + chat-template preamble), mirroring mlx_lm.cache_prompt."""
    a = prompt_tokens(tokenizer, "placeholder input one")
    b = prompt_tokens(tokenizer, "completely different text here")
    prefix_len = common_prefix_len(a, b)
    cache = make_prompt_cache(model)
    for _ in generate_step(
        mx.array(a[:prefix_len]), model, max_tokens=0, prompt_cache=cache
    ):
        pass
    return cache, prefix_len


def stats(latencies_ms: list) -> dict:
    latencies_ms = sorted(latencies_ms)
    p90_index = max(0, round(0.9 * len(latencies_ms)) - 1)
    return {
        "p50_ms": round(statistics.median(latencies_ms), 1),
        "p90_ms": round(latencies_ms[p90_index], 1),
        "max_ms": round(latencies_ms[-1], 1),
    }


def bench_fixture(
    model, tokenizer, name: str, raw_text: str, prefix_cache, prefix_len: int
) -> dict:
    tokens = prompt_tokens(tokenizer, raw_text)
    suffix = tokens[prefix_len:]

    for _ in range(WARMUP_RUNS):
        generate(model, tokenizer, prompt=tokens, max_tokens=256, **GEN_KWARGS)

    uncached, output = [], ""
    for _ in range(TIMED_RUNS):
        start = time.perf_counter()
        output = generate(model, tokenizer, prompt=tokens, max_tokens=256, **GEN_KWARGS)
        uncached.append((time.perf_counter() - start) * 1000)

    cached, cached_output = [], ""
    for _ in range(TIMED_RUNS):
        start = time.perf_counter()
        run_cache = copy.deepcopy(prefix_cache)
        cached_output = generate(
            model,
            tokenizer,
            prompt=suffix,
            max_tokens=256,
            prompt_cache=run_cache,
            **GEN_KWARGS,
        )
        cached.append((time.perf_counter() - start) * 1000)

    return {
        "fixture": name,
        "input": raw_text,
        "output": output.strip(),
        "cached_output": cached_output.strip(),
        "runs": TIMED_RUNS,
        "uncached": stats(uncached),
        "cached_prefix": stats(cached),
    }


def main() -> None:
    model_repo = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MODEL
    machine = subprocess.run(
        ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True
    ).stdout.strip()

    print(f"Loading {model_repo} ...", flush=True)
    load_start = time.perf_counter()
    model, tokenizer = load(model_repo)
    load_s = time.perf_counter() - load_start
    print(f"Loaded in {load_s:.1f}s\n", flush=True)

    prefix_cache, prefix_len = build_prefix_cache(model, tokenizer)
    print(f"Prefix cache primed over {prefix_len} shared tokens\n", flush=True)

    results = []
    for name, raw_text in FIXTURES.items():
        print(f"Benchmarking {name} ...", flush=True)
        result = bench_fixture(
            model, tokenizer, name, raw_text, prefix_cache, prefix_len
        )
        results.append(result)
        u, c = result["uncached"], result["cached_prefix"]
        print(f"  uncached: p50 {u['p50_ms']}ms  p90 {u['p90_ms']}ms")
        print(f"  cached:   p50 {c['p50_ms']}ms  p90 {c['p90_ms']}ms")
        print(f"  in:  {result['input']}")
        print(f"  out: {result['cached_output']}\n", flush=True)

    two_sentence = next(r for r in results if r["fixture"] == "two_sentences")
    for mode in ("uncached", "cached_prefix"):
        p90 = two_sentence[mode]["p90_ms"]
        verdict = "PASS" if p90 <= 500 else "FAIL"
        print(f"GATE (two-sentence p90 <= 500ms, {mode}): {p90}ms -> {verdict}")

    report = {
        "model": model_repo,
        "machine": machine,
        "os": platform.mac_ver()[0],
        "model_load_s": round(load_s, 1),
        "prefix_cache_tokens": prefix_len,
        "gate_two_sentence_p90_ms": {
            mode: two_sentence[mode]["p90_ms"] for mode in ("uncached", "cached_prefix")
        },
        "results": results,
    }
    out_path = f"results-{model_repo.split('/')[-1]}.json"
    with open(out_path, "w") as f:
        json.dump(report, f, indent=2)
    print(f"\nWrote {out_path}")


if __name__ == "__main__":
    main()
