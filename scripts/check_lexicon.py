#!/usr/bin/env python3
"""Quick lexicon asserts — no GUI. Mirrors DictionaryStore TSV + auto-code rules."""
from __future__ import annotations
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZIMB = ROOT / "Resources/tables/cht_zimb_VISTA.tsv"
CIMB = ROOT / "Resources/tables/cht_cimb_VISTA.tsv"

def load_tsv(path: Path):
    exact = defaultdict(list)
    # ch -> best (code, len, xh, jm)
    best = {}
    with path.open(encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        lower = [h.lower() for h in header]
        code_i, word_i = lower.index("srm"), lower.index("hz")
        has_jm = "jm" in lower
        jm_i = lower.index("jm") if has_jm else None
        xh_i = lower.index("xh") if "xh" in lower else None
        for n, line in enumerate(f, 1):
            cols = line.rstrip("\n").split("\t")
            if len(cols) <= max(code_i, word_i):
                continue
            code, word = cols[code_i], cols[word_i]
            if not code.isdigit() or not word:
                continue
            if word not in exact[code]:
                exact[code].append(word)
            if len(word) == 1:
                jm = (cols[jm_i] == "1") if jm_i is not None and jm_i < len(cols) else len(code) <= 2
                xh = int(cols[xh_i]) if xh_i is not None and xh_i < len(cols) and cols[xh_i].isdigit() else n
                ln = len(code)
                cur = best.get(word)
                def better(cur, code, ln, xh, jm):
                    if cur is None:
                        return True
                    if cur[3] and not jm:
                        return True
                    if cur[3] == jm:
                        if not jm and ln == 4 and cur[1] != 4:
                            return True
                        if not jm and cur[1] == 4 and ln != 4:
                            return False
                        if ln > cur[1] and cur[1] != 4:
                            return True
                        if ln == cur[1] and xh >= cur[2]:
                            return True
                    return False
                if better(cur, code, ln, xh, jm):
                    best[word] = (code, ln, xh, jm)
    char_primary = {ch: meta[0] for ch, meta in best.items()}
    return exact, char_primary

def compute_code(phrase: str, char_primary: dict) -> str | None:
    chars = list(phrase)
    primaries = []
    for ch in chars:
        if ch not in char_primary:
            return None
        primaries.append(char_primary[ch])
    n = len(primaries)
    if n == 1:
        slices = [6]
    elif n == 2:
        slices = [3, 3]
    elif n == 3:
        slices = [2, 2, 2]
    elif n == 4:
        slices = [2, 1, 1, 2]
    else:
        slices = [2, 1, 1, 1, 1]
    out = ""
    for i, need in enumerate(slices):
        if i >= len(primaries):
            break
        out += primaries[i][:need]
    return out[:6]

def main() -> int:
    assert ZIMB.is_file(), f"missing {ZIMB}"
    assert CIMB.is_file(), f"missing {CIMB}"
    z_exact, char_primary = load_tsv(ZIMB)
    c_exact, _ = load_tsv(CIMB)
    exact = defaultdict(list)
    for d in (z_exact, c_exact):
        for k, words in d.items():
            for w in words:
                if w not in exact[k]:
                    exact[k].append(w)

    z_rows = sum(len(v) for v in z_exact.values())
    c_rows = sum(len(v) for v in c_exact.values())
    print(f"zimb entries: {z_rows}  cimb entries: {c_rows}  codes: {len(exact)}  charPrimary: {len(char_primary)}")

    checks = []
    def check(name, cond, detail=""):
        checks.append((name, cond, detail))
        print(("PASS" if cond else "FAIL"), name, detail)

    check("0307 contains 我", "我" in exact.get("0307", []))
    check("0 → 的", "的" in exact.get("0", []))
    check("0 → 香港", "香港" in exact.get("0", []))
    check("9 → 小", "小" in exact.get("9", []))
    check("289449 → 縱橫", "縱橫" in exact.get("289449", []))
    check("縱 primary 2898", char_primary.get("縱") == "2898", char_primary.get("縱"))
    check("橫 primary 4498", char_primary.get("橫") == "4498", char_primary.get("橫"))
    code = compute_code("縱橫", char_primary)
    check("auto-code 縱橫 → 289449", code == "289449", code)
    # 簡碼 singles order: first in zimb for 0 should be 的
    check("0 first single 的", exact.get("0", [None])[0] == "的", exact.get("0", [])[:3])

    failed = [n for n, ok, _ in checks if not ok]
    print(f"\n{len(checks)-len(failed)}/{len(checks)} passed")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
