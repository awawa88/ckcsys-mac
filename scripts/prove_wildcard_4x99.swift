#!/usr/bin/env swift
import Foundation

/// Prove Mac wildcard 選字 mirrors iOS 0.1.8 intent:
/// - `4?99` includes 林; count matches lexicon exact-length chars
/// - dedicated wildcardResultCap=600 covers worst single-`?` exact-length 選字
///   (old shared prefixResultCap=120 truncated those)

final class Lex {
    var exact: [String: [String]] = [:]
    let wildcardResultCap = 600
    let oldPrefixCap = 120

    func loadTSV(_ url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        var first = true
        for line in s.split(whereSeparator: \.isNewline) {
            if first { first = false; continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 2 else { continue }
            let code = cols[0], word = cols[1]
            guard !code.isEmpty, code.allSatisfy(\.isNumber), !word.isEmpty else { continue }
            var list = exact[code] ?? []
            if !list.contains(word) { list.append(word) }
            exact[code] = list
        }
    }

    /// exactLengthOnly: stop after exact-length keys (lexicon count for 選字 intent)
    func candidatesWildcard(pattern: String, charactersOnly: Bool, cap: Int, exactLengthOnly: Bool = false) -> [String] {
        let pats = Array(pattern)
        let plen = pats.count
        func matches(_ key: String) -> Bool {
            let ks = Array(key)
            guard ks.count >= plen else { return false }
            for i in 0..<plen {
                if pats[i] != "?" && pats[i] != ks[i] { return false }
            }
            return true
        }
        let allKeys = Set(exact.keys)
        let exactLen = allKeys.filter { $0.count == plen && matches($0) }.sorted()
        let longer: [String]
        if exactLengthOnly {
            longer = []
        } else {
            longer = allKeys.filter { $0.count > plen && matches($0) }.sorted {
                if $0.count != $1.count { return $0.count < $1.count }
                return $0 < $1
            }
        }
        var out: [String] = []
        var seen = Set<String>()
        for k in exactLen + longer {
            for c in exact[k] ?? [] {
                if charactersOnly && c.count != 1 { continue }
                if !charactersOnly && c.count < 2 { continue }
                if seen.insert(c).inserted {
                    out.append(c)
                    if out.count >= cap { return out }
                }
            }
        }
        return out
    }
}

let root = URL(fileURLWithPath: NSHomeDirectory() + "/Projects/ckcsys-mac/Resources/tables")
let lex = Lex()
lex.loadTSV(root.appendingPathComponent("cht_zimb_VISTA.tsv"))
lex.loadTSV(root.appendingPathComponent("cht_cimb_VISTA.tsv"))
print("loaded keys=\(lex.exact.count)")

let pattern = "4?99"
let lexicon = lex.candidatesWildcard(pattern: pattern, charactersOnly: true, cap: 999_999, exactLengthOnly: true)
let neu = lex.candidatesWildcard(pattern: pattern, charactersOnly: true, cap: lex.wildcardResultCap)
let old = lex.candidatesWildcard(pattern: pattern, charactersOnly: true, cap: lex.oldPrefixCap)
let idx = neu.firstIndex(of: "林")
print("pattern=\(pattern) lexiconExactChars=\(lexicon.count) new=\(neu.count) old120=\(old.count) has林=\(idx != nil) index=\(idx.map(String.init) ?? "nil")")
guard neu.contains("林") else {
    fputs("FAIL: 林 missing under wildcardResultCap\n", stderr)
    exit(2)
}
guard lexicon.contains("林") else {
    fputs("FAIL: 林 not in lexicon exact-length set\n", stderr)
    exit(2)
}
// Full algorithm may add longer-prefix chars; exact-length set must be subset of new result
for ch in lexicon where !neu.contains(ch) {
    fputs("FAIL: exact-length char \(ch) missing under new cap\n", stderr)
    exit(3)
}
print("4?99: all \(lexicon.count) exact-length 選字 reachable (incl. 林 @ \(idx!))")

let busy = "4?"
let busyLex = lex.candidatesWildcard(pattern: busy, charactersOnly: true, cap: 999_999, exactLengthOnly: true)
let busyNewExact = lex.candidatesWildcard(pattern: busy, charactersOnly: true, cap: lex.wildcardResultCap, exactLengthOnly: true)
let busyOldExact = lex.candidatesWildcard(pattern: busy, charactersOnly: true, cap: lex.oldPrefixCap, exactLengthOnly: true)
let busyNewFull = lex.candidatesWildcard(pattern: busy, charactersOnly: true, cap: lex.wildcardResultCap)
print("pattern=\(busy) lexiconExactChars=\(busyLex.count) newExact=\(busyNewExact.count) old120Exact=\(busyOldExact.count) newFull=\(busyNewFull.count)")
guard busyLex.count > lex.oldPrefixCap else {
    fputs("FAIL: expected \(busy) exact-length > 120 for truncation demo\n", stderr)
    exit(4)
}
guard busyOldExact.count == lex.oldPrefixCap else {
    fputs("FAIL: old cap did not bite on \(busy) exact-length\n", stderr)
    exit(5)
}
guard busyNewExact.count == busyLex.count else {
    fputs("FAIL: new cap still truncates exact-length \(busy) (\(busyNewExact.count)/\(busyLex.count))\n", stderr)
    exit(6)
}
guard busyLex.count <= lex.wildcardResultCap else {
    fputs("FAIL: lexicon exact-length \(busy) exceeds wildcardResultCap — raise cap\n", stderr)
    exit(7)
}

print("BEFORE: shared prefixResultCap=120 truncated exact-length \(busy) to \(busyOldExact.count)/\(busyLex.count)")
print("AFTER:  dedicated wildcardResultCap=600 returns all \(busyLex.count) exact-length 選字 for \(busy)")
print("NOTE: CandidateWindow pages pageSize=9 through full array (no UI prefix hard-cap)")
print("PROVE OK")
