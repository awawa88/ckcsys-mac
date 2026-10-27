import Foundation

/// Minimal replica of DictionaryStore prefix/exact gates used by CKCInputController digit path.
final class Lex {
    var exact: [String: [String]] = [:]
    var userExact: [String: [String]] = [:]
    var prefixIndex: [String: [String]] = [:]

    func loadTSV(_ url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in s.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 2 else { continue }
            let code = cols[0], word = cols[1]
            guard !code.isEmpty, code.allSatisfy(\.isNumber), !word.isEmpty else { continue }
            var list = exact[code] ?? []
            if !list.contains(word) { list.append(word) }
            exact[code] = list
        }
    }

    func loadUser(_ url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in s.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") { continue }
            let cols = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard cols.count == 2 else { continue }
            let code = cols[0], word = cols[1]
            guard code.allSatisfy(\.isNumber) else { continue }
            var list = userExact[code] ?? []
            if !list.contains(word) { list.append(word) }
            userExact[code] = list
        }
    }

    func buildPrefix() {
        prefixIndex.removeAll()
        let allKeys = Set(exact.keys).union(userExact.keys)
        var tmp: [String: [String]] = [:]
        for key in allKeys {
            let chars = Array(key)
            for i in 1...chars.count {
                let p = String(chars[..<i])
                tmp[p, default: []].append(key)
            }
        }
        for (p, keys) in tmp { prefixIndex[p] = keys.sorted() }
    }

    func hasLongerCode(_ code: String) -> Bool {
        guard let keys = prefixIndex[code] else { return false }
        return keys.contains { $0.count > code.count }
    }
    func hasLongerUserCode(_ code: String) -> Bool {
        for key in userExact.keys where key.count > code.count && key.hasPrefix(code) { return true }
        return false
    }
    func hasCode(withPrefix prefix: String) -> Bool {
        guard let keys = prefixIndex[prefix] else { return false }
        return !keys.isEmpty
    }
    func hasUserCode(withPrefix prefix: String) -> Bool {
        for key in userExact.keys where key == prefix || key.hasPrefix(prefix) { return true }
        return false
    }
    func hasExactPhrase(_ code: String) -> Bool {
        if let u = userExact[code], u.contains(where: { $0.count >= 2 }) { return true }
        if let s = exact[code], s.contains(where: { $0.count >= 2 }) { return true }
        return false
    }
    func phrases(_ code: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for w in (userExact[code] ?? []) + (exact[code] ?? []) where w.count >= 2 {
            if seen.insert(w).inserted { out.append(w) }
        }
        // prefix expansions (stock+user longer), user first — mirrors candidates() preference lightly
        if let keys = prefixIndex[code] {
            for key in keys where key != code {
                for w in (userExact[key] ?? []) + (exact[key] ?? []) where w.count >= 2 {
                    if seen.insert(w).inserted { out.append(w) }
                }
                if out.count >= 120 { break }
            }
        }
        return out
    }
    func chars(_ code: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for w in (userExact[code] ?? []) + (exact[code] ?? []) where w.count == 1 {
            if seen.insert(w).inserted { out.append(w) }
        }
        if let keys = prefixIndex[code] {
            for key in keys where key != code {
                for w in (exact[key] ?? []) where w.count == 1 {
                    if seen.insert(w).inserted { out.append(w) }
                }
                if out.count >= 120 { break }
            }
        }
        return out
    }
}

enum Look: String { case all, phrases, characters }

/// Mirrors 0.2.26 controller decision for one digit after a given buffer/lookKind.
func decide(lex: Lex, buffer: String, look: Look, digit: Int, inactive: Bool) -> String {
    let phrases = lex.phrases(buffer)
    let chars = lex.chars(buffer)
    let hasCandidates = !phrases.isEmpty || !chars.isEmpty
    let exactPhrase = lex.hasExactPhrase(buffer)
    let longer = lex.hasLongerCode(buffer)
    let userLonger = lex.hasLongerUserCode(buffer)

    func shouldAuto() -> Bool {
        if buffer.isEmpty { return false }
        if userLonger { return false }
        if !longer { return !phrases.isEmpty || !chars.isEmpty }
        return exactPhrase && chars.isEmpty && !phrases.isEmpty
    }

    if inactive {
        let armed = (look == .phrases || look == .characters) && digit >= 1 && digit <= 9 && hasCandidates
        if !armed { return "PASSTHROUGH_ASCII digit=\(digit)" }
    }

    if digit >= 1 && digit <= 9 && hasCandidates {
        if look == .phrases {
            let pick = phrases.indices.contains(digit - 1) ? phrases[digit - 1] : Optional<String>.none
            if let p = pick { return "PHRASE_PICK '\(p)' (armed look=phrases)" }
            return "PHRASE_PICK_MISS"
        }
        if look == .characters {
            let pick = chars.indices.contains(digit - 1) ? chars[digit - 1] : Optional<String>.none
            if let p = pick { return "CHAR_PICK '\(p)'" }
            return "CHAR_PICK_MISS"
        }
        if inactive { return "PASSTHROUGH_ASCII digit=\(digit)" }
    }

    // .all compose path with auto one-shot
    var look2 = look
    if shouldAuto() {
        let extended = buffer + String(digit)
        if lex.hasUserCode(withPrefix: extended) {
            return "COMPOSE_USER_EXTEND '\(extended)'"
        } else {
            // enter auto + pick
            look2 = !phrases.isEmpty ? .phrases : .characters
            if look2 == .phrases, digit >= 1, digit <= 9, phrases.indices.contains(digit - 1) {
                return "AUTO_PHRASE_PICK '\(phrases[digit - 1])' stockExtends=\(lex.hasCode(withPrefix: extended))"
            }
            return "AUTO_ENTER_\(look2.rawValue) (no pick)"
        }
    }
    let next = buffer + String(digit)
    var afterLook = "all"
    // after append auto-enter
    let phrasesN = lex.phrases(next)
    let charsN = lex.chars(next)
    let exactN = lex.hasExactPhrase(next)
    let longerN = lex.hasLongerCode(next)
    let userLongerN = lex.hasLongerUserCode(next)
    let autoN: Bool = {
        if next.isEmpty { return false }
        if userLongerN { return false }
        if !longerN { return !phrasesN.isEmpty || !charsN.isEmpty }
        return exactN && charsN.isEmpty && !phrasesN.isEmpty
    }()
    if autoN { afterLook = !phrasesN.isEmpty ? "phrases" : "characters" }
    return "COMPOSE '\(next)' then look=\(afterLook) phrases=\(phrasesN.count) first=\(phrasesN.first ?? "-")"
}

