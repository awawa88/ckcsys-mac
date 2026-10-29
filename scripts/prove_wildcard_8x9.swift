import Foundation

final class Lex {
    var exact: [String: [String]] = [:]
    let cap = 120

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

    /// Fixed algorithm (exact-length first, then longer; cap on words).
    func candidatesWildcard(pattern: String, charactersOnly: Bool) -> [String] {
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
        let longer = allKeys.filter { $0.count > plen && matches($0) }.sorted {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0 < $1
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

    /// Old broken algorithm (cap on keys, prefix-style).
    func candidatesWildcardOld(pattern: String, charactersOnly: Bool) -> [String] {
        let pats = Array(pattern)
        var matched: [String] = []
        for key in exact.keys.sorted() {
            let ks = Array(key)
            if ks.count < pats.count { continue }
            var ok = true
            for i in 0..<pats.count {
                if pats[i] != "?" && pats[i] != ks[i] { ok = false; break }
            }
            if ok { matched.append(key) }
            if matched.count >= cap { break }
        }
        var out: [String] = []
        var seen = Set<String>()
        for k in matched {
            for c in exact[k] ?? [] {
                if charactersOnly && c.count != 1 { continue }
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

let old = lex.candidatesWildcardOld(pattern: "8?9", charactersOnly: true)
let neu = lex.candidatesWildcard(pattern: "8?9", charactersOnly: true)
print("OLD chars(\(old.count)): \(old.prefix(12).joined(separator: ","))")
print("NEW chars(\(neu.count)): \(neu.prefix(20).joined(separator: ","))")

let hasCe = neu.contains("策")
let hasZhu = neu.contains("築")
let has889 = hasCe && hasZhu
print("889 chars present (策,築): \(has889)")
if !has889 {
    fputs("FAIL: 889 選字 missing\n", stderr)
    exit(1)
}
if old.contains("策") {
    print("NOTE: old algo unexpectedly had 策 (cap may not have bitten on this machine state)")
} else {
    print("OLD missing 策 (as expected) — NEW fixed")
}
print("PROVE OK")
