import Foundation
import AppKit

/// Loads CKC code→candidate mappings from original Windows TSV tables,
/// plus user-defined phrases under Application Support.
final class DictionaryStore {
    static let shared = DictionaryStore()

    /// code -> ordered unique candidates (chars and phrases)
    private(set) var exact: [String: [String]] = [:]
    /// prefix (1..codeLen) -> exact keys with that prefix (sorted). Built once at load.
    private var prefixIndex: [String: [String]] = [:]
    /// Cap prefix-expansion candidates so UI stays snappy on short codes.
    private let prefixResultCap = 120
    /// User phrases only (also merged into exact with priority).
    private(set) var userExact: [String: [String]] = [:]
    /// Character → primary full code (from zimb; non-简码, prefer 4-digit, last xh on ties).
    private(set) var charPrimaryCode: [String: String] = [:]
    private(set) var sourceDescription: String = "unloaded"
    /// Windows cht_punctuation.tsv order (xh sorted) — keypad "-" picker pages of 9.
    private(set) var punctuationList: [String] = []

    private(set) var systemEntryCount: Int = 0
    private(set) var userEntryCount: Int = 0

    private init() {}

    // MARK: - Paths

    var userPhrasesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CKC縱橫", isDirectory: true)
            .appendingPathComponent("user_phrases.tsv")
    }

    /// True when only the tiny built-in proof set is active (tables failed to load).
    var needsLexiconReload: Bool {
        sourceDescription.contains("hardcoded minimal") || systemEntryCount < 1000
    }

    // MARK: - Bundle / paths

    /// Resolve the IM app bundle even if Bundle.main is briefly wrong during install races.
    private func lexiconBundle() -> Bundle {
        let main = Bundle.main
        if let id = main.bundleIdentifier, id.contains("inputmethod.ckc") {
            return main
        }
        if main.bundleURL.path.hasSuffix("Ckcsys.app") || main.bundleURL.path.contains("CKC縱橫.app") {
            return main
        }
        let candidates = [
            NSHomeDirectory() + "/Library/Input Methods/Ckcsys.app",
            NSHomeDirectory() + "/Library/Input Methods/CKC縱橫.app"
        ]
        for path in candidates {
            if let b = Bundle(path: path) { return b }
        }
        return main
    }

    private func appendLog(_ line: String) {
        let path = "/tmp/ckc-ime.log"
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    // MARK: - Load

    func load() {
        exact.removeAll()
        prefixIndex.removeAll()
        userExact.removeAll()
        charPrimaryCode.removeAll()
        systemEntryCount = 0
        userEntryCount = 0
        sourceDescription = "unloaded"

        let bundle = lexiconBundle()
        var loaded = 0
        let resPath = bundle.resourceURL?.path ?? "nil"
        appendLog("Dictionary load begin bundle=\(bundle.bundlePath) resources=\(resPath)")

        if let tablesURL = bundle.resourceURL?.appendingPathComponent("tables", isDirectory: true) {
            if FileManager.default.fileExists(atPath: tablesURL.path) {
                loaded = loadWindowsTables(from: tablesURL)
                if loaded == 0 {
                    appendLog("Dictionary tables dir present but 0 rows from \(tablesURL.path)")
                }
            } else {
                appendLog("Dictionary tables missing at \(tablesURL.path)")
            }
        } else {
            appendLog("Dictionary resourceURL nil for bundle \(bundle.bundlePath)")
        }

        // Also try the installed IM path if Bundle.main pointed at a half-deleted tree.
        if loaded == 0 {
            let fallback = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Input Methods/Ckcsys.app/Contents/Resources/tables", isDirectory: true)
            if FileManager.default.fileExists(atPath: fallback.path) {
                loaded = loadWindowsTables(from: fallback)
                if loaded > 0 {
                    appendLog("Dictionary loaded via installed-path fallback \(fallback.path)")
                }
            }
        }

        if loaded == 0, let seedURL = bundle.url(forResource: "ckc_seed", withExtension: "txt") {
            loaded = loadPlainTextTable(seedURL, buildCharIndex: true)
            sourceDescription = "ckc_seed.txt fallback (\(loaded) entries)"
        }

        if loaded == 0 {
            addSystem("0307", "我")
            addSystem("289449", "縱橫")
            addSystem("0", "的")
            addSystem("0", "香港")
            addSystem("1", "要")
            addSystem("6", "是")
            addSystem("9", "小")
            charPrimaryCode["我"] = "0307"
            charPrimaryCode["縱"] = "2898"
            charPrimaryCode["橫"] = "4498"
            charPrimaryCode["的"] = "0760"
            charPrimaryCode["小"] = "9"
            loaded = 7
            sourceDescription = "hardcoded minimal proofs"
            appendLog("Dictionary FALLBACK hardcoded — tables/seed unavailable (install race or missing Resources/tables)")
        }

        systemEntryCount = loaded
        let userN = loadUserPhrases()
        userEntryCount = userN
        if sourceDescription.isEmpty || sourceDescription == "unloaded" {
            sourceDescription = "tables/ (\(systemEntryCount) system + \(userEntryCount) user)"
        } else if userN > 0 {
            sourceDescription += " + \(userN) user"
        }
        loadPunctuationTable()
        rebuildPrefixIndex()
        NSLog("[CKC] Dictionary loaded: %@ punct=%d", sourceDescription, punctuationList.count)
        appendLog(String(format: "Dictionary loaded punct=%d desc=%@", punctuationList.count, sourceDescription))
    }

    /// Build prefix → sorted exact keys once. Lookup avoids O(n) key scan per keystroke.
    private func rebuildPrefixIndex() {
        prefixIndex.removeAll(keepingCapacity: true)
        var buckets: [String: [String]] = [:]
        let allKeys = Set(exact.keys).union(userExact.keys)
        for key in allKeys {
            // Index every non-empty prefix of the key
            let chars = Array(key)
            for i in 1...chars.count {
                let p = String(chars[..<i])
                buckets[p, default: []].append(key)
            }
        }
        for (p, keys) in buckets {
            prefixIndex[p] = keys.sorted()
        }
    }

    /// Prefer known Windows exports: zimb (singles) before cimb (phrases).
    private func loadWindowsTables(from dir: URL) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.lastPathComponent.lowercased(), $0) })

        var total = 0
        let preferredOrder = [
            "cht_zimb_vista.tsv",
            "cht_cimb_vista.tsv",
            "cht_allzi_vista.tsv"
        ]
        var consumed = Set<String>()
        for name in preferredOrder {
            if let url = byName[name] {
                let isZimb = name.contains("zimb")
                total += loadPlainTextTable(url, buildCharIndex: isZimb || name.contains("allzi"))
                consumed.insert(name)
            }
        }
        // Any other .tsv/.txt/.cin
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent.lowercased()
            if name.hasPrefix(".") || name == "readme.txt" { continue }
            if consumed.contains(name) { continue }
            if name.hasSuffix(".cin") {
                total += loadCIN(url)
            } else if name.hasSuffix(".txt") || name.hasSuffix(".tsv") || name.hasSuffix(".table") || name.hasSuffix(".dic") {
                total += loadPlainTextTable(url, buildCharIndex: false)
            }
        }
        if total > 0 {
            sourceDescription = "tables/ (\(total) system entries; zimb+cimb Windows)"
        }
        return total
    }

    @discardableResult
    private func loadPlainTextTable(_ url: URL, buildCharIndex: Bool) -> Int {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("[CKC] Failed to read %@", url.path)
            return 0
        }
        var n = 0
        var isHeaderChecked = false
        var codeIdx = 0
        var wordIdx = 1
        // For char primary: track best (len4 preferred, then longer, then higher xh)
        var bestMeta: [String: (code: String, len: Int, xh: Int, jm: Bool)] = [:]

        for line in data.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") || s.hasPrefix("//") { continue }

            let cols: [String]
            if s.contains("\t") {
                cols = s.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            } else {
                cols = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            }
            guard cols.count >= 2 else { continue }

            if !isHeaderChecked {
                isHeaderChecked = true
                let lower = cols.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let si = lower.firstIndex(of: "srm"), let hi = lower.firstIndex(of: "hz") {
                    codeIdx = si
                    wordIdx = hi
                    continue // skip header
                }
                // No header — fall through and parse this line
            }

            guard codeIdx < cols.count, wordIdx < cols.count else { continue }
            let code = cols[codeIdx].trimmingCharacters(in: .whitespaces)
            let word = cols[wordIdx].trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty, !word.isEmpty, code.allSatisfy({ $0.isNumber }) else { continue }

            addSystem(code, word)
            n += 1

            if buildCharIndex, word.count == 1 {
                let jm: Bool
                if cols.count > 5 {
                    jm = cols[5].trimmingCharacters(in: .whitespaces) == "1"
                } else {
                    jm = code.count <= 2
                }
                let xh: Int
                if cols.count > 3, let v = Int(cols[3].trimmingCharacters(in: .whitespaces)) {
                    xh = v
                } else {
                    xh = n
                }
                let len = code.count
                if let cur = bestMeta[word] {
                    // Prefer non-简码; then length==4; then longer; then higher xh (→ 2898 for 縱)
                    let better: Bool
                    if cur.jm && !jm {
                        better = true
                    } else if cur.jm == jm {
                        if !jm && len == 4 && cur.len != 4 {
                            better = true
                        } else if !jm && cur.len == 4 && len != 4 {
                            better = false
                        } else if len > cur.len && cur.len != 4 {
                            better = true
                        } else if len == cur.len && xh >= cur.xh {
                            better = true
                        } else {
                            better = false
                        }
                    } else {
                        better = false
                    }
                    if better {
                        bestMeta[word] = (code, len, xh, jm)
                    }
                } else {
                    bestMeta[word] = (code, len, xh, jm)
                }
            }
        }

        if buildCharIndex {
            for (ch, meta) in bestMeta {
                // Only overwrite if we don't have a non-jm yet, or this is better
                if let existing = charPrimaryCode[ch] {
                    let existJm = existing.count <= 2
                    if existJm && !meta.jm {
                        charPrimaryCode[ch] = meta.code
                    } else if !existJm && !meta.jm && meta.len == 4 && existing.count != 4 {
                        charPrimaryCode[ch] = meta.code
                    } else if !existJm && !meta.jm && meta.len == existing.count {
                        // keep higher xh already chosen in bestMeta pass — replace
                        charPrimaryCode[ch] = meta.code
                    }
                } else {
                    charPrimaryCode[ch] = meta.code
                }
            }
            // Direct assign from bestMeta (authoritative for this file)
            for (ch, meta) in bestMeta {
                charPrimaryCode[ch] = meta.code
            }
        }

        NSLog("[CKC] Loaded %d rows from %@ (charIndex=%d)", n, url.lastPathComponent, buildCharIndex ? charPrimaryCode.count : -1)
        return n
    }

    @discardableResult
    private func loadCIN(_ url: URL) -> Int {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var inCharDef = false
        var n = 0
        for line in data.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            let lower = s.lowercased()
            if lower.hasPrefix("%chardef") {
                inCharDef = lower.contains("begin")
                continue
            }
            if !inCharDef { continue }
            let parts = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2 else { continue }
            let code = parts[0]
            let word = parts[1]
            guard code.allSatisfy({ $0.isNumber }) else { continue }
            addSystem(code, word)
            n += 1
        }
        NSLog("[CKC] Loaded %d .cin chardef rows from %@", n, url.lastPathComponent)
        return n
    }

    // MARK: - User phrases

    @discardableResult
    func loadUserPhrases() -> Int {
        let url = userPhrasesURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        userExact.removeAll()
        var n = 0
        for line in data.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            let parts = s.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let code = parts[0].trimmingCharacters(in: .whitespaces)
            let phrase = parts[1].trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty, !phrase.isEmpty, code.allSatisfy({ $0.isNumber }), code.count <= 6 else { continue }
            addUser(code, phrase)
            n += 1
        }
        NSLog("[CKC] Loaded %d user phrases from %@", n, url.path)
        return n
    }

    /// Append/update user phrase and persist. Returns nil on success, or error message.
    @discardableResult
    func addUserPhrase(code: String, phrase: String) -> String? {
        let code = code.trimmingCharacters(in: .whitespaces)
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return "詞語不能為空" }
        guard !code.isEmpty, code.allSatisfy({ $0.isNumber }), code.count <= 6 else {
            return "編碼須為 1–6 位數字"
        }
        addUser(code, phrase)
        if let err = persistUserPhrases() { return err }
        // Cheap incremental prefix index update for this code
        let chars = Array(code)
        for i in 1...chars.count {
            let p = String(chars[..<i])
            var keys = prefixIndex[p] ?? []
            if !keys.contains(code) {
                keys.append(code)
                keys.sort()
                prefixIndex[p] = keys
            }
        }
        userEntryCount = userExact.values.reduce(0) { $0 + $1.count }
        NSLog("[CKC] User phrase saved %@ → %@", code, phrase)
        return nil
    }

    private func persistUserPhrases() -> String? {
        let url = userPhrasesURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines: [String] = [
                "# CKC 縱橫 user phrases — code<TAB>phrase",
                "# Edit/remove lines here; restart input source or re-Add to reload.",
                "# Auto-coding: 1→full; 2→3+3; 3→2+2+2; 4→2+1+1+2; 5+→2+1+1+1+1 (max 6)."
            ]
            for code in userExact.keys.sorted() {
                for phrase in userExact[code] ?? [] {
                    lines.append("\(code)\t\(phrase)")
                }
            }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "無法寫入 \(url.path): \(error.localizedDescription)"
        }
    }

    func revealUserPhrasesInFinder() {
        let url = userPhrasesURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = persistUserPhrases()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Phrase auto-code (Windows CKC rules)

    /// Compute CKC code for a phrase from per-character primary codes.
    /// Rules: 1→full; 2→3+3; 3→2+2+2; 4→2+1+1+2; 5+→2+1+1+1+1; max 6 digits.
    /// Missing characters return nil and list them in `missing`.
    func computeCode(forPhrase phrase: String, missing: inout [String]) -> String? {
        missing.removeAll()
        let chars = phrase.map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !chars.isEmpty else { return nil }

        var primaries: [String] = []
        for ch in chars {
            if let c = charPrimaryCode[ch] {
                primaries.append(c)
            } else {
                missing.append(ch)
            }
        }
        if !missing.isEmpty { return nil }

        let n = primaries.count
        let slices: [Int]
        switch n {
        case 1: slices = [6]
        case 2: slices = [3, 3]
        case 3: slices = [2, 2, 2]
        case 4: slices = [2, 1, 1, 2]
        default: slices = [2, 1, 1, 1, 1] // first 5 chars
        }

        var out = ""
        let take = min(slices.count, primaries.count)
        for i in 0..<take {
            let code = primaries[i]
            let need = slices[i]
            let chunk = String(code.prefix(need)) // short codes: take all available, no zero-pad
            out += chunk
        }
        if out.count > 6 { out = String(out.prefix(6)) }
        return out.isEmpty ? nil : out
    }

    func computeCode(forPhrase phrase: String) -> String? {
        var missing: [String] = []
        return computeCode(forPhrase: phrase, missing: &missing)
    }

    // MARK: - Lookup

    enum CandidateKind {
        case all
        case characters  // 單字 — Windows "/"
        case phrases     // 詞組 — Windows "*"
    }

    /// True when some lexicon key is strictly longer than `code` and shares that prefix
    /// (i.e. typing another digit can still narrow toward a longer code).
    func hasLongerCode(for code: String) -> Bool {
        guard !code.isEmpty else { return true }
        guard let keys = prefixIndex[code] else { return false }
        return keys.contains { $0.count > code.count }
    }

    /// Candidates: user phrases first, then exact system, then prefix matches.
    func candidates(for code: String, kind: CandidateKind = .all) -> [String] {
        guard !code.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []

        func accept(_ word: String) -> Bool {
            switch kind {
            case .all: return true
            case .characters: return word.count == 1
            case .phrases: return word.count >= 2
            }
        }

        if let userHits = userExact[code] {
            for c in userHits where accept(c) && seen.insert(c).inserted { out.append(c) }
        }
        if let exactHits = exact[code] {
            for c in exactHits where accept(c) && seen.insert(c).inserted { out.append(c) }
        }
        // Prefix association via prebuilt index (skip exact key itself)
        if let keys = prefixIndex[code] {
            for key in keys where key != code {
                if out.count >= prefixResultCap { break }
                if let uh = userExact[key] {
                    for c in uh where accept(c) && seen.insert(c).inserted {
                        out.append(c)
                        if out.count >= prefixResultCap { break }
                    }
                }
                if out.count >= prefixResultCap { break }
                for c in exact[key] ?? [] where accept(c) && seen.insert(c).inserted {
                    out.append(c)
                    if out.count >= prefixResultCap { break }
                }
            }
        }
        return out
    }

    // MARK: - Internals

    private func addSystem(_ code: String, _ word: String) {
        var list = exact[code] ?? []
        if !list.contains(word) {
            list.append(word)
            exact[code] = list
        }
    }

    private func addUser(_ code: String, _ word: String) {
        var ulist = userExact[code] ?? []
        if !ulist.contains(word) {
            ulist.insert(word, at: 0)
            userExact[code] = ulist
        }
        // Also surface in exact for prefix enumeration, but candidates() already prefers userExact
        var list = exact[code] ?? []
        if let idx = list.firstIndex(of: word) {
            list.remove(at: idx)
        }
        list.insert(word, at: 0)
        exact[code] = list
    }

    /// Load Resources/tables/cht_punctuation.tsv (xh\thz), sorted by xh.
    func loadPunctuationTable() {
        punctuationList = []
        let bundle = lexiconBundle()
        var url = bundle.resourceURL?
            .appendingPathComponent("tables", isDirectory: true)
            .appendingPathComponent("cht_punctuation.tsv")
        if url == nil || !FileManager.default.fileExists(atPath: url!.path) {
            url = bundle.url(forResource: "cht_punctuation", withExtension: "tsv", subdirectory: "tables")
        }
        if url == nil || !FileManager.default.fileExists(atPath: url!.path) {
            let fb = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Input Methods/Ckcsys.app/Contents/Resources/tables/cht_punctuation.tsv")
            if FileManager.default.fileExists(atPath: fb.path) { url = fb }
        }
        guard let url = url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            punctuationList = ["，", "。", "、", "：", "；", "？", "「", "」", "！",
                               "…", "‘", "’", "（", "）", "〔", "〕", "｛", "｝",
                               "《", "》", "─", "‧", "“", "”", "『", "』", "〈", "〉", "【", "】"]
            NSLog("[CKC] punctuation fallback (%d)", punctuationList.count)
            return
        }
        var pairs: [(Int, String)] = []
        for (i, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            if i == 0 && s.lowercased().hasPrefix("xh") { continue }
            let cols = s.split(separator: "\t", maxSplits: 1).map(String.init)
            guard cols.count >= 2, let n = Int(cols[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let hz = cols[1].trimmingCharacters(in: .whitespaces)
            if !hz.isEmpty { pairs.append((n, hz)) }
        }
        pairs.sort { $0.0 < $1.0 }
        punctuationList = pairs.map { $0.1 }
        NSLog("[CKC] punctuation loaded %d from %@", punctuationList.count, url.lastPathComponent)
    }

    /// Wildcard "?" matches any single digit in code (Windows 萬能鍵 / Num Lock).
    func candidatesWildcard(for pattern: String, kind: CandidateKind = .all) -> [String] {
        if !pattern.contains("?") {
            return candidates(for: pattern, kind: kind)
        }
        let keys = Set(exact.keys).union(userExact.keys)
        var matched: [String] = []
        let pats = Array(pattern)
        for key in keys.sorted() {
            let ks = Array(key)
            if ks.count < pats.count { continue }
            var ok = true
            for i in 0..<pats.count {
                if pats[i] != "?" && pats[i] != ks[i] { ok = false; break }
            }
            if ok { matched.append(key) }
            if matched.count >= prefixResultCap { break }
        }
        var out: [String] = []
        var seen = Set<String>()
        for k in matched {
            let merged = (userExact[k] ?? []) + (exact[k] ?? [])
            let list: [String]
            switch kind {
            case .all: list = merged
            case .characters: list = merged.filter { $0.count == 1 }
            case .phrases: list = merged.filter { $0.count > 1 }
            }
            for c in list where seen.insert(c).inserted {
                out.append(c)
                if out.count >= prefixResultCap { return out }
            }
        }
        return out
    }

}