let root = URL(fileURLWithPath: NSHomeDirectory() + "/Projects/ckcsys-mac")
let lex = Lex()
lex.loadTSV(root.appendingPathComponent("Resources/tables/cht_cimb_VISTA.tsv"))
lex.loadTSV(root.appendingPathComponent("Resources/tables/cht_zimb_VISTA.tsv"))
lex.loadUser(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/CKC縱橫/user_phrases.tsv"))
lex.buildPrefix()

print("lex exact[06177]=\(lex.exact["06177"] ?? [])")
print("lex hasLonger(06177)=\(lex.hasLongerCode("06177")) userLonger=\(lex.hasLongerUserCode("06177")) stock061771=\(lex.hasCode(withPrefix: "061771"))")
print("lex phrases(06177)[0]=\(lex.phrases("06177").first ?? "?") count=\(lex.phrases("06177").count) chars=\(lex.chars("06177").count)")
print("lex phrases(5883) auto? userLonger=\(lex.hasLongerUserCode("5883")) exact=\(lex.hasExactPhrase("5883"))")
print("lex phrases(58834).first=\(lex.phrases("58834").first ?? "?")")

var failed = 0
func check(_ name: String, _ got: String, contains: String) {
    let ok = got.contains(contains)
    print("\(ok ? "OK" : "FAIL") \(name) => \(got)")
    if !ok { failed += 1 }
}

// Step through 06177 compose
var buf = ""
var look = Look.all
for d in [0, 6, 1, 7, 7] {
    let r = decide(lex: lex, buffer: buf, look: look, digit: d, inactive: false)
    print("TYPE \(d) @'\(buf)' look=\(look.rawValue) => \(r)")
    if r.hasPrefix("COMPOSE '") {
        if let s = r.split(separator: "'").dropFirst().first {
            buf = String(s)
        }
        if r.contains("look=phrases") { look = .phrases }
        else if r.contains("look=characters") { look = .characters }
        else { look = .all }
    }
}
check("after 06177 auto-armed", "look=\(look.rawValue) buf=\(buf)", contains: "look=phrases")

// Critical: armed phrase mode + digit 1 → 自己 (even though stock 061771 exists)
check("armed auto +1", decide(lex: lex, buffer: "06177", look: .phrases, digit: 1, inactive: false), contains: "自己")
check("manual 選詞 +1", decide(lex: lex, buffer: "06177", look: .phrases, digit: 1, inactive: false), contains: "PHRASE_PICK '自己'")
check("armed + inactive-row 1", decide(lex: lex, buffer: "06177", look: .phrases, digit: 1, inactive: true), contains: "自己")
check("OLD BUG stock extend must NOT win", decide(lex: lex, buffer: "06177", look: .phrases, digit: 1, inactive: false), contains: "PHRASE_PICK")

// 5883+user58834: no auto; digit 4 composes
let d5883 = decide(lex: lex, buffer: "5883", look: .all, digit: 4, inactive: false)
check("5883+4 compose 輸入法 path", d5883, contains: "COMPOSE '58834'")
let after58834 = decide(lex: lex, buffer: "58834", look: .all, digit: 1, inactive: false)
// at 58834 may auto or pick — first phrase should be 輸入法 when picking in phrases
let p58834 = lex.phrases("58834")
check("58834 first phrase 輸入法", p58834.first ?? "", contains: "輸入法")
// after explicit 選詞 at 5883, digit 1 picks not extend
check("5883 選詞 +1 picks not extend", decide(lex: lex, buffer: "5883", look: .phrases, digit: 1, inactive: false), contains: "PHRASE_PICK")

if failed > 0 {
    fputs("FAILED \(failed) checks\n", stderr)
    exit(1)
}
print("ALL CHECKS PASSED")
