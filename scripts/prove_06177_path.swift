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

/// Mirrors Mac controller digit decision (0.2.62).
func decide(
    lex: Lex,
    buffer: String,
    look: Look,
    digit: Int,
    inactive: Bool,
    manualPhrasePick: Bool
) -> String {
    let phrases = lex.phrases(buffer)
    let chars = lex.chars(buffer)
    let hasCandidates = !phrases.isEmpty || !chars.isEmpty
    let longer = lex.hasLongerCode(buffer)
    let userLonger = lex.hasLongerUserCode(buffer)

    func shouldAuto() -> Bool {
        if buffer.isEmpty { return false }
        if userLonger { return false }
        guard !longer else { return false }
        return !phrases.isEmpty || !chars.isEmpty
    }

    func shouldComposeOver(digit: Int) -> Bool {
        guard buffer.count < 6 else { return false }
        if manualPhrasePick { return false }
        let extended = buffer + String(digit)
        if lex.hasUserCode(withPrefix: extended) { return true }
        return lex.hasCode(withPrefix: extended)
    }

    if inactive {
        let armed = (look == .phrases || look == .characters) && digit >= 1 && digit <= 9 && hasCandidates
        if !armed { return "PASSTHROUGH_ASCII digit=\(digit)" }
    }

    var look2 = look
    var phraseCompose = false
    if digit >= 1 && digit <= 9 && hasCandidates {
        if look == .phrases {
            if !shouldComposeOver(digit: digit) {
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

    if look2 == .all && shouldAuto() {
        let extended = buffer + String(digit)
        if shouldComposeOver(digit: digit) {
            // fall through to append
        } else {
            look2 = !phrases.isEmpty ? .phrases : .characters
            if look2 == .phrases, digit >= 1, digit <= 9, phrases.indices.contains(digit - 1) {
                return "AUTO_PHRASE_PICK '\(phrases[digit - 1])' stockExtends=\(lex.hasCode(withPrefix: extended))"
            }
            return "AUTO_ENTER_\(look2.rawValue) (no pick)"
        }
    }
    let next = buffer + String(digit)
    var afterLook = "all"
    let phrasesN = lex.phrases(next)
    let charsN = lex.chars(next)
    let longerN = lex.hasLongerCode(next)
    let userLongerN = lex.hasLongerUserCode(next)
    let autoN: Bool = {
        if next.isEmpty { return false }
        if userLongerN { return false }
        guard !longerN else { return false }
        return !phrasesN.isEmpty || !charsN.isEmpty
    }()
    if autoN { afterLook = !phrasesN.isEmpty ? "phrases" : "characters" }
    return "COMPOSE '\(next)' then look=\(afterLook) phrases=\(phrasesN.count) first=\(phrasesN.first ?? "-")"
}

func stepPath(lex: Lex, digits: [Int], manualAfterLen: [Int: Bool] = [:]) -> String {
    var buf = ""
    var look = Look.all
    var manual = false
    for d in digits {
        if manualAfterLen[buf.count] == true { manual = true; look = .phrases }
        let r = decide(lex: lex, buffer: buf, look: look, digit: d, inactive: false, manualPhrasePick: manual)
        if r.hasPrefix("COMPOSE '") {
            if let s = r.split(separator: "'").dropFirst().first { buf = String(s) }
            look = r.contains("look=phrases") ? .phrases : .all
            if look == .phrases && !manual { manual = false }
        } else {
            return "ABORT @'\(buf)' digit=\(d) => \(r)"
        }
    }
    return buf
}

let root = URL(fileURLWithPath: NSHomeDirectory() + "/Projects/ckcsys-mac")
let lex = Lex()
lex.loadTSV(root.appendingPathComponent("Resources/tables/cht_cimb_VISTA.tsv"))
lex.loadTSV(root.appendingPathComponent("Resources/tables/cht_zimb_VISTA.tsv"))
lex.loadUser(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/CKC縱橫/user_phrases.tsv"))
lex.buildPrefix()

var failed = 0
func check(_ name: String, _ got: String, contains: String) {
    let ok = got.contains(contains)
    print("\(ok ? "OK" : "FAIL") \(name) => \(got)")
    if !ok { failed += 1 }
}

// 06177: longer codes exist → no auto **; 選詞+1 picks 自己
print("lex exact[06177]=\(lex.exact["06177"] ?? []) longer=\(lex.hasLongerCode("06177"))")
let p06177 = stepPath(lex: lex, digits: [0, 6, 1, 7, 7])
check("06177 compose path stays .all", p06177, contains: "06177")
check("manual 選詞 +1", decide(lex: lex, buffer: "06177", look: .phrases, digit: 1, inactive: false, manualPhrasePick: true), contains: "PHRASE_PICK '自己'")
check("06177+1 without 選詞 extends", decide(lex: lex, buffer: "06177", look: .all, digit: 1, inactive: false, manualPhrasePick: false), contains: "061771")

// 366069
check("366069 path", stepPath(lex: lex, digits: [3, 6, 6, 0, 6, 9]), contains: "366069")
check("366069 first phrase", lex.phrases("366069").first ?? "", contains: "課程")

// 800620 / 分別
print("lex exact[8006]=\(lex.exact["8006"] ?? []) longer8006=\(lex.hasLongerCode("8006")) stock800620=\(lex.hasCode(withPrefix: "800620"))")
print("lex phrases(800620).first=\(lex.phrases("800620").first ?? "?")")
check("800620 path", stepPath(lex: lex, digits: [8, 0, 0, 6, 2, 0]), contains: "800620")
check("8006+2 must compose not 人名", decide(lex: lex, buffer: "8006", look: .all, digit: 2, inactive: false, manualPhrasePick: false), contains: "80062")
check("80062+0", decide(lex: lex, buffer: "80062", look: .all, digit: 0, inactive: false, manualPhrasePick: false), contains: "800620")

// 20338 + 0 / longer compose
check("20338+0", decide(lex: lex, buffer: "20338", look: .all, digit: 0, inactive: false, manualPhrasePick: false), contains: "203380")
check("20338+1 compose (longer exists)", decide(lex: lex, buffer: "20338", look: .all, digit: 1, inactive: false, manualPhrasePick: false), contains: "COMPOSE '203381")

// Dead-end auto (example: pick still works when no longer code)
if let dead = lex.prefixIndex["00259"]?.first(where: { $0 == "00259" }) {
    _ = dead
}
check("00259+1 dead-end", decide(lex: lex, buffer: "00259", look: .all, digit: 1, inactive: false, manualPhrasePick: false), contains: "AUTO_PHRASE_PICK")

if failed > 0 {
    fputs("FAILED \(failed) checks\n", stderr)
    exit(1)
}
print("ALL CHECKS PASSED")
