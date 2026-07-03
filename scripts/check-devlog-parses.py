#!/usr/bin/env python3
"""Acceptance check (PLAN.md §14): the dev transcript log must parse with
pandas.read_json(lines=True). Pass a path, or default to the live log."""
import os
import sys

import pandas as pd

path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "~/Documents/dictation-dev/transcripts.jsonl"
)
df = pd.read_json(path, lines=True)
print(f"PASS: {len(df)} records parsed from {path}")
print(df.groupby("type").size().to_string())
print(f"columns: {sorted(df.columns)}")
