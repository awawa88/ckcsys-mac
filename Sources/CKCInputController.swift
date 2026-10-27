import Cocoa
import InputMethodKit
import Carbon.HIToolbox

/// CKC / Ckcsys IMK controller.
/// Digit entry builds the composition code (max 6). Two-column CandidateWindow: chars | phrases.
/// T/* = 詞 then 1–9 pick; Y// = 字 then 1–9 pick; −/= page; Space commit.
/// After committing any single 字: show 聯想 phrases starting with that char; digit picks need 選詞 first
/// (選詞 also sets marked caret " **" like normal phrase mode).
/// Association commit inserts only the suffix after the seed (already in the document).
/// Auto 選詞/選字 (marked **/ *) at a dead-end (!hasLongerCode), OR exact-詞 with no 字
/// left even if stock longer keys exist (e.g. 06177 → 自己). Only a **user-added** longer
/// phrase under the buffer (hasLongerUserCode) overrides shorter auto-選詞 — require T/×
/// (e.g. user 58834 → at 5883 no auto). Stock longer keys alone do not block auto.
/// DigitSource flips only via Caps Lock / StatusConsole (never on digit keys).
/// Active DigitSource gates compose + candidate pick: numpad mode accepts only numpad digits;
/// number-row mode accepts only number-row digits. Inactive-row digits never flip mode and
/// always `return false` (unhandled) so they type as regular digits — idle, composing, or punct.
@objc(CKCInputController)
class CKCInputController: IMKInputController {
    private var buffer: String = ""
    private var charCandidates: [String] = []
    private var phraseCandidates: [String] = []
    private var lookKind: DictionaryStore.CandidateKind = .all  // .all = both columns
    private var selectedIndex: Int = 0
    private weak var currentClient: AnyObject?

    /// After committing a single 字: lexicon phrases that start with that character (聯想).
    /// Shown automatically; digit picks require 選詞 (T / ×) first — otherwise digits start a fresh code.
    private var associationSeed: String = ""
    private var associationPhrases: [String] = []
    private var associationPickEnabled: Bool = false

    /// Windows CKC: idle keypad "-" (標點符號鍵) opens 標點 picker; digits then commit.
    private var punctMode: Bool = false
    private var punctPageIndex: Int = 0
    /// Caps Lock often delivers two flagsChanged (press + release) with the same lock state.
    /// Track edges so DigitSource toggles once per real Caps Lock state change.
    private var lastCapsLockOn: Bool?
    /// Debounce Num Lock keyDown+flagsChanged double delivery → one "?".
    private var lastWildcardAppendAt: TimeInterval = 0
    /// Deferred StatusConsole hide lives on StatusConsole (shared) so one controller
    /// instance cannot fire a hide that another instance's activate already cancelled.

