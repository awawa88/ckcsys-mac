import Cocoa

/// Small Cocoa dialog: phrase text → auto CKC code → Save to user_phrases.tsv.
final class AddPhrasePanel: NSObject, NSTextFieldDelegate {
    static let shared = AddPhrasePanel()

    private var window: NSWindow?
    private var phraseField: NSTextField!
    private var codeField: NSTextField!
    private var statusLabel: NSTextField!
    private var presetCode: String?

    func show(presetCode: String? = nil, presetPhrase: String? = nil) {
        self.presetCode = presetCode
        DispatchQueue.main.async {
            self.buildIfNeeded()
            if let p = presetPhrase, !p.isEmpty {
                self.phraseField.stringValue = p
                self.recomputeCode(allowManualOverride: false)
            } else if let c = presetCode, !c.isEmpty {
                self.codeField.stringValue = c
                self.statusLabel.stringValue = "已帶入目前編碼；輸入詞語後可自動重算，或手動改碼。"
            } else {
                self.phraseField.stringValue = ""
                self.codeField.stringValue = ""
                self.statusLabel.stringValue = "輸入詞語 → 自動編碼（可改）。規則：1字全碼；2字3+3；3字2+2+2；4字2+1+1+2；5+字2+1+1+1+1。"
            }
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeFirstResponder(self.phraseField)
        }
    }

    private func buildIfNeeded() {
        if window != nil { return }

        let rect = NSRect(x: 0, y: 0, width: 420, height: 220)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Ckcsys — 新增詞語"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()

        let content = NSView(frame: rect)

        let phraseLabel = NSTextField(labelWithString: "詞語：")
        phraseLabel.frame = NSRect(x: 20, y: 170, width: 60, height: 22)
        content.addSubview(phraseLabel)

        phraseField = NSTextField(frame: NSRect(x: 80, y: 168, width: 320, height: 24))
        phraseField.placeholderString = "例如：縱橫"
        phraseField.delegate = self
        content.addSubview(phraseField)

        let codeLabel = NSTextField(labelWithString: "編碼：")
        codeLabel.frame = NSRect(x: 20, y: 130, width: 60, height: 22)
        content.addSubview(codeLabel)

        codeField = NSTextField(frame: NSRect(x: 80, y: 128, width: 200, height: 24))
        codeField.placeholderString = "自動填入，可改"
        content.addSubview(codeField)

        let recomputeBtn = NSButton(frame: NSRect(x: 290, y: 126, width: 110, height: 28))
        recomputeBtn.title = "依詞語重算"
        recomputeBtn.bezelStyle = .rounded
        recomputeBtn.target = self
        recomputeBtn.action = #selector(recomputeClicked)
        content.addSubview(recomputeBtn)

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 60, width: 380, height: 56)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        let saveBtn = NSButton(frame: NSRect(x: 220, y: 18, width: 90, height: 32))
        saveBtn.title = "儲存"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(saveClicked)
        content.addSubview(saveBtn)

        let cancelBtn = NSButton(frame: NSRect(x: 320, y: 18, width: 80, height: 32))
        cancelBtn.title = "取消"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelClicked)
        content.addSubview(cancelBtn)

        let revealBtn = NSButton(frame: NSRect(x: 20, y: 18, width: 160, height: 32))
        revealBtn.title = "在 Finder 開啟檔案"
        revealBtn.bezelStyle = .rounded
        revealBtn.target = self
        revealBtn.action = #selector(revealClicked)
        content.addSubview(revealBtn)

        win.contentView = content
        self.window = win
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === phraseField else { return }
        recomputeCode(allowManualOverride: false)
    }

    @objc private func recomputeClicked() {
        recomputeCode(allowManualOverride: false)
    }

    private func recomputeCode(allowManualOverride: Bool) {
        let phrase = phraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            if !allowManualOverride { codeField.stringValue = "" }
            return
        }
        var missing: [String] = []
        if let code = DictionaryStore.shared.computeCode(forPhrase: phrase, missing: &missing) {
            codeField.stringValue = code
            statusLabel.stringValue = "自動編碼：\(code)（可手動修改後儲存）"
            statusLabel.textColor = .secondaryLabelColor
        } else if !missing.isEmpty {
            statusLabel.stringValue = "字碼表無：\(missing.joined()) — 請手動輸入編碼"
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "無法計算編碼"
            statusLabel.textColor = .systemOrange
        }
    }

    @objc private func saveClicked() {
        let phrase = phraseField.stringValue
        let code = codeField.stringValue
        if let err = DictionaryStore.shared.addUserPhrase(code: code, phrase: phrase) {
            statusLabel.stringValue = err
            statusLabel.textColor = .systemRed
            return
        }
        statusLabel.stringValue = "已儲存 \(code) → \(phrase.trimmingCharacters(in: .whitespacesAndNewlines))"
        statusLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.window?.orderOut(nil)
        }
    }

    @objc private func cancelClicked() {
        window?.orderOut(nil)
    }

    @objc private func revealClicked() {
        DictionaryStore.shared.revealUserPhrasesInFinder()
    }
}
