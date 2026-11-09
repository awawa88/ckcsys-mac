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
    func isListedExactPhrase(_ phrase: String, atCode code: String) -> Bool {
        guard phrase.count >= 2 else { return false }
        if let u = userExact[code], u.contains(phrase) { return true }
        if let s = exact[code], s.contains(phrase) { return true }
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

    func shouldComposeOver(digit: Int, phraseList: [String]) -> Bool {
        guard buffer.count < 6 else { return false }
        let extended = buffer + String(digit)
        if lex.hasUserCode(withPrefix: extended) { return true }
        guard lex.hasCode(withPrefix: extended) else { return false }
        if digit == 0 { return true }
        guard extended.count == 6, digit >= 1, digit <= 9 else { return false }
        if phraseList.indices.contains(digit - 1) {
            let pick = phraseList[digit - 1]
            if lex.isListedExactPhrase(pick, atCode: buffer) { return false }
        }
        return true
    }

    if inactive {
        let armed = (look == .phrases || look == .characters) && digit >= 1 && digit <= 9 && hasCandidates
        if !armed { return "PASSTHROUGH_ASCII digit=\(digit)" }
    }

    var look2 = look
    var phraseCompose = false
    if digit >= 1 && digit <= 9 && hasCandidates {
        if look == .phrases {
            if !shouldComposeOver(digit: digit, phraseList: phrases) {
                let pick = phrases.indices.contains(digit - 1) ? phrases[digit - 1] : Optional<String>.none
                if let p = pick { return "PHRASE_PICK '\(p)' (armed look=phrases)" }
                return "PHRASE_PICK_MISS"
            }
            look2 = .all
            phraseCompose = true
        } else if look == .characters {
            let pick = chars.indices.contains(digit - 1) ? chars[digit - 1] : Optional<String>.none
            if let p = pick { return "CHAR_PICK '\(p)'" }
            return "CHAR_PICK_MISS"
        }
        if inactive && !phraseCompose { return "PASSTHROUGH_ASCII digit=\(digit)" }
    }

    // .all compose path with auto one-shot
    if look2 == .all && shouldAuto() {
        let extended = buffer + String(digit)
        if shouldComposeOver(digit: digit, phraseList: phrases) {
            // fall through to append/compose below
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
    if r.hasPrefix("COMPOSE '") || r.hasPrefix("COMPOSE_DIGIT0_EXTEND '") || r.hasPrefix("COMPOSE_USER_EXTEND '") {
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

// 20338 exact 詞 + stock 203380: digit 0 must compose (never swallow into **)
print("lex exact[20338]=\(lex.exact["20338"] ?? []) chars=\(lex.chars("20338").count) longer=\(lex.hasLongerCode("20338")) stock203380=\(lex.hasCode(withPrefix: "203380"))")
print("lex phrases(203380).first=\(lex.phrases("203380").first ?? "?")")
check("20338+0 compose 終於 path", decide(lex: lex, buffer: "20338", look: .all, digit: 0, inactive: false), contains: "203380")
check("20338 phrases +0 still compose", decide(lex: lex, buffer: "20338", look: .phrases, digit: 0, inactive: false), contains: "203380")
check("20338+1 still auto-picks (not compose to 203381)", decide(lex: lex, buffer: "20338", look: .all, digit: 1, inactive: false), contains: "AUTO_PHRASE_PICK")
check("06177+0 stock-extends still compose if key exists", decide(lex: lex, buffer: "06177", look: .all, digit: 0, inactive: false), contains: "061770")

// 366069 class: exact 詞 midpoint (36606) must not swallow the 6th digit
print("lex exact[36606]=\(lex.exact["36606"] ?? []) hasLonger=\(lex.hasLongerCode("36606")) stock366069=\(lex.hasCode(withPrefix: "366069"))")
print("lex phrases(366069).first=\(lex.phrases("366069").first ?? "?")")
check("36606 armed +9 must compose 366069", decide(lex: lex, buffer: "36606", look: .phrases, digit: 9, inactive: false), contains: "366069")
check("36606 all +9 compose (one-shot)", decide(lex: lex, buffer: "36606", look: .all, digit: 9, inactive: false), contains: "366069")
var buf366 = ""
var look366 = Look.all
for d in [3, 6, 6, 0, 6, 9] {
    let r = decide(lex: lex, buffer: buf366, look: look366, digit: d, inactive: false)
    print("366069 TYPE \(d) @'\(buf366)' => \(r)")
    if r.hasPrefix("COMPOSE '") {
        if let s = r.split(separator: "'").dropFirst().first { buf366 = String(s) }
        if r.contains("look=phrases") { look366 = .phrases }
        else { look366 = .all }
    } else if r.hasPrefix("PHRASE_PICK") || r.hasPrefix("AUTO_PHRASE_PICK") {
        failed += 1
        print("FAIL 366069 path digit \(d) => \(r)")
    }
}
check("366069 full path buffer", "buf=\(buf366)", contains: "366069")

// 203380: stock 6-digit completion via 0
check("20338+0 still compose", decide(lex: lex, buffer: "20338", look: .all, digit: 0, inactive: false), contains: "203380")

if failed > 0 {
    fputs("FAILED \(failed) checks\n", stderr)
    exit(1)
}
print("ALL CHECKS PASSED")
