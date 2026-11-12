#!/usr/bin/env python3
"""Verify bundled lexicon: Cantonese customs rank first under their codes."""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZIMB = ROOT / "Resources/tables/cht_zimb_VISTA.tsv"
CIMB = ROOT / "Resources/tables/cht_cimb_VISTA.tsv"

EXPECTED = {
    "120303": "而家",
    "33161": "試一吓",
    "336613": "試吓",
    "363121": "邊到",
    "478404": "超好",
    "483271": "大灣區",
    "610406": "唔值得",
    "613070": "點解",
    "66304": "嗰度",
    "782641": "除咗",
    "616052": "唄使",
}


def load_paths(*paths: Path) -> dict[str, list[str]]:
    exact: dict[str, list[str]] = defaultdict(list)
    for path in paths:
        with path.open(encoding="utf-8") as f:
            header = f.readline()
            if not header.lower().startswith("srm"):
                f.seek(0)
            for line in f:
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 2:
                    continue
                code, word = cols[0].strip(), cols[1].strip()
                if not code.isdigit() or not word:
                    continue
                if word not in exact[code]:
                    exact[code].append(word)
    return exact


def main() -> int:
    exact = load_paths(ZIMB, CIMB)
    ok = True
    for code, want in sorted(EXPECTED.items()):
        hits = exact.get(code, [])
        phrase_hits = [h for h in hits if len(h) >= 2]
        first = phrase_hits[0] if phrase_hits else None
        count = sum(1 for h in hits if h == want)
        line_ok = first == want and count == 1
        ok = ok and line_ok
        print(
            f"{code}: first_phrase={first!r} want={want!r} "
            f"dup_count={count} {'PASS' if line_ok else 'FAIL'}"
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
