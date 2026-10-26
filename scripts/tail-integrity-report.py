#!/usr/bin/env python3
"""Counts how often a committed dictation's tail disagrees with what the user
saw, from the dev log (NOTES: "Tail integrity at commit").

Usage: python3 -I scripts/tail-integrity-report.py ~/Documents/dictation-dev/debug.log

A log record is a timestamped line plus the untimestamped lines that follow it,
because COMMIT and display text span lines. A session runs from
`hotkey action: startDictation` to the next one; sessions that `cancel`,
that are restarted before committing, or that commit a redacted secure-input
field are skipped. Words are compared lowercased with punctuation stripped,
because cleanup rewrites both sides.

Four counts per committed session:
  late draft      an `asr draft` record followed `audio stream ended`.
  invented tail   the commit text ends with two words that appear in no
                  pre-commit draft (pre-commit means before `hotkey action: commit`).
  lost tail       the last pre-commit draft ends with two words, both absent
                  from the commit text.
  short, late final
                  among sessions under 10 s (`audio stream ended after N
                  chunks`, 256 ms each), an `asr final` was logged after the
                  COMMIT record, so its text missed the injected snapshot.

From the windows-by-pause change on (NOTES), finals arrive at each pause and
after 12 s of unbroken speech, not only at the commit, so a session of any
length can have finals before `audio stream ended`. The 10 s cut-off below
dates from the sliding window and is unchanged.

The late draft count can include a harmless draft that finished after `audio
stream ended` but before the engine closed drafts, since that one lands before
the settle and is part of the snapshot.

Matching is rough: a re-decode that changes a word counts as a loss and an
invention, so the counts are upper bounds.
"""
import re
import sys

# A line is `<timestamp> [s:<session id>] <message>`: the timestamp has
# optional milliseconds and the session id is present while a session is open.
# Both are consumed here so the record text starts at the message itself.
TIMESTAMP = re.compile(
    r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z) (?:\[s:[0-9A-Fa-f]+\] )?(.*)$"
)
# The committed text follows the first "))" + ": " (injected outcomes) or the
# older "(would inject): " form.
COMMIT_TEXT = re.compile(r"\)\): |\(would inject\): ")
CHUNK_SECONDS = 0.256
SHORT_SESSION_SECONDS = 10
EXAMPLE_LIMIT = 10
TAIL_CHARS = 60


def read_records(path):
    """Yield (timestamp, text) per record, joining continuation lines."""
    record = None
    with open(path, encoding="utf-8", errors="replace") as log:
        for line in log:
            line = line.rstrip("\n")
            match = TIMESTAMP.match(line)
            if match:
                if record:
                    yield record
                record = [match.group(1), match.group(2)]
            elif record:
                record[1] += "\n" + line
    if record:
        yield record


def words(text):
    return re.findall(r"[a-z0-9]+", text.lower().replace("'", ""))


def split_sessions(records):
    """Yield the records of each session that reached a COMMIT with text. A
    session runs until the next startDictation, so records that arrive after
    its COMMIT record belong to it."""
    session, committed = None, False
    for stamp, text in records:
        if text.startswith("hotkey action: startDictation"):
            if session and committed:
                yield session
            session, committed = [], False
        elif session is None:
            continue
        elif text.startswith("hotkey action: cancel") and not committed:
            session = None
            continue
        session.append((stamp, text))
        if text.startswith("COMMIT "):
            committed = "skippedSecureInput" not in text.split("\n")[0][:60]
            if not committed:
                session = None
    if session and committed:
        yield session


def analyse(session):
    stamp = session[0][0]
    commit_action = ended = commit_index = None
    chunks = None
    pre_commit_drafts, finals_after_commit, drafts_after_ended = [], 0, 0
    commit_text = ""
    for index, (_, text) in enumerate(session):
        if text.startswith("hotkey action: commit"):
            commit_action = index
        elif text.startswith("audio stream ended"):
            ended = index
            found = re.search(r"after (\d+) chunks", text)
            chunks = int(found.group(1)) if found else None
        elif text.startswith("asr draft"):
            body = text.split(": ", 1)[1] if ": " in text else ""
            if commit_action is None:
                pre_commit_drafts.append(body)
            if ended is not None and commit_index is None:
                drafts_after_ended += 1
        elif text.startswith("asr final") and commit_index is not None:
            # The test suite's fake engine writes this line into the live log.
            if not text.endswith("flush final."):
                finals_after_commit += 1
        elif text.startswith("COMMIT ") and commit_index is None:
            commit_index = index
            commit_text = COMMIT_TEXT.split(text, maxsplit=1)[-1] if COMMIT_TEXT.search(text) else ""
    if commit_action is None or not commit_text.strip():
        return None

    commit_words = words(commit_text)
    seen = {word for draft in pre_commit_drafts for word in words(draft)}
    last_draft = pre_commit_drafts[-1] if pre_commit_drafts else ""
    last_draft_words = words(last_draft)

    return {
        "stamp": stamp,
        "late_draft": drafts_after_ended > 0,
        "invented": len(commit_words) >= 2 and bool(pre_commit_drafts)
            and not any(word in seen for word in commit_words[-2:]),
        "lost": len(last_draft_words) >= 2
            and not any(word in set(commit_words) for word in last_draft_words[-2:]),
        "short": chunks is not None and chunks * CHUNK_SECONDS < SHORT_SESSION_SECONDS,
        "late_final": finals_after_commit > 0,
        "draft_tail": last_draft[-TAIL_CHARS:],
        "commit_tail": commit_text.strip()[-TAIL_CHARS:],
    }


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sessions = [s for s in map(analyse, split_sessions(read_records(sys.argv[1]))) if s]
    total = len(sessions)
    short = [s for s in sessions if s["short"]]
    counts = [
        ("late draft (draft after audio stream ended)", "late_draft", sessions),
        ("invented tail (commit ends in words no draft showed)", "invented", sessions),
        ("lost tail (last draft ends in words the commit lacks)", "lost", sessions),
        ("short session with a final that arrived after the injected snapshot",
         "late_final", short),
    ]
    print(f"committed sessions: {total} (under {SHORT_SESSION_SECONDS} s: {len(short)})")
    for label, key, pool in counts:
        hits = [s for s in pool if s[key]]
        print(f"{label}: {len(hits)} of {len(pool)}")
    for label, key, pool in counts:
        hits = [s for s in pool if s[key]]
        if not hits:
            continue
        print(f"\n{label}: up to {EXAMPLE_LIMIT} examples")
        for s in hits[-EXAMPLE_LIMIT:]:
            print(f"  {s['stamp']}\n    draft:  ...{s['draft_tail']}\n    commit: ...{s['commit_tail']}")


if __name__ == "__main__":
    main()
