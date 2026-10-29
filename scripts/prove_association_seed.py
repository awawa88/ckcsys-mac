#!/usr/bin/env python3
"""Prove shortest-seed-first association against Mac lexicon tables (no invented phrases)."""
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[1]
CIMB = ROOT / "Resources" / "tables" / "cht_cimb_VISTA.tsv"


def load_by_first():
    by = defaultdict(list)
    with CIMB.open(encoding="utf-8", errors="ignore") as f:
        header = None
        hz_i = pd_i = None
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            cols = s.split("\t")
            if header is None:
                lower = [c.strip().lower() for c in cols]
                if "hz" in lower:
                    hz_i = lower.index("hz")
                    pd_i = lower.index("pd") if "pd" in lower else None
                    header = True
                    continue
                hz_i, pd_i = 1, 2
                header = True
            if hz_i >= len(cols):
                continue
            w = cols[hz_i].strip()
            if len(w) < 2:
                continue
            pd = int(cols[pd_i]) if pd_i is not None and pd_i < len(cols) and cols[pd_i].strip().isdigit() else 0
            by[w[0]].append((pd, w))
    out = {}
    for ch, pairs in by.items():
        seen = set()
        words = []
        for _, w in sorted(pairs, key=lambda x: -x[0]):
            if w not in seen:
                seen.add(w)
                words.append(w)
                if len(words) >= 400:
                    break
        out[ch] = words
    return out


def phrases_starting(index, prefix, show_cap=90):
    if not prefix:
        return []
    allw = index.get(prefix[0], [])
    filtered = [w for w in allw if w.startswith(prefix) and len(w) > len(prefix)]
    # shorter first (stable)
    filtered = sorted(enumerate(filtered), key=lambda iv: (len(iv[1]), iv[0]))
    filtered = [w for _, w in filtered]
    return filtered[:show_cap]


def best(index, context, max_len=6, show_cap=90):
    """Shortest viable seed first; longer-suffix continuations after (reserved slots)."""
    if not context:
        return None
    upper = min(len(context), max_len)
    primary = None
    short_phrases = []
    longer_phrases = []
    longer_seen = set()
    for length in range(1, upper + 1):
        seed = context[-length:]
        ph = phrases_starting(index, seed, show_cap=show_cap)
        if not ph:
            continue
        if primary is None:
            primary = seed
            short_phrases = ph
        else:
            for w in ph:
                if w not in short_phrases and w not in longer_seen:
                    longer_seen.add(w)
                    longer_phrases.append(w)
    if primary is None or not short_phrases:
        return None
    if not longer_phrases:
        merged = short_phrases[:show_cap]
    else:
        reserve = min(20, max(1, show_cap // 3), len(longer_phrases))
        short_keep = max(0, show_cap - reserve)
        merged = short_phrases[:short_keep]
        for w in longer_phrases:
            if len(merged) >= show_cap:
                break
            merged.append(w)
    return primary, merged[:show_cap]


def main():
    idx = load_by_first()
    # Simulate: commit 香 then 港
    ctx = ""
    for step in ["香", "港"]:
        ctx += step
        if len(ctx) > 6:
            ctx = ctx[-6:]
        hit = best(idx, ctx)
        assert hit, f"no hit for {ctx}"
        seed, ph = hit
        print(f"after '{step}' context='{ctx}' seed='{seed}' top={ph[:8]} (n={len(ph)})")
    # After 香港: primary seed is last 字 港 (not 香港)
    assert seed == "港", seed
    assert ph[0].startswith("港"), ph[:10]
    # Longer context continuations (香港…) still appear, but after short-seed hits
    long_hits = [w for w in ph if w.startswith("香港")]
    short_hits = [w for w in ph if w.startswith("港") and not w.startswith("香港")]
    assert short_hits, ph[:15]
    assert long_hits, "expected some 香港… continuations lower in the list"
    first_long = next(i for i, w in enumerate(ph) if w.startswith("香港"))
    first_short = next(i for i, w in enumerate(ph) if w.startswith("港") and not w.startswith("香港"))
    assert first_short < first_long, (first_short, first_long, ph[:20])
    # After picking 港口 from association (matched seed 港)
    prior = "港"
    full = "港口"
    assert ctx.endswith(prior)
    ctx = ctx[: -len(prior)] + full
    hit = best(idx, ctx)
    seed, ph = hit
    print(f"after pick '{full}' context='{ctx}' seed='{seed}' top={ph[:8]} (n={len(ph)})")
    # Context 香港口 → shortest seed 口 first
    assert seed == "口", seed
    assert ph[0].startswith("口"), ph[:10]
    print("PASS")


if __name__ == "__main__":
    main()