    /// Convert Traditional Chinese to Simplified using CFStringTransform (system ICU).
    /// Returns the input unchanged if conversion fails.
    private func convertToSimplified(_ traditional: String) -> String {
        let mutable = NSMutableString(string: traditional)
        if CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false) {
            return mutable as String
        }
        return traditional
    }

    /// Pages of 9 from cht_punctuation.tsv (Windows xh order).
    private var punctPages: [[String]] {
        let list = DictionaryStore.shared.punctuationList
        let src = list.isEmpty
            ? ["，", "。", "、", "：", "；", "？", "「", "」", "！"]
            : list
        var pages: [[String]] = []
        var i = 0
        while i < src.count {
            pages.append(Array(src[i..<min(i + 9, src.count)]))
            i += 9
        }
        return pages
    }

    private func cancelPendingConsoleHide() {
        StatusConsole.shared.cancelPendingHide()
    }

    private func scheduleDeferredConsoleHide(clientBundle: String) {
        StatusConsole.shared.scheduleDeferredHide(clientBundle: clientBundle)
    }

    /// Belt-and-suspenders: if activate was skipped/raced, first CKC key brings the strip back.
    private func ensureStatusConsoleVisible(near client: Any?) {
        cancelPendingConsoleHide()
        guard !StatusConsole.shared.isVisible else { return }
        let clientId = clientBundleId(client)
        StatusConsole.shared.show(near: client as AnyObject?)
        ckcLog("StatusConsole show (ensure-key) client=\(clientId)")
    }

    // MARK: - Init (vChewing / Shiki Suen pattern)
    // macOS sometimes constructs IMKInputController via bare init() without activateServer.
    // Keys stay dead until the user toggles IME. Both inits share construct → activateServer.

    /// Shared post-super.init work: async activateServer with the best available client.
    private func construct(client theClient: (IMKTextInput & NSObjectProtocol)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let maybeClient: Any? = theClient ?? self.client()
            let bundle = self.clientBundleId(maybeClient)
            self.ckcLog("construct → activateServer client=\(bundle)")
            self.activateServer(maybeClient)
        }
    }

    /// Bare init: macOS may allocate without server/delegate/client and skip activateServer.
    override init() {
        super.init()
        let bareClient = client() as (IMKTextInput & NSObjectProtocol)?
        let cid = clientBundleId(bareClient)
        ckcLog("init() bare client=\(cid)")
        construct(client: bareClient)
    }

    /// Designated IMK init — still run construct so activateServer is not skipped after restart.
    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        let theClient = inputClient as? (IMKTextInput & NSObjectProtocol)
        let cid = clientBundleId(theClient)
        ckcLog("init(server:delegate:client:) client=\(cid)")
        construct(client: theClient)
    }

    /// Mode / state tag can arrive on a controller that never got activateServer (bare init).
    /// Re-activate when we have no client yet or the strip is missing.
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        super.setValue(value, forTag: tag, client: sender)
        let clientId = clientBundleId(sender)
        ckcLog("setValue tag=\(tag) value=\(String(describing: value)) client=\(clientId)")
        if currentClient == nil || !StatusConsole.shared.isVisible {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.ckcLog("setValue → re-activateServer client=\(self.clientBundleId(sender))")
                self.activateServer(sender)
            }
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        currentClient = sender as AnyObject
        // Sync Caps Lock latch so the first flagsChanged does not spuriously toggle DigitSource.
        lastCapsLockOn = NSEvent.modifierFlags.contains(.capsLock)
        // Self-heal after install races: IM may have loaded while Resources/tables was mid-replace.
        if DictionaryStore.shared.needsLexiconReload {
            ckcLog("activateServer lexicon reload (was \(DictionaryStore.shared.sourceDescription))")
            DictionaryStore.shared.load()
        }
        cancelPendingConsoleHide()
        StatusConsole.shared.show(near: sender as AnyObject?)
        ckcLog("StatusConsole show (activate) client=\(clientBundleId(sender))")
        // Keep candidate headers / marked chrome in sync when 小鍵盤↔鍵盤 toggles.
        StatusConsole.shared.onDigitSourceChanged = { [weak self] source in
            guard let self else { return }
            CandidateWindow.shared.applyDigitModeLabels(digitSource: source)
            if self.punctMode {
                self.showPunctCandidates(client: self.currentClient)
            } else if !self.buffer.isEmpty {
                self.updateUI(client: self.currentClient)
            }
            self.ckcLog("digitSource changed → \(source.rawValue) headers=\(source.charColumnHeader)/\(source.phraseColumnHeader)")
        }
        // Log output mode changes
        StatusConsole.shared.onOutputModeChanged = { [weak self] mode in
            guard let self else { return }
            self.ckcLog("outputMode changed → \(mode.rawValue)")
        }
        // 光/錨: reposition candidate popup immediately when toggle changes while visible.
        StatusConsole.shared.onCandidateAnchorChanged = { [weak self] anchor in
            guard let self else { return }
            self.ckcLog("candidateAnchor → \(anchor.rawValue) follow-console=\(anchor == .console ? 1 : 0)")
            CandidateWindow.shared.repositionForCurrentAnchor()
        }
        // Wire mouse click callback to commit the clicked candidate
        CandidateWindow.shared.onCandidateClicked = { [weak self] text, column in
            guard let self else { return }
            self.ckcLog("clicked candidate '\(text)' column=\(column == .characters ? "char" : "phrase")")
            if self.punctMode {
                self.commitPunct(text, client: self.currentClient)
            } else {
                // Mouse is an explicit pick — allowed even before 選詞 in association mode.
                self.commit(text, client: self.currentClient)
            }
        }
        CandidateWindow.shared.applyDigitModeLabels(digitSource: StatusConsole.shared.digitSource)
        let clientId = clientBundleId(sender)
        if clientId == "com.apple.Notes" || clientId == "com.apple.MobileSMS" {
            ckcLog("ACTIVATE Notes/Messages client=\(clientId) — type digits with Ckcsys; if dead, remove+re-add Input Source")
        }
        ckcLog("activateServer client=\(clientId) dict=\(DictionaryStore.shared.sourceDescription) digitSource=\(StatusConsole.shared.digitSource.rawValue) outputMode=\(StatusConsole.shared.outputMode.rawValue) capsOn=\(lastCapsLockOn == true ? 1 : 0) buffer='\(buffer)' punct=\(punctMode ? 1 : 0)")
        // Notes/Messages churn activate/deactivate; restore marked text + panel if we still have state.
        if punctMode {
            showPunctCandidates(client: sender)
        } else if !buffer.isEmpty {
            updateUI(client: sender)
        } else if hasAssociation {
            showAssociationWindow(client: sender)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        // Do NOT clearComposition here — focus churn in Notes/iMessage would wipe digits
        // already consumed (return true), which looks like "nothing happens".
        let clientId = clientBundleId(sender)
        ckcLog("deactivateServer client=\(clientId) buffer='\(buffer)' punct=\(punctMode ? 1 : 0)")
        CandidateWindow.shared.hide()
        CandidateWindow.shared.onCandidateClicked = nil
        // Do not hide StatusConsole immediately — focus flicker would order it out
        // before the next activate can keep it visible (iMessage caret, Notes, Chrome).
        scheduleDeferredConsoleHide(clientBundle: clientId)
        super.deactivateServer(sender)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        return Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func menu() -> NSMenu! {
        let m = NSMenu(title: "Ckcsys")
        let add = NSMenuItem(
            title: "新增詞語… (Add Phrase)",
            action: #selector(addPhraseMenuAction(_:)),
            keyEquivalent: "="
        )
        add.keyEquivalentModifierMask = [.control]
        add.target = self
        m.addItem(add)

        let reveal = NSMenuItem(
            title: "編輯使用者詞庫…",
            action: #selector(revealUserPhrasesMenuAction(_:)),
            keyEquivalent: ""
        )
        reveal.target = self
        m.addItem(reveal)

        m.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(
            title: "切換碼元來源（小鍵盤／鍵盤）",
            action: #selector(toggleDigitSourceMenuAction(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        m.addItem(toggle)

        let reload = NSMenuItem(
            title: "重新載入詞庫",
            action: #selector(reloadDictionaryMenuAction(_:)),
            keyEquivalent: ""
        )
        reload.target = self
        m.addItem(reload)
        return m
    }

    @objc func addPhraseMenuAction(_ sender: Any?) {
        AddPhrasePanel.shared.show(presetCode: buffer.isEmpty ? nil : buffer)
    }

    @objc func revealUserPhrasesMenuAction(_ sender: Any?) {
        DictionaryStore.shared.revealUserPhrasesInFinder()
    }

    @objc func toggleDigitSourceMenuAction(_ sender: Any?) {
        StatusConsole.shared.toggleDigitSource()
    }

    @objc func reloadDictionaryMenuAction(_ sender: Any?) {
        DictionaryStore.shared.load()
        if !buffer.isEmpty {
            refreshCandidates()
            updateUI(client: currentClient)
        }
        NSLog("[CKC] dictionary reloaded: %@", DictionaryStore.shared.sourceDescription)
    }

    /// Short client id for Notes/Messages diagnose (IMKTextInput.bundleIdentifier).
    private func clientBundleId(_ client: Any?) -> String {
        let input = (client as? IMKTextInput) ?? (currentClient as? IMKTextInput)
        return input?.bundleIdentifier() ?? "?"
    }

    /// Append one line to /tmp/ckc-ime.log (unified log often redacts NSLog as <private>).
    private func ckcLog(_ message: String) {
        let line = message + "\n"
        let path = "/tmp/ckc-ime.log"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        NSLog("%@", "[CKC] " + message)
    }

    /// True for keypad Minus: Carbon 0x4E, or numericPad + ASCII/Unicode minus variants.
    private func isKeypadMinusEvent(keyCode: Int, characters: String, rawFlags: NSEvent.ModifierFlags) -> Bool {
        if keyCode == Int(kVK_ANSI_KeypadMinus) || keyCode == 0x4E { return true }
        guard rawFlags.contains(.numericPad) else { return false }
        for ch in characters {
            if ch == "-" || ch == "\u{2212}" || ch == "\u{FF0D}" || ch == "\u{FE63}" { return true }
        }
        return false
    }

    private func isKeypadPlusEvent(keyCode: Int, characters: String, rawFlags: NSEvent.ModifierFlags) -> Bool {
        if keyCode == Int(kVK_ANSI_KeypadPlus) || keyCode == 0x45 { return true }
        guard rawFlags.contains(.numericPad) else { return false }
        return characters.contains("+") || characters.contains("\u{FF0B}")
    }

    /// Mac Num Lock is usually KeypadClear (0x47). Some boards only send flagsChanged.
    private func isNumLockEvent(keyCode: Int, characters: String, rawFlags: NSEvent.ModifierFlags) -> Bool {
        if keyCode == Int(kVK_ANSI_KeypadClear) || keyCode == 0x47 { return true }
        // Rare: character "clear" / empty with numericPad on that keycode path already covered.
        _ = characters
        _ = rawFlags
        return false
    }

    /// Top number-row Minus (kVK_ANSI_Minus / 0x1B) — NOT keypad.
    /// Page-prev when composing / candidates; never the active special key.
    private func isNumberRowMinusEvent(keyCode: Int, characters: String, rawFlags: NSEvent.ModifierFlags) -> Bool {
        if keyCode == Int(kVK_ANSI_Minus) || keyCode == 0x1B { return true }
        // ASCII/Unicode minus without numericPad → treat as number-row
        if rawFlags.contains(.numericPad) { return false }
        for ch in characters {
            if ch == "-" || ch == "\u{2212}" || ch == "\u{FF0D}" { return true }
        }
        return false
    }

    /// Number-row Grave / backtick (kVK_ANSI_Grave / 0x32), left of 1.
    /// Unshifted "`" and Shift+"`" ("~") both count as the 鍵盤 special key.
    private func isNumberRowGraveEvent(keyCode: Int, characters: String, rawFlags: NSEvent.ModifierFlags) -> Bool {
        if keyCode == Int(kVK_ANSI_Grave) || keyCode == 0x32 { return true }
        if rawFlags.contains(.numericPad) { return false }
        for ch in characters {
            if ch == "`" || ch == "~" { return true }
        }
        return false
    }

    /// Active special key mirrors DigitSource:
    /// - .numpad → Num Lock (KeypadClear)
    /// - .numberRow → Grave / backtick (` / ~)
    /// Idle → 標點 only (no marked "?"); composing → 萬能鍵 "?"; punctMode → next 標點 page.
    private func isActiveSpecialKeyEvent(keyCode: Int, characters: String, rawFlags: NSEvent.ModifierFlags) -> Bool {
        switch StatusConsole.shared.digitSource {
        case .numpad:
            return isNumLockEvent(keyCode: keyCode, characters: characters, rawFlags: rawFlags)
        case .numberRow:
            return isNumberRowGraveEvent(keyCode: keyCode, characters: characters, rawFlags: rawFlags)
        }
    }

    private func specialKeyLabel() -> String {
        switch StatusConsole.shared.digitSource {
        case .numpad: return "NumLock"
        case .numberRow: return "Grave"
        }
    }

    /// Handle active special key:
    /// - punctMode → next 標點 page
    /// - already composing (digits/`?` in buffer) → append another "?" only (no 標點)
    /// - idle (empty buffer, first keystroke) → 標點 only (1st key cannot be wildcard)
    @discardableResult
    private func handleActiveSpecialKey(client: Any?) -> Bool {
        ensureStatusConsoleVisible(near: client)
        let via = specialKeyLabel()
        if punctMode {
            let pages = punctPages
            let pageCount = max(pages.count, 1)
            punctPageIndex = (punctPageIndex + 1) % pageCount
            showPunctCandidates(client: client)
            ckcLog("\(via) special → punct page \(punctPageIndex + 1)/\(pageCount) buffer=\(buffer)")
            return true
        }
        if !buffer.isEmpty {
            // Mid-compose: 萬能鍵 only — never reopen 標點.
            return appendWildcardMarked(client: client, via: via)
        }
        // Idle / first keystroke: 標點 only — no leading marked "?".
        enterPunctMode(client: client)
        ckcLog("\(via) special → punctMode ON (idle, no wildcard)")
        return true
    }

    /// Cmd/Ctrl/Opt/Shift block; leftover .numericPad/.function/.capsLock already stripped from `flags`.
    private func hasBlockingModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        return !flags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    /// Optional 萬能鍵 keys: "?" always; `/~ when NOT the active 鍵盤 special (see call site).
    /// Shift is REQUIRED for "?" / "~" on US keyboards — never treat Shift as blocking.
    /// Only Cmd/Ctrl/Opt block. Prefer keyCode fallbacks (Slash=0x2C, Grave=0x32).
    private func isWildcardKeyEvent(keyCode: Int, typed: String, charsIgnoring: String, flags: NSEvent.ModifierFlags) -> Bool {
        if !flags.intersection([.command, .control, .option]).isEmpty {
            return false
        }
        if typed == "?" || typed == "`" || typed == "~" { return true }
        if charsIgnoring == "?" || charsIgnoring == "`" || charsIgnoring == "~" { return true }
        let isSlash = (keyCode == Int(kVK_ANSI_Slash) || keyCode == 0x2C)
        let isGrave = (keyCode == Int(kVK_ANSI_Grave) || keyCode == 0x32)
        if isSlash && flags.contains(.shift) { return true }
        if isGrave { return true }
        return false
    }

    /// Append "?" into marked composition (same path as digits). Dismisses 標點 if open.
    /// First code unit cannot be wildcard — requires non-empty buffer.
    @discardableResult
    private func appendWildcardMarked(client: Any?, via: String = "wildcard") -> Bool {
        if buffer.isEmpty {
            // Idle: do not start compose with "?". Keep 標點 if open; else pass through.
            ckcLog("\(via) → wildcard blocked (1st key cannot be wildcard) punct=\(punctMode ? 1 : 0)")
            return punctMode
        }
        if punctMode {
            exitPunctMode()
            ckcLog("\(via) dismissed punct → compose")
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastWildcardAppendAt < 0.08 {
            ckcLog("\(via) → wildcard debounced buffer=\(buffer)")
            return true
        }
        if buffer.count >= 6 {
            ckcLog("\(via) → wildcard ignored at max buffer=\(buffer)")
            return true
        }
        lastWildcardAppendAt = now
        buffer.append("?")
        selectedIndex = 0
        lookKind = .all
        refreshCandidates()
        updateUI(client: client)
        ckcLog("\(via) → wildcard marked '\(buffer)' chars=\(charCandidates.count) phrases=\(phraseCandidates.count)")
        return true
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else { return false }
        currentClient = sender as AnyObject

        // Caps Lock toggles digit source; some keyboards deliver Num Lock only as flagsChanged.
        if event.type == .flagsChanged {
            let fk = Int(event.keyCode)
            ckcLog(String(format: "flagsChanged code=%d rawFlags=0x%lx punctMode=%d composing=%d",
                          fk, event.modifierFlags.rawValue, punctMode ? 1 : 0, buffer.isEmpty ? 0 : 1))
            if event.keyCode == UInt16(kVK_CapsLock) {
                let capsOn = event.modifierFlags.contains(.capsLock)
                if lastCapsLockOn == nil || lastCapsLockOn != capsOn {
                    lastCapsLockOn = capsOn
                    StatusConsole.shared.toggleDigitSource()
                    StatusConsole.shared.show(near: sender as AnyObject?)
                    ckcLog("CapsLock edge → digitSource=\(StatusConsole.shared.digitSource.rawValue) capsOn=\(capsOn ? 1 : 0)")
                } else {
                    ckcLog("CapsLock flagsChanged ignored (no state edge) capsOn=\(capsOn ? 1 : 0)")
                }
                return true
            }
            // Num Lock flagsChanged → active special only in 小鍵盤 mode
            if fk == Int(kVK_ANSI_KeypadClear) || fk == 0x47 {
                if StatusConsole.shared.digitSource == .numpad {
                    return handleActiveSpecialKey(client: sender)
                }
                ckcLog("NumLock flagsChanged ignored (digitSource=numberRow)")
                return true
            }
            return false
        }

        guard event.type == .keyDown else { return false }
        // If activate raced / was skipped, first keyDown brings StatusConsole back.
        ensureStatusConsoleVisible(near: sender)

        let keyCode = Int(event.keyCode)
        let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let rawFlags = event.modifierFlags
        // Numpad keys always carry .numericPad; Caps Lock is our digit-source toggle.
        // Strip those (and .function) so they do not block composition / picks.
        let flags = rawFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let lower = chars.lowercased()
        let composing = !buffer.isEmpty
        let hasCandidates = !charCandidates.isEmpty || !phraseCandidates.isEmpty
        let blocked = hasBlockingModifiers(flags)

        let typedForTrace = event.characters ?? ""
        // Trace keypad / Num Lock / number-row minus / wildcard keys for debugging.
        if keyCode == 0x4E || keyCode == 0x45 || keyCode == 0x41 || keyCode == 0x47
            || keyCode == 0x1B || keyCode == Int(kVK_ANSI_Minus)
            || keyCode == 0x2C || keyCode == Int(kVK_ANSI_Slash)
            || keyCode == 0x32 || keyCode == Int(kVK_ANSI_Grave)
            || rawFlags.contains(.numericPad)
            || chars == "-" || chars == "+" || chars.contains("−")
            || typedForTrace == "?" || typedForTrace == "`" || typedForTrace == "~"
            || chars == "?" || chars == "`" || chars == "~" {
            ckcLog(String(format: "keyDown code=%d chars=%@ typed=%@ rawFlags=0x%lx flags=0x%lx composing=%d punctMode=%d shift=%d",
                          keyCode, chars as NSString, typedForTrace as NSString,
                          rawFlags.rawValue, flags.rawValue,
                          composing ? 1 : 0, punctMode ? 1 : 0,
                          rawFlags.contains(.shift) ? 1 : 0))
        }

        // Ctrl+= → Add Phrase
        if flags.contains(.control) && !flags.contains(.option) && !flags.contains(.command) {
            if chars == "=" || chars == "+" || keyCode == kVK_ANSI_Equal {
                AddPhrasePanel.shared.show(presetCode: buffer.isEmpty ? nil : buffer)
                return true
            }
        }

        let typedChars = event.characters ?? ""

        // 萬能鍵 BEFORE 字-end / punct: "?" and `/~ ONLY append when already composing.
        // 1st key cannot be wildcard (appendWildcardMarked no-ops / passes through if buffer empty).
        // Use rawFlags for Shift — never let Shift block 萬能鍵 (Shift+/ = "?")
        let wildFlags = flags.union(rawFlags.intersection([.shift]))
        // In 鍵盤 mode Grave/`/~ is the active special key — do not steal it as bare wildcard.
        let graveIsSpecial = StatusConsole.shared.digitSource == .numberRow
            && isNumberRowGraveEvent(keyCode: keyCode, characters: chars, rawFlags: rawFlags)
        if !graveIsSpecial
            && isWildcardKeyEvent(keyCode: keyCode, typed: typedChars, charsIgnoring: chars, flags: wildFlags) {
            ckcLog(String(format: "wildcard HIT code=%d typed=%@ chars=%@ shift=%d punct=%d buf=%@",
                          keyCode, typedChars as NSString, chars as NSString,
                          wildFlags.contains(.shift) ? 1 : 0, punctMode ? 1 : 0, buffer as NSString))
            return appendWildcardMarked(client: sender, via: "wildcard")
        }

        // End keys: T / * = phrases; Y / bare / = characters (when composing).
        // Shift+/ is 萬能鍵 (handled above), not 字-end.
        let isPhraseEndKey =
            (lower == "t" && flags.isEmpty) ||
            keyCode == kVK_ANSI_KeypadMultiply ||
            chars == "*" || typedChars == "*"
        let isBareSlash =
            !flags.contains(.shift)
            && typedChars != "?"
            && (typedChars == "/" || chars == "/" || keyCode == Int(kVK_ANSI_Slash))
        let isCharEnd =
            (composing && lower == "y" && flags.isEmpty) ||
            keyCode == kVK_ANSI_KeypadDivide ||
            isBareSlash

        // Association 選詞: idle after 字 commit — T / × arms digit picks (does not steal digits before this).
        // Mirror normal phrase-mode caret mark: empty buffer + " **" via updateMarked.
        if !composing && !punctMode && hasAssociation && isPhraseEndKey && !blocked {
            associationPickEnabled = true
            lookKind = .phrases
            phraseCandidates = associationPhrases
            charCandidates = []
            selectedIndex = 0
            showAssociationWindow(client: sender)
            updateMarked(client: sender)
            ckcLog("association 選詞 armed seed='\(associationSeed)' phrases=\(associationPhrases.count) marked=' **'")
            return true
        }

        if composing && isPhraseEndKey {
            // T / keypad * → 詞 column only
            lookKind = .phrases
            selectedIndex = 0
            refreshCandidates()
            updateUI(client: sender)
            return true
        }
        if composing && isCharEnd {
            // Y / keypad / / bare / → 字 column only
            lookKind = .characters
            selectedIndex = 0
            refreshCandidates()
            updateUI(client: sender)
            return true
        }

        // Esc → clear 標點, composition, or association guesses
        if keyCode == kVK_Escape {
            if punctMode || composing {
                clearComposition(client: sender)
                return true
            }
            if hasAssociation {
                clearAssociation()
                return true
            }
            return false
        }

        // F11 / F12 → direct ，。 (Windows CKC)
        if keyCode == kVK_F11 {
            commitPunct("，", client: sender)
            return true
        }
        if keyCode == kVK_F12 {
            commitPunct("。", client: sender)
            return true
        }

        // Active special key (DigitSource gate):
        // 小鍵盤 → Num Lock; 鍵盤 → Grave / backtick (` / ~).
        // Idle (first key) → 標點 only (no "?"); composing → 萬能鍵 "?"; punctMode → next page.
        // Number-row Minus is NOT special — page-prev when candidates visible.
        if isActiveSpecialKeyEvent(keyCode: keyCode, characters: chars, rawFlags: rawFlags) {
            ckcLog(String(format: "specialKey src=%@ code=%d composing=%d punctMode=%d",
                          StatusConsole.shared.digitSource.rawValue as NSString,
                          keyCode, composing ? 1 : 0, punctMode ? 1 : 0))
            return handleActiveSpecialKey(client: sender)
        }

        // Punct mode: 1–9 pick; Num Lock / keypad -/+ / number-row -/= page; Decimal exits
        if punctMode {
            let pages = punctPages
            let pageCount = max(pages.count, 1)
            // Number-row Minus or keypad Minus → next page while punct open
            if isNumberRowMinusEvent(keyCode: keyCode, characters: chars, rawFlags: rawFlags)
                || isKeypadMinusEvent(keyCode: keyCode, characters: chars, rawFlags: rawFlags) {
                punctPageIndex = (punctPageIndex + 1) % pageCount
                showPunctCandidates(client: sender)
                return true
            }
            if isKeypadPlusEvent(keyCode: keyCode, characters: chars, rawFlags: rawFlags)
                || chars == "=" || keyCode == Int(kVK_ANSI_Equal) {
                punctPageIndex = (punctPageIndex - 1 + pageCount) % pageCount
                showPunctCandidates(client: sender)
                return true
            }
            if keyCode == Int(kVK_ANSI_KeypadDecimal) || keyCode == 0x41 {
                // Dismiss 標點; idle punct has empty buffer so nothing to restore.
                exitPunctMode()
                if !buffer.isEmpty {
                    refreshCandidates()
                    updateUI(client: sender)
                }
                return true
            }
            if let digitInfo = classifyDigit(keyCode: keyCode, characters: chars, rawFlags: rawFlags), !blocked {
                // Active DigitSource only — inactive row must not pick 標點 or flip mode.
                if digitInfo.source != StatusConsole.shared.digitSource {
                    // Always pass through: inactive digits must type 0–9 into the app, never pick 標點.
                    ckcLog("digit \(digitInfo.value) IGNORE inactive (passthrough/punct) src=\(digitInfo.source.rawValue) active=\(StatusConsole.shared.digitSource.rawValue)")
                    return false
                }
                // Pure punct mode: 1–9 (and 0) choose the mark — never wildcard-continue.
                let d = digitInfo.value
                let page = pages[max(0, min(punctPageIndex, pages.count - 1))]
                let idx: Int
                if (1...9).contains(d) { idx = d - 1 }
                else if d == 0 { idx = min(8, max(page.count - 1, 0)) }
                else { return true }
                if idx < page.count { commitPunct(page[idx], client: sender) }
                return true
            }
            if keyCode == kVK_Space || keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
                if let pick = CandidateWindow.shared.selectedCandidate {
                    commitPunct(pick, client: sender)
                    return true
                }
                exitPunctMode()
                return true
            }
            if keyCode == kVK_UpArrow {
                selectedIndex = CandidateWindow.shared.moveSelection(-1)
                return true
            }
            if keyCode == kVK_DownArrow {
                selectedIndex = CandidateWindow.shared.moveSelection(1)
                return true
            }
            if flags.isEmpty, lower.count == 1, let ch = lower.first, ch.isLetter {
                exitPunctMode()
                return false
            }
            exitPunctMode()
        }

        // Keypad Decimal = 輸入碼刪除鍵 (delete last code digit). Not 。
        if keyCode == kVK_ANSI_KeypadDecimal && flags.isEmpty {
            if composing {
                if lookKind != .all {
                    lookKind = .all
                    refreshCandidates()
                    updateUI(client: sender)
                    return true
                }
                buffer.removeLast()
                selectedIndex = 0
                refreshCandidates()
                updateUI(client: sender)
                return true
            }
            return false
        }

        // Navigation when candidates visible
        if hasCandidates {
            if keyCode == kVK_UpArrow {
                selectedIndex = CandidateWindow.shared.moveSelection(-1)
                updateUI(client: sender)
                return true
            }
            if keyCode == kVK_DownArrow {
                selectedIndex = CandidateWindow.shared.moveSelection(1)
                updateUI(client: sender)
                return true
            }
            if keyCode == kVK_LeftArrow || keyCode == kVK_RightArrow {
                _ = CandidateWindow.shared.switchColumn()
                selectedIndex = CandidateWindow.shared.globalSelectedIndex
                updateUI(client: sender)
                return true
            }
            if keyCode == kVK_Tab {
                _ = CandidateWindow.shared.switchColumn()
                selectedIndex = CandidateWindow.shared.globalSelectedIndex
                updateUI(client: sender)
                return true
            }

            // Page-prev: keypad Minus, number-row Minus (both modes), PageUp
            if isNumberRowMinusEvent(keyCode: keyCode, characters: chars, rawFlags: rawFlags)
                || keyCode == Int(kVK_PageUp)
                || isKeypadMinusEvent(keyCode: keyCode, characters: chars, rawFlags: rawFlags) {
                selectedIndex = CandidateWindow.shared.prevPage()
                updateUI(client: sender)
                return true
            }
            if chars == "=" || chars == "+" || keyCode == Int(kVK_ANSI_Equal) ||
                isKeypadPlusEvent(keyCode: keyCode, characters: chars, rawFlags: rawFlags)
                || keyCode == Int(kVK_PageDown) {
                selectedIndex = CandidateWindow.shared.nextPage()
                updateUI(client: sender)
                return true
            }
            if chars == "," || chars == "[" || keyCode == kVK_ANSI_Comma || keyCode == kVK_ANSI_LeftBracket {
                selectedIndex = CandidateWindow.shared.prevPage()
                updateUI(client: sender)
                return true
            }
            if chars == "." || chars == "]" || keyCode == kVK_ANSI_Period || keyCode == kVK_ANSI_RightBracket {
                selectedIndex = CandidateWindow.shared.nextPage()
                updateUI(client: sender)
                return true
            }
        }

        // Space / Return → commit highlighted (association: only after 選詞)
        if keyCode == kVK_Space || keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            if hasAssociation && !composing {
                if associationPickEnabled {
                    if let pick = CandidateWindow.shared.selectedCandidate
                        ?? phraseCandidates.first {
                        commit(pick, client: sender)
                        return true
                    }
                    return true
                }
                // Without 選詞, Space/Return are normal — dismiss guesses, do not force a phrase.
                clearAssociation()
                return false
            }
            if let pick = CandidateWindow.shared.selectedCandidate
                ?? charCandidates.first
                ?? phraseCandidates.first {
                commit(pick, client: sender)
                return true
            }
            if composing {
                clearComposition(client: sender)
                return true
            }
            return false
        }

        // Backspace
        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            if composing {
                // If filtered, first Backspace restores both columns
                if lookKind != .all {
                    lookKind = .all
                    refreshCandidates()
                    updateUI(client: sender)
                    return true
                }
                buffer.removeLast()
                selectedIndex = 0
                refreshCandidates()
                updateUI(client: sender)
                return true
            }
            if hasAssociation {
                clearAssociation()
                return true
            }
            return false
        }

        // Digits: after Y// → pick 字; after T/* → pick 詞;
        // at 6 digits → 1–9 pick 詞 directly (no T/* needed);
        // at any length, if no longer lexicon codes remain → auto 選詞 + digit pick;
        // else compose — but only from the active DigitSource.
        if let digitInfo = classifyDigit(keyCode: keyCode, characters: chars, rawFlags: rawFlags) {
            let digit = digitInfo.value
            let pickModifiers = flags.contains(.option) || flags.contains(.control)
            let atMaxCode = buffer.count >= 6

            // Mode gate: only the active physical row feeds compose / candidate pick.
            // Never auto-switch DigitSource (sticky since 0.2.14/0.2.15).
            // Inactive-source digits always pass through (return false / unhandled) so they
            // insert as regular 0–9 — including while composing or in 標點. Never append to
            // the CKC buffer and never flip DigitSource.
            if digitInfo.source != StatusConsole.shared.digitSource {
                ckcLog("digit \(digit) IGNORE inactive (passthrough) src=\(digitInfo.source.rawValue) active=\(StatusConsole.shared.digitSource.rawValue) composing=\(composing ? 1 : 0) punct=\(punctMode ? 1 : 0)")
                return false
            }

            // Association after 字 commit: digits pick ONLY when 選詞 armed; else start a fresh code.
            if hasAssociation && buffer.isEmpty && !punctMode && flags.isEmpty {
                if associationPickEnabled && digit >= 1 && digit <= 9 {
                    syncAssociationWindow(near: sender)
                    if let text = CandidateWindow.shared.selectPhraseOnPage(digit) {
                        ckcLog("association pick digit=\(digit) → '\(text)' seed='\(associationSeed)'")
                        commit(text, client: sender)
                        return true
                    }
                    return true
                }
                ckcLog("association dismiss → fresh compose digit=\(digit) seed='\(associationSeed)' armed=\(associationPickEnabled ? 1 : 0)")
                clearAssociation()
                // fall through: digit starts a new CKC code
            }

            if digit >= 1 && digit <= 9 && hasCandidates && flags.isEmpty {
                // Full 6-digit code: 1–9 commits phrase (Windows-style; no T/* required)
                if atMaxCode && !phraseCandidates.isEmpty && lookKind != .characters {
                    lookKind = .phrases
                    syncCandidateWindow(near: sender)
                    if let text = CandidateWindow.shared.selectPhraseOnPage(digit) {
                        commit(text, client: sender)
                        return true
                    }
                    return true
                }
                // If this digit continues a longer lexicon/user code (e.g. 5883+4 → 58834
                // 輸入法), leave 選詞/選字 and compose — do not treat it as candidate pick.
                let extended = buffer + String(digit)
                let digitExtendsCode = !buffer.isEmpty
                    && DictionaryStore.shared.hasCode(withPrefix: extended)
                // Phrase filter (T / * / auto-選詞): 1–9 commits phrase — never only toggle **
                if lookKind == .phrases {
                    if digitExtendsCode {
                        ckcLog("phrase-mode digit=\(digit) extends '\(extended)' → compose")
                        lookKind = .all
                        // fall through to compose below
                    } else {
                        syncCandidateWindow(near: sender)
                        if let text = CandidateWindow.shared.selectPhraseOnPage(digit) {
                            commit(text, client: sender)
                            return true
                        }
                        return true
                    }
                } else if lookKind == .characters {
                    // Char filter (Y / / / auto-選字): 1–9 commits character
                    if digitExtendsCode {
                        ckcLog("char-mode digit=\(digit) extends '\(extended)' → compose")
                        lookKind = .all
                        // fall through to compose below
                    } else {
                        syncCandidateWindow(near: sender)
                        if let text = CandidateWindow.shared.selectCharOnPage(digit) {
                            commit(text, client: sender)
                            return true
                        }
                        return true
                    }
                }
                // At 6 digits with only chars (no phrases): allow char pick
                if lookKind == .all && atMaxCode && !charCandidates.isEmpty && phraseCandidates.isEmpty {
                    syncCandidateWindow(near: sender)
                    if let text = CandidateWindow.shared.selectCharOnPage(digit) {
                        commit(text, client: sender)
                        return true
                    }
                    return true
                }
            }

            // Option/Ctrl+1–9 always picks left column (even in .all / while composing)
            if pickModifiers && digit >= 1 && digit <= 9 && hasCandidates {
                if let text = CandidateWindow.shared.selectCharOnPage(digit) {
                    commit(text, client: sender)
                    return true
                }
                return true
            }

            // Composition digit from the active DigitSource only (gated above); never a 7th digit.
            // DigitSource stays sticky: inactive-row digits never reach here. Caps Lock /
            // StatusConsole toggle remain the only intentional switches (標點 + ÷/× vs Y/T).
            if flags.isEmpty {
                if punctMode {
                    exitPunctMode()
                    ckcLog("digit compose dismissed punct buffer=\(buffer)")
                }
                if atMaxCode {
                    // Already 6 digits: treat 1–9 as phrase pick if possible (any source already handled above)
                    ckcLog("digit \(digit) atMaxCode swallowed source=\(digitInfo.source.rawValue)")
                    return true
                }
                // Auto-select gate: dead-end, or exact-詞/no-字 (06177). Only user-added
                // longer phrases under the buffer override shorter auto-選詞.
                // Same keystroke must enter mode AND pick — never leave user with only **.
                // Refresh both columns so the gate sees 字/詞 counts correctly.
                lookKind = .all
                refreshCandidates()
                if shouldAutoSelectMode() {
                    let extended = buffer + String(digit)
                    if DictionaryStore.shared.hasCode(withPrefix: extended) {
                        // e.g. buffer 5883 + digit 4 → 58834 exists; keep composing
                        ckcLog("auto-select skipped; digit extends '\(extended)' exactPhrase=\(DictionaryStore.shared.hasExactPhrase(for: buffer) ? 1 : 0) longer=\(DictionaryStore.shared.hasLongerCode(for: buffer) ? 1 : 0) userLonger=\(DictionaryStore.shared.hasLongerUserCode(for: buffer) ? 1 : 0)")
                        // fall through to append
                    } else {
                        ckcLog("auto-phrase-no-extension buffer=\(buffer) digit=\(digit) exactPhrase=\(DictionaryStore.shared.hasExactPhrase(for: buffer) ? 1 : 0) longer=\(DictionaryStore.shared.hasLongerCode(for: buffer) ? 1 : 0) userLonger=\(DictionaryStore.shared.hasLongerUserCode(for: buffer) ? 1 : 0)")
                        enterAutoSelectMode()
                        syncCandidateWindow(near: sender)
                        updateMarked(client: sender)
                        if digit >= 1 && digit <= 9 {
                            if lookKind == .phrases {
                                if let text = CandidateWindow.shared.selectPhraseOnPage(digit) {
                                    commit(text, client: sender)
                                    return true
                                }
                            } else if lookKind == .characters {
                                if let text = CandidateWindow.shared.selectCharOnPage(digit) {
                                    commit(text, client: sender)
                                    return true
                                }
                            }
                        }
                        // digit 0 or out-of-range: stay in select mode (marked * / **)
                        ensureStatusConsoleVisible(near: sender)
                        updateUI(client: sender)
                        return true
                    }
                }
                if lookKind != .all {
                    lookKind = .all
                }
                buffer.append(Character(String(digit)))
                selectedIndex = 0
                lookKind = .all
                refreshCandidates()
                // Auto-enter 選詞/選字 when gate matches (dead-end or exact-詞/no-字).
                // User-longer under the prefix still needs explicit 選詞 (T/×).
                if shouldAutoSelectMode() {
                    enterAutoSelectMode()
                    ckcLog("auto-select-enter buffer=\(buffer) mode=\(lookKind == .phrases ? "phrases" : "characters") chars=\(charCandidates.count) phrases=\(phraseCandidates.count) exactPhrase=\(DictionaryStore.shared.hasExactPhrase(for: buffer) ? 1 : 0) longer=\(DictionaryStore.shared.hasLongerCode(for: buffer) ? 1 : 0) userLonger=\(DictionaryStore.shared.hasLongerUserCode(for: buffer) ? 1 : 0)")
                } else if buffer.count >= 6 && !phraseCandidates.isEmpty {
                    // Full 6-digit with phrases: focus 詞 (Windows-style)
                    lookKind = .phrases
                    CandidateWindow.shared.focusColumn(.phrases)
                }
                ensureStatusConsoleVisible(near: sender)
                let clientId = clientBundleId(sender)
                ckcLog("digit compose '\(buffer)' src=\(digitInfo.source.rawValue) active=\(StatusConsole.shared.digitSource.rawValue) client=\(clientId) chars=\(charCandidates.count) phrases=\(phraseCandidates.count) look=\(String(describing: lookKind))")
                updateUI(client: sender)
                return true
            }

            // Modifiers block compose → pass through (Shift etc.). Source mismatch already gated above.
            ckcLog("digit \(digit) REJECTED (modifiers) src=\(digitInfo.source.rawValue) active=\(StatusConsole.shared.digitSource.rawValue) flags=0x\(String(flags.rawValue, radix: 16))")
            return false
        }

        if composing {
            // Letters pass through as English so the left keyboard stays free.
            // T/Y already handled above as 詞/字 end keys; do not swallow A–Z/QWE etc.
            if flags.isEmpty, lower.count == 1, let ch = lower.first, ch.isLetter {
                return false
            }
            // Swallow other unused keys while composing (keep buffer)
            return true
        }
        return false
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        // Combined for IMK fallback; UI uses two columns
        return charCandidates + phraseCandidates
    }

    // MARK: - Internals


    /// Whether the current buffer should lock into 選詞/選字 without T/Y.
    /// - Dead-end (!hasLongerCode): any candidates → auto.
    /// - Exact 詞 with zero 字 left (e.g. 06177 → 自己) even if stock longer keys
    ///   like 061771 exist — digits then pick / compose-over-pick via hasCode(withPrefix:).
    /// - User-added longer phrase under the buffer (hasLongerUserCode) overrides:
    ///   at 5883 with user 58834→輸入法, no auto shortlist; need T/× for 中等/責令.
    private func shouldAutoSelectMode() -> Bool {
        guard !buffer.isEmpty, !buffer.contains("?") else { return false }
        // User longer phrase under this prefix → keep composing; shorter exact 詞 need T/×.
        if DictionaryStore.shared.hasLongerUserCode(for: buffer) {
            return false
        }
        // Dead-end: no longer keys at all → auto if any candidates.
        if !DictionaryStore.shared.hasLongerCode(for: buffer) {
            return !phraseCandidates.isEmpty || !charCandidates.isEmpty
        }
        // Stock longer keys only: restore exact-詞 auto (06177 → 自己).
        return DictionaryStore.shared.hasExactPhrase(for: buffer)
            && charCandidates.isEmpty
            && !phraseCandidates.isEmpty
    }

    /// Prefer 選詞 when phrases exist; else 選字. Assumes candidates already refreshed (.all).
    private func enterAutoSelectMode() {
        if !phraseCandidates.isEmpty {
            lookKind = .phrases
        } else if !charCandidates.isEmpty {
            lookKind = .characters
        } else {
            lookKind = .phrases
        }
        selectedIndex = 0
        refreshCandidates()
    }

    /// Push controller candidate lists into CandidateWindow synchronously (updateUI defers show).
    private func syncCandidateWindow(near client: Any?) {
        let mode: CandidateDisplayMode
        let focus: CandidateColumn
        switch lookKind {
        case .characters:
            mode = .characters; focus = .characters
        case .phrases:
            mode = .phrases; focus = .phrases
        case .all:
            mode = .both; focus = .characters
        }
        CandidateWindow.shared.show(
            composition: buffer,
            chars: charCandidates,
            phrases: phraseCandidates,
            mode: mode,
            focus: lookKind == .all ? nil : focus,
            digitSource: StatusConsole.shared.digitSource,
            near: (client as AnyObject?) ?? currentClient
        )
    }

    private func refreshCandidates() {
        let useWild = buffer.contains("?")
        func lookup(_ kind: DictionaryStore.CandidateKind) -> [String] {
            useWild
                ? DictionaryStore.shared.candidatesWildcard(for: buffer, kind: kind)
                : DictionaryStore.shared.candidates(for: buffer, kind: kind)
        }
        switch lookKind {
        case .all:
            charCandidates = lookup(.characters)
            phraseCandidates = lookup(.phrases)
        case .characters:
            charCandidates = lookup(.characters)
            phraseCandidates = []
        case .phrases:
            charCandidates = []
            phraseCandidates = lookup(.phrases)
        }
        if selectedIndex >= max(charCandidates.count, phraseCandidates.count) {
            selectedIndex = 0
        }
    }

    private func updateUI(client: Any?) {
        let clientObj = (client as AnyObject?) ?? currentClient
        updateMarked(client: clientObj)
        // Defer candidate positioning to next run loop after setMarkedText.
        // Chrome/Docs returns invalid (near 0,0) lineHeightRectangle when queried
        // immediately after setMarkedText; client needs layout cycle to update.
        // Fix from Rime Squirrel PR #1126 (merged): https://github.com/rime/squirrel/pull/1126
        DispatchQueue.main.async { [weak self] in
            self?.updateCandidateWindow(client: clientObj)
        }
    }

    private func updateMarked(client: Any?) {
        guard let client = (client as? IMKTextInput) ?? (currentClient as? IMKTextInput) else { return }
        var display = buffer
        // Marked chrome stays Chinese-only; ÷/× or Y/T live on candidate column headers.
        switch lookKind {
        case .phrases: display += " **"
        case .characters: display += " *"
        case .all: break
        }
        let attr = NSAttributedString(string: display)
        client.setMarkedText(
            attr,
            selectionRange: NSRange(location: display.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func updateCandidateWindow(client: Any?) {
        if buffer.isEmpty {
            if hasAssociation {
                showAssociationWindow(client: client)
            } else {
                CandidateWindow.shared.hide()
            }
            return
        }
        let mode: CandidateDisplayMode
        let focus: CandidateColumn?
        switch lookKind {
        case .all:
            mode = .both
            focus = nil
        case .characters:
            mode = .characters
            focus = .characters
        case .phrases:
            mode = .phrases
            focus = .phrases
        }
        CandidateWindow.shared.show(
            composition: buffer,
            chars: charCandidates,
            phrases: phraseCandidates,
            mode: mode,
            focus: focus,
            digitSource: StatusConsole.shared.digitSource,
            near: (client as AnyObject?) ?? currentClient
        )
        selectedIndex = CandidateWindow.shared.globalSelectedIndex
    }

    private func commit(_ text: String, client: Any?) {
        guard let client = (client as? IMKTextInput) ?? (currentClient as? IMKTextInput) else { return }

        // Association pick: seed 字 is already in the document — insert only the suffix
        // (習慣 → 慣 when seed is 習). Candidates still list full phrases for readability.
        let fromAssociation = !associationSeed.isEmpty
        let insertSource: String
        if fromAssociation {
            insertSource = associationSuffixToInsert(phrase: text)
            ckcLog("association commit phrase='\(text)' seed='\(associationSeed)' suffix='\(insertSource)'")
        } else {
            insertSource = text
        }

        // Convert to Simplified if output mode is simplified; candidates always show Traditional.
        // Strip used Traditional seed/phrase first; convert only the remaining suffix.
        let outputText: String
        if insertSource.isEmpty {
            outputText = ""
        } else if StatusConsole.shared.outputMode == .simplified {
            outputText = convertToSimplified(insertSource)
        } else {
            outputText = insertSource
        }

        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        if !outputText.isEmpty {
            client.insertText(outputText, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        buffer = ""
        charCandidates = []
        phraseCandidates = []
        lookKind = .all
        selectedIndex = 0
        // Lexicon association uses Traditional form (same as candidate lists).
        let traditional = text
        clearAssociation(hideWindow: false)
        CandidateWindow.shared.hide()
        NSLog("[CKC] committed %@ (outputMode=%@ assoc=%d)", outputText, StatusConsole.shared.outputMode.rawValue, fromAssociation ? 1 : 0)
        // Any single 字 → show common phrases starting with that character (習 is just an example).
        // Do not re-associate on an association suffix commit (even if suffix is one 字).
        if !fromAssociation && traditional.count == 1 {
            beginAssociation(for: traditional, client: client)
        }
    }

    /// Suffix after the association seed for document insert.
    /// Seed is stored in the same Traditional lexicon form used for phrase lookup; strip that
    /// form from the phrase. If Traditional prefix fails (繁/簡 edge), match via simplified
    /// forms and drop the same character count from the Traditional phrase so outputMode
    /// conversion still runs on Traditional text. Phrase == seed → empty (dismiss, no insert).
    private func associationSuffixToInsert(phrase: String) -> String {
        let seed = associationSeed
        guard !seed.isEmpty else { return phrase }
        if phrase.hasPrefix(seed) {
            return String(phrase.dropFirst(seed.count))
        }
        let seedS = convertToSimplified(seed)
        let phraseS = convertToSimplified(phrase)
        if phraseS.hasPrefix(seedS), phrase.count >= seed.count {
            return String(phrase.dropFirst(seed.count))
        }
        // Avoid doubling an already-committed seed when forms do not match cleanly.
        return ""
    }

    private func clearComposition(client: Any?) {
        punctMode = false
        punctPageIndex = 0
        buffer = ""
        charCandidates = []
        phraseCandidates = []
        lookKind = .all
        selectedIndex = 0
        clearAssociation()
        if let client = (client as? IMKTextInput) ?? (currentClient as? IMKTextInput) {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    // MARK: - Association (聯想 after single 字)

    private var hasAssociation: Bool { !associationPhrases.isEmpty }

    private func clearAssociation(hideWindow: Bool = true) {
        let wasArmed = associationPickEnabled
        associationSeed = ""
        associationPhrases = []
        associationPickEnabled = false
        if buffer.isEmpty {
            // Avoid stale lookKind=.phrases stealing the next digit as a pick.
            if hideWindow {
                phraseCandidates = []
                charCandidates = []
                lookKind = .all
                selectedIndex = 0
                CandidateWindow.shared.hide()
            }
            // Drop caret " **" left by association 選詞 arm (commit/clearComposition already clear).
            if wasArmed {
                if let client = currentClient as? IMKTextInput {
                    client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
        }
    }

    private func beginAssociation(for character: String, client: Any?) {
        guard character.count == 1 else {
            clearAssociation()
            return
        }
        let phrases = DictionaryStore.shared.phrasesStarting(with: character)
        guard !phrases.isEmpty else {
            clearAssociation()
            ckcLog("association none for '\(character)'")
            return
        }
        associationSeed = character
        associationPhrases = phrases
        associationPickEnabled = false
        lookKind = .phrases
        charCandidates = []
        phraseCandidates = phrases
        selectedIndex = 0
        showAssociationWindow(client: client)
        ckcLog("association show seed='\(character)' phrases=\(phrases.count) (pick after 選詞 only)")
    }

    private func showAssociationWindow(client: Any?) {
        syncAssociationWindow(near: client)
    }

    private func syncAssociationWindow(near client: Any?) {
        guard hasAssociation else { return }
        var chrome = associationSeed
        if associationPickEnabled { chrome += " **" }
        CandidateWindow.shared.show(
            composition: chrome,
            chars: [],
            phrases: associationPhrases,
            mode: .phrases,
            focus: .phrases,
            digitSource: StatusConsole.shared.digitSource,
            near: (client as AnyObject?) ?? currentClient
        )
        phraseCandidates = associationPhrases
        selectedIndex = CandidateWindow.shared.globalSelectedIndex
    }


    // MARK: - Punctuation (Windows CKC keypad "-")

    /// Open 標點 with empty buffer (idle special key). Clears composition; no marked "?".
    private func enterPunctMode(client: Any?) {
        punctMode = true
        punctPageIndex = 0
        buffer = ""
        clearAssociation(hideWindow: false)
        lookKind = .characters
        charCandidates = []
        phraseCandidates = []
        selectedIndex = 0
        if DictionaryStore.shared.punctuationList.isEmpty {
            DictionaryStore.shared.loadPunctuationTable()
        }
        showPunctCandidates(client: client)
        ckcLog(String(format: "punctMode ON page %d/%d items=%d visible=%d",
                      punctPageIndex + 1, punctPages.count,
                      DictionaryStore.shared.punctuationList.count,
                      CandidateWindow.shared.isVisible ? 1 : 0))
    }

    private func exitPunctMode() {
        if punctMode {
            ckcLog("punctMode OFF")
        }
        punctMode = false
        punctPageIndex = 0
        lookKind = .all
        charCandidates = []
        phraseCandidates = []
        selectedIndex = 0
        CandidateWindow.shared.hide()
    }

    /// Show 標點 CandidateWindow. Idle punct keeps buffer empty (no leading marked "?").
    private func showPunctCandidates(client: Any?) {
        let pages = punctPages
        guard !pages.isEmpty else {
            ckcLog("punct pages empty")
            return
        }
        if punctPageIndex >= pages.count { punctPageIndex = 0 }
        let page = pages[punctPageIndex]
        charCandidates = page
        phraseCandidates = []
        lookKind = .characters
        selectedIndex = 0
        let clientObj = (client as AnyObject?) ?? currentClient
        // Same CandidateWindow path/chrome/caret positioning as 字/詞 — not parked by StatusConsole.
        CandidateWindow.shared.show(
            composition: "標點 \(punctPageIndex + 1)/\(pages.count)",
            chars: page,
            phrases: [],
            mode: .characters,
            focus: .characters,
            digitSource: StatusConsole.shared.digitSource,
            near: clientObj
        )
        ckcLog(String(format: "showPunct page=%d count=%d frame=%@",
                      punctPageIndex + 1, page.count,
                      NSStringFromRect(CandidateWindow.shared.frame)))
    }

    private func commitPunct(_ text: String, client: Any?) {
        exitPunctMode()
        // Clear provisional marked "?" from dual idle (or any leftover buffer) before inserting punct.
        buffer = ""
        charCandidates = []
        phraseCandidates = []
        lookKind = .all
        selectedIndex = 0
        guard let client = (client as? IMKTextInput) ?? (currentClient as? IMKTextInput) else { return }
        
        // Convert punctuation to Simplified if output mode is simplified
        let outputText: String
        if StatusConsole.shared.outputMode == .simplified {
            outputText = convertToSimplified(text)
        } else {
            outputText = text
        }
        
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        client.insertText(outputText, replacementRange: NSRange(location: NSNotFound, length: 0))
        NSLog("[CKC] punct %@ (outputMode=%@)", outputText, StatusConsole.shared.outputMode.rawValue)
    }

    private struct DigitInfo {
        let value: Int
        let source: DigitSource
    }

    private func classifyDigit(keyCode: Int, characters: String, rawFlags: NSEvent.ModifierFlags) -> DigitInfo? {
        // Numpad keys (Carbon keycodes) — primary path for 小鍵盤 mode
        switch keyCode {
        case Int(kVK_ANSI_Keypad0): return DigitInfo(value: 0, source: .numpad)
        case Int(kVK_ANSI_Keypad1): return DigitInfo(value: 1, source: .numpad)
        case Int(kVK_ANSI_Keypad2): return DigitInfo(value: 2, source: .numpad)
        case Int(kVK_ANSI_Keypad3): return DigitInfo(value: 3, source: .numpad)
        case Int(kVK_ANSI_Keypad4): return DigitInfo(value: 4, source: .numpad)
        case Int(kVK_ANSI_Keypad5): return DigitInfo(value: 5, source: .numpad)
        case Int(kVK_ANSI_Keypad6): return DigitInfo(value: 6, source: .numpad)
        case Int(kVK_ANSI_Keypad7): return DigitInfo(value: 7, source: .numpad)
        case Int(kVK_ANSI_Keypad8): return DigitInfo(value: 8, source: .numpad)
        case Int(kVK_ANSI_Keypad9): return DigitInfo(value: 9, source: .numpad)
        default: break
        }
        // Number row
        switch keyCode {
        case Int(kVK_ANSI_0): return DigitInfo(value: 0, source: .numberRow)
        case Int(kVK_ANSI_1): return DigitInfo(value: 1, source: .numberRow)
        case Int(kVK_ANSI_2): return DigitInfo(value: 2, source: .numberRow)
        case Int(kVK_ANSI_3): return DigitInfo(value: 3, source: .numberRow)
        case Int(kVK_ANSI_4): return DigitInfo(value: 4, source: .numberRow)
        case Int(kVK_ANSI_5): return DigitInfo(value: 5, source: .numberRow)
        case Int(kVK_ANSI_6): return DigitInfo(value: 6, source: .numberRow)
        case Int(kVK_ANSI_7): return DigitInfo(value: 7, source: .numberRow)
        case Int(kVK_ANSI_8): return DigitInfo(value: 8, source: .numberRow)
        case Int(kVK_ANSI_9): return DigitInfo(value: 9, source: .numberRow)
        default: break
        }
        // Fallback by character — honor .numericPad so keypad never mislabeled as number-row
        if characters.count == 1, let ch = characters.first, ch.isNumber,
           let v = Int(String(ch)), (0...9).contains(v) {
            let src: DigitSource = rawFlags.contains(.numericPad) ? .numpad : .numberRow
            return DigitInfo(value: v, source: src)
        }
        return nil
    }
}
