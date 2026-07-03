#!/usr/bin/env python3
"""Generate the golden tokenizer corpus: (string -> token ids) pairs from the
reference Qwen2 fast tokenizer, which the first-party Swift tokenizer must match
byte-for-byte. Seeded with the adversarial cases documented across the ecosystem
(CamelCase/fix_mistral, contractions, CJK, combining marks, NBSP/format chars,
CRLF+space, special tokens, code identifiers) plus real dictation transcripts.

Run: spikes/cleanup-bench/.venv/bin/python scripts/gen-tokenizer-golden.py
Writes: VizprTests/Fixtures/tokenizer-golden.json
"""
import json
import os

from transformers import AutoTokenizer

MODEL_DIR = "Vizpr/Resources/Models/cleanup-llm"
OUT = "VizprTests/Fixtures/tokenizer-golden.json"

CASES = [
    # --- plain ---
    "hello world", "The quick brown fox.", "",
    # --- CamelCase / mixed case (fix_mistral_regex divergence zone) ---
    "CamelCase", "camelCase", "snake_case_name", "HTTPServer", "iOSApp", "'The'",
    "getURLPath", "XMLHttpRequest",
    # --- contractions, upper and lower (the (?i:) zone) ---
    "it's", "IT'S", "don't", "DON'T", "we're", "they've", "I'd", "'Does it work?'",
    "y'all can't won't",
    # --- numbers (Qwen splits single digits) ---
    "12345", "3.14159", "$200", "1,000,000", "version 2.0.1",
    # --- punctuation runs / whitespace ---
    "wait... what? yes!", "a.b.c", "  leading spaces", "trailing spaces  ",
    "tabs\tand\ttabs", "line1\nline2", "crlf\r\nnext", "\n ", " \n", "mixed \r\n  spaces",
    # --- unicode: accents, CJK, emoji, combining marks, NBSP, zero-width ---
    "café résumé naïve", "日本語のテキスト", "emoji 🎉 test 👍🏽",
    "é combining", "ͅ ypogegrammeni", "nbsp here", "zwj‍joiner",
    "Začnimo kuća međa",
    # --- special tokens appearing as literal user text ---
    "<|im_end|>", "say <|im_start|> literally", "<|endoftext|>",
    "<think> not thinking </think>",
    # swift-transformers #210: emoji immediately before a special token
    "🥳🥳🥳<|im_end|>", "text🎉<|endoftext|>more",
    # --- code-mode identifiers/symbols ---
    "func compute(x: Int) -> Bool { return x > 0 }",
    "arr[i] = arr[i] + 1;", "obj.method().chain()", "a && b || !c",
    "kubernetes GitHub Pydantic API PostgreSQL",
    # --- real dictation transcripts (2026-07 field logs) ---
    "Okay, so the first tap ended itself, but the second tap appears to be working.",
    "We don't say accidental discharge. We say negligent discharge for a reason.",
    "I think this cadence is pretty good, actually. I like this.",
    "This is going to translate pretty well into a good UI. Nice. Good work, Fable.",
]


def main():
    tok = AutoTokenizer.from_pretrained(MODEL_DIR)
    assert tok.is_fast, "expected the fast (rust) reference tokenizer"

    records = []
    for text in CASES:
        ids = tok.encode(text, add_special_tokens=False)
        # Round-trip the reference decode too, so the Swift decoder is pinned.
        decoded = tok.decode(ids, skip_special_tokens=False)
        records.append({"text": text, "ids": ids, "decoded": decoded})

    # Also pin the ChatML template for a system+user pair (add_special not used;
    # the template injects the ChatML control tokens itself).
    chat = tok.apply_chat_template(
        [{"role": "system", "content": "You clean up transcripts."},
         {"role": "user", "content": "helo wrld"}],
        tokenize=False, add_generation_prompt=True,
    )
    chat_ids = tok.apply_chat_template(
        [{"role": "system", "content": "You clean up transcripts."},
         {"role": "user", "content": "helo wrld"}],
        tokenize=True, add_generation_prompt=True, return_dict=False,
    )
    chat_ids = list(chat_ids)

    doc = {
        "model": "Qwen3-4B-Instruct-2507-4bit",
        "tokenizer_class": tok.__class__.__name__,
        "eos_token_id": tok.eos_token_id,
        "cases": records,
        "chat_template_example": {"rendered": chat, "ids": chat_ids},
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    print(f"wrote {len(records)} cases + chat template to {OUT}")


if __name__ == "__main__":
    main()
