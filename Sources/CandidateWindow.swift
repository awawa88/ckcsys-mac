import Cocoa
import InputMethodKit

/// Which column of the two-column candidate HUD is focused.
enum CandidateColumn {
    case characters  // 選字列 (left)
    case phrases     // 選詞區 (right)
}

/// Display mode for columns.
enum CandidateDisplayMode {
    case both        // default while typing digits
    case characters  // / or Y — chars only (or phrases dimmed)
    case phrases     // * or T — phrases only
}

/// Native-looking floating candidate popup for CKC digit composition.
/// Two columns like Windows 縱橫: left = single chars (1–9), right = phrases (1–9 after T/*).
/// Vibrancy HUD, rounded corners, dark-mode aware.
final class CandidateWindow: NSPanel {
    static let shared = CandidateWindow()

    /// Callback when a candidate is clicked: (text: String, column: CandidateColumn)
    var onCandidateClicked: ((String, CandidateColumn) -> Void)?

    private let pageSize = 9
    private var charCandidates: [String] = []
    private var phraseCandidates: [String] = []
    private var composition: String = ""
    private var displayMode: CandidateDisplayMode = .both

    private var focusedColumn: CandidateColumn = .characters
    private var selectedIndex: Int = 0   // index within current page of focused column
    private var pageIndex: Int = 0       // shared page index

    private var effectView: NSVisualEffectView!
    private var contentStack: NSStackView!
    private var pageLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var columnsStack: NSStackView!
    private var leftStack: NSStackView!
    private var rightStack: NSStackView!
    private var leftColumnBox: NSView!
    private var rightColumnBox: NSView!
    private var leftTitleLabel: NSTextField!
    private var rightTitleLabel: NSTextField!
    private var charRowViews: [CandidateRowView] = []
    private var phraseRowViews: [CandidateRowView] = []
    /// Active digit mode — drives ÷/× vs Y/T column headers and footer hint.
    private var digitSource: DigitSource = .numpad
    /// Last known caret position - may be suspicious (near corners/edges).
    /// Always re-query on each show() and upgrade from suspicious to good rects.
    private var lastKnownCaretRect: NSRect?
    /// Initial fallback position captured once per composition session.
    private var initialFallbackPosition: NSPoint?
    /// Local event monitor to force cursor even when NSButton.cursor fails in nonactivating panels.
    private var cursorMonitor: Any?

    private let panelWidthBoth: CGFloat = 340
    private let panelWidthSingle: CGFloat = 200
    private let cornerRadius: CGFloat = 14
    private let charColWidth: CGFloat = 88
    private let phraseColWidth: CGFloat = 200

    // MARK: - Public state

    var selectedCandidate: String? {
        let list = focusedList
        let global = pageIndex * pageSize + selectedIndex
        guard global >= 0, global < list.count else { return nil }
        return list[global]
    }

    var focusedColumnPublic: CandidateColumn { focusedColumn }
    var displayModePublic: CandidateDisplayMode { displayMode }

    var pageCount: Int {
        let leftPages = charPageCount
        let rightPages = phrasePageCount
        switch displayMode {
        case .both: return max(1, max(leftPages, rightPages))
        case .characters: return max(1, leftPages)
        case .phrases: return max(1, rightPages)
        }
    }

    private var charPageCount: Int {
        guard !charCandidates.isEmpty else { return 0 }
        return Int(ceil(Double(charCandidates.count) / Double(pageSize)))
    }

    private var phrasePageCount: Int {
        guard !phraseCandidates.isEmpty else { return 0 }
        return Int(ceil(Double(phraseCandidates.count) / Double(pageSize)))
    }

    private var focusedList: [String] {
        switch focusedColumn {
        case .characters: return charCandidates
        case .phrases: return phraseCandidates
        }
    }

    private var panelWidth: CGFloat {
        displayMode == .both ? panelWidthBoth : panelWidthSingle
    }

    // MARK: - Init

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidthBoth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above StatusConsole (.floating) so 字/詞 panel is never covered by the strip.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        // AppKit window shadow is rectangular; with a transparent NSPanel it leaks
        // as solid black right-angle corners outside the rounded vibrancy mask.
        // Depth comes from the container layer shadow instead.
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // Ensure mouse events (clicks and cursor rects) work for nonactivating panel
        ignoresMouseEvents = false

        buildUI()
        orderOut(nil)
    }

    private func buildUI() {
        effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidthBoth, height: 120))
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        // IME is LSUIElement / never key — followsWindowActiveState washes out the HUD.
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.clipsToBounds = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let container = NSView(frame: effectView.bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.35
        container.layer?.shadowRadius = 20
        container.layer?.shadowOffset = CGSize(width: 0, height: -3)
        container.autoresizingMask = [.width, .height]
        effectView.autoresizingMask = [.width, .height]
        container.addSubview(effectView)

        // Composition digits stay in the client marked text only — not duplicated here.
        pageLabel = NSTextField(labelWithString: "")
        pageLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = .tertiaryLabelColor
        pageLabel.alignment = .right

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [headerSpacer, pageLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 8
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Left column: chars numbered 1–9
        leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 1
        leftStack.distribution = .fill
        for i in 0..<pageSize {
            let row = CandidateRowView()
            row.onClicked = { [weak self] in
                self?.handleRowClick(index: i, column: .characters)
            }
            charRowViews.append(row)
            leftStack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        leftColumnBox = wrapColumn(leftStack, title: "選字÷", minWidth: charColWidth, titleOut: &leftTitleLabel)

        // Right column: phrases numbered 1–9 (pick after T/*)
        rightStack = NSStackView()
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 1
        rightStack.distribution = .fill
        for i in 0..<pageSize {
            let row = CandidateRowView()
            row.onClicked = { [weak self] in
                self?.handleRowClick(index: i, column: .phrases)
            }
            phraseRowViews.append(row)
            rightStack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: rightStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        rightColumnBox = wrapColumn(rightStack, title: "選詞×", minWidth: phraseColWidth, titleOut: &rightTitleLabel)

        // Vertical separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true

        columnsStack = NSStackView(views: [leftColumnBox, separator, rightColumnBox])
        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.spacing = 6
        columnsStack.distribution = .fill
        leftColumnBox.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rightColumnBox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        hintLabel = NSTextField(labelWithString: "↑↓選  ←→欄  ×後1–9選詞  ÷後1–9選字  −/=翻頁  Space確認")
        hintLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .left
        hintLabel.lineBreakMode = .byTruncatingTail

        contentStack = NSStackView(views: [header, columnsStack, hintLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -20),
            columnsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -20),
            hintLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -20),
            leftColumnBox.widthAnchor.constraint(equalToConstant: charColWidth),
            rightColumnBox.widthAnchor.constraint(greaterThanOrEqualToConstant: phraseColWidth - 40),
        ])

        contentView = container
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func wrapColumn(_ stack: NSStackView, title: String, minWidth: CGFloat, titleOut: inout NSTextField!) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        // Semibold so 選字÷ / 選詞× (or Y/T) read as headers.
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleOut = titleLabel

        let col = NSStackView(views: [titleLabel, stack])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            col.topAnchor.constraint(equalTo: box.topAnchor),
            col.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
            titleLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
        return box
    }

    // MARK: - Public API

    /// Show two-column candidates. `mode` controls which columns are visible.
    /// `digitSource` sets left/right headers to 選字÷/選詞× (小鍵盤) or 選字Y/選詞T (鍵盤).
    func show(
        composition: String,
        chars: [String],
        phrases: [String],
        mode: CandidateDisplayMode = .both,
        focus: CandidateColumn? = nil,
        digitSource: DigitSource = StatusConsole.shared.digitSource,
        near client: AnyObject?
    ) {
        self.composition = composition
        self.charCandidates = chars
        self.phraseCandidates = phrases
        self.displayMode = mode
        self.digitSource = digitSource

        let hasChars = !chars.isEmpty
        let hasPhrases = !phrases.isEmpty

        if !hasChars && !hasPhrases {
            hide()
            return
        }

        // Resolve focus
        if let focus = focus {
            focusedColumn = focus
        } else {
            switch mode {
            case .characters:
                focusedColumn = .characters
            case .phrases:
                focusedColumn = .phrases
            case .both:
                // Keep current if still valid; else prefer chars then phrases
                if focusedColumn == .characters && !hasChars && hasPhrases {
                    focusedColumn = .phrases
                } else if focusedColumn == .phrases && !hasPhrases && hasChars {
                    focusedColumn = .characters
                } else if focusedColumn == .characters && !hasChars {
                    focusedColumn = .phrases
                } else if focusedColumn == .phrases && !hasPhrases {
                    focusedColumn = .characters
                }
            }
        }

        // Clamp focus to available data under mode
        switch mode {
        case .characters:
            focusedColumn = .characters
            if !hasChars { hide(); return }
        case .phrases:
            focusedColumn = .phrases
            if !hasPhrases { hide(); return }
        case .both:
            break
        }

        // Clamp page / selection
        let list = focusedList
        let maxPage = max(0, pageCount - 1)
        if pageIndex > maxPage { pageIndex = maxPage }
        let pageLen = min(pageSize, max(0, list.count - pageIndex * pageSize))
        if selectedIndex >= pageLen { selectedIndex = max(0, pageLen - 1) }

        applyDigitModeLabels()
        reloadRows()
        position(near: client)
        // Always raise — StatusConsole may have been orderFront'd; keep candidates on top after T/Y/*/ /.
        alphaValue = 1
        level = .popUpMenu
        orderFrontRegardless()
        applyAppearance()
        
        // Start monitoring for cursor changes (fallback for nonactivating panel)
        startCursorMonitoring()
    }

    /// Idle 標點 picker — same chrome and caret positioning as composition candidates.
    /// Kept for callers; prefer `show(composition:chars:…)` from the controller.
    func showPunctuationPage(title: String, marks: [String], near client: AnyObject?) {
        show(
            composition: title,
            chars: marks,
            phrases: [],
            mode: .characters,
            focus: .characters,
            near: client
        )
    }

    func hide() {
        charCandidates = []
        phraseCandidates = []
        composition = ""
        selectedIndex = 0
        pageIndex = 0
        focusedColumn = .characters
        displayMode = .both
        // Reset cached positions for next composition session
        lastKnownCaretRect = nil
        initialFallbackPosition = nil
        stopCursorMonitoring()
        orderOut(nil)
    }

    /// Move selection within the focused column (crosses pages).
    @discardableResult
    func moveSelection(_ delta: Int) -> Int {
        let list = focusedList
        guard !list.isEmpty else { return 0 }
        var global = pageIndex * pageSize + selectedIndex + delta
        global = max(0, min(global, list.count - 1))
        pageIndex = global / pageSize
        selectedIndex = global % pageSize
        // Keep shared page in range of the other side too
        let maxPage = max(0, pageCount - 1)
        if pageIndex > maxPage {
            pageIndex = maxPage
            selectedIndex = 0
        }
        reloadRows()
        return global
    }

    /// Switch focused column (←→ or Tab). Returns true if switched.
    @discardableResult
    func switchColumn() -> Bool {
        guard displayMode == .both else { return false }
        let target: CandidateColumn = (focusedColumn == .characters) ? .phrases : .characters
        let targetList = (target == .characters) ? charCandidates : phraseCandidates
        guard !targetList.isEmpty else { return false }
        focusedColumn = target
        // Keep page; clamp selection to available rows on this page
        let start = pageIndex * pageSize
        let pageLen = min(pageSize, max(0, targetList.count - start))
        if pageLen == 0 {
            // Jump to last page that has items for this column
            let pages = max(1, Int(ceil(Double(targetList.count) / Double(pageSize))))
            pageIndex = pages - 1
            selectedIndex = 0
        } else if selectedIndex >= pageLen {
            selectedIndex = pageLen - 1
        }
        reloadRows()
        return true
    }

    func focusColumn(_ column: CandidateColumn) {
        let list = (column == .characters) ? charCandidates : phraseCandidates
        guard !list.isEmpty else { return }
        focusedColumn = column
        let start = pageIndex * pageSize
        let pageLen = min(pageSize, max(0, list.count - start))
        if pageLen == 0 {
            pageIndex = 0
            selectedIndex = 0
        } else if selectedIndex >= pageLen {
            selectedIndex = pageLen - 1
        }
        reloadRows()
        orderFrontRegardless()
    }

    @discardableResult
    func nextPage() -> Int {
        guard pageIndex + 1 < pageCount else {
            return pageIndex * pageSize + selectedIndex
        }
        pageIndex += 1
        selectedIndex = 0
        // If focused column empty on new page, try other column in both mode
        let list = focusedList
        let start = pageIndex * pageSize
        if start >= list.count, displayMode == .both {
            let other: CandidateColumn = focusedColumn == .characters ? .phrases : .characters
            let otherList = other == .characters ? charCandidates : phraseCandidates
            if pageIndex * pageSize < otherList.count {
                focusedColumn = other
            }
        }
        reloadRows()
        return pageIndex * pageSize
    }

    @discardableResult
    func prevPage() -> Int {
        guard pageIndex > 0 else {
            return pageIndex * pageSize + selectedIndex
        }
        pageIndex -= 1
        selectedIndex = 0
        reloadRows()
        return pageIndex * pageSize
    }

    /// Pick left-column char by 1-based index on current page (1–9).
    func selectCharOnPage(_ oneBased: Int) -> String? {
        let idx = oneBased - 1
        guard idx >= 0, idx < pageSize else { return nil }
        let global = pageIndex * pageSize + idx
        guard global < charCandidates.count else { return nil }
        focusedColumn = .characters
        selectedIndex = idx
        reloadRows()
        return charCandidates[global]
    }

    /// Pick right-column phrase by 1-based index on current page (1–9 or 1–10).
    func selectPhraseOnPage(_ oneBased: Int) -> String? {
        let idx = oneBased - 1
        guard idx >= 0, idx < pageSize else { return nil }
        let global = pageIndex * pageSize + idx
        guard global < phraseCandidates.count else { return nil }
        focusedColumn = .phrases
        selectedIndex = idx
        reloadRows()
        return phraseCandidates[global]
    }

    var globalSelectedIndex: Int {
        pageIndex * pageSize + selectedIndex
    }

    // MARK: - Digit-mode column headers / footer

    /// Update ÷/× or Y/T headers and the short footer hint for the active DigitSource.
    func applyDigitModeLabels(digitSource: DigitSource? = nil) {
        if let digitSource {
            self.digitSource = digitSource
        }
        leftTitleLabel?.stringValue = self.digitSource.charColumnHeader
        rightTitleLabel?.stringValue = self.digitSource.phraseColumnHeader
        let charKey = self.digitSource.charEndKey
        let phraseKey = self.digitSource.phraseEndKey
        hintLabel?.stringValue = "↑↓選  ←→欄  \(phraseKey)後1–9選詞  \(charKey)後1–9選字  −/=翻頁  Space確認"
    }

    // MARK: - Mouse click handling

    private func handleRowClick(index: Int, column: CandidateColumn) {
        let global = pageIndex * pageSize + index
        let candidates = (column == .characters) ? charCandidates : phraseCandidates
        guard global >= 0, global < candidates.count else { return }
        let text = candidates[global]
        onCandidateClicked?(text, column)
    }

    // MARK: - Cursor monitoring (fallback for nonactivating panel)
    
    /// Install a local event monitor to force cursor when over clickable candidates.
    /// NSButton.cursor may not work in nonactivating panels under Chrome, so we
    /// intercept mouseMoved globally and check if we're over a candidate.
    private func startCursorMonitoring() {
        stopCursorMonitoring()
        
        cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            
            let mouseLocation = NSEvent.mouseLocation
            let windowFrame = self.frame
            
            // Check if mouse is within our panel bounds
            guard windowFrame.contains(mouseLocation) else {
                // Outside panel - let default cursor show
                return event
            }
            
            // Convert to window coordinates for hit testing
            let windowPoint = self.convertPoint(fromScreen: mouseLocation)
            
            // Use AppKit hit testing to find which view is under the mouse
            if let hitView = self.contentView?.hitTest(windowPoint) {
                // Check if hit view is a candidate row or descendant
                for row in self.charRowViews + self.phraseRowViews {
                    if (hitView == row || hitView.isDescendant(of: row)) && !row.isEmpty {
                        NSCursor.pointingHand.set()
                        return event
                    }
                }
            }
            
            // Over panel but not over a candidate - show arrow
            NSCursor.arrow.set()
            return event
        }
    }
    
    private func stopCursorMonitoring() {
        if let monitor = cursorMonitor {
            NSEvent.removeMonitor(monitor)
            cursorMonitor = nil
        }
    }

    // MARK: - Layout / paint

    private func reloadRows() {
        applyAppearance()
        if pageCount > 1 {
            pageLabel.stringValue = "\(pageIndex + 1) / \(pageCount)"
        } else {
            let total = charCandidates.count + phraseCandidates.count
            pageLabel.stringValue = total > 0 ? "\(pageIndex + 1) / 1" : ""
        }

        let showLeft = displayMode != .phrases && !charCandidates.isEmpty
        let showRight = displayMode != .characters && !phraseCandidates.isEmpty
        // In both mode with only one side populated, still show that side
        leftColumnBox.isHidden = !showLeft
        rightColumnBox.isHidden = !showRight
        // Separator is middle arranged view
        if let sep = columnsStack.arrangedSubviews.first(where: { $0 is NSBox }) {
            sep.isHidden = !(showLeft && showRight)
        }

        let start = pageIndex * pageSize
        var visibleLeft = 0
        var visibleRight = 0

        for i in 0..<pageSize {
            let global = start + i
            if showLeft, global < charCandidates.count {
                charRowViews[i].isHidden = false
                let selected = focusedColumn == .characters && i == selectedIndex
                charRowViews[i].configure(
                    label: "\(i + 1)",
                    text: charCandidates[global],
                    selected: selected,
                    labelWidth: 16
                )
                visibleLeft += 1
            } else {
                charRowViews[i].isHidden = true
            }

            if showRight, global < phraseCandidates.count {
                phraseRowViews[i].isHidden = false
                let selected = focusedColumn == .phrases && i == selectedIndex
                phraseRowViews[i].configure(
                    label: "\(i + 1)",
                    text: phraseCandidates[global],
                    selected: selected,
                    labelWidth: 16
                )
                visibleRight += 1
            } else {
                phraseRowViews[i].isHidden = true
            }
        }

        let visibleRows = max(visibleLeft, visibleRight, 1)
        let headerH: CGFloat = 18
        let colTitleH: CGFloat = 16  // ÷/× or Y/T column titles
        let hintH: CGFloat = 14
        let pad: CGFloat = 20
        let rowsH = CGFloat(visibleRows) * 28 + CGFloat(max(visibleRows - 1, 0)) * 1
        let height = pad + headerH + 6 + colTitleH + rowsH + 4 + hintH
        // Single-column: size to the visible column (字 narrow / 詞 wider).
        let width: CGFloat
        if showLeft && showRight {
            width = panelWidthBoth
        } else if showRight {
            width = max(panelWidthSingle, phraseColWidth + 24)
        } else {
            width = max(140, charColWidth + 36)
        }
        columnsStack.needsLayout = true
        contentStack.needsLayout = true
        effectView.needsLayout = true
        let newFrame = NSRect(origin: self.frame.origin, size: NSSize(width: width, height: height))
        setFrame(newFrame, display: true)
        if let cv = contentView {
            cv.frame = NSRect(origin: .zero, size: newFrame.size)
        }
        effectView.frame = NSRect(origin: .zero, size: newFrame.size)
        contentStack.layoutSubtreeIfNeeded()
    }

    private func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectView.appearance = NSApp.effectiveAppearance
        effectView.material = dark ? .hudWindow : .popover
        effectView.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }

    private func position(near client: AnyObject?) {
        // Always query fresh caret position - Chrome/Docs may return better rects after marked text.
        let freshAnchor = caretAnchor(near: client)
        
        let screen: NSScreen?
        let visible: NSRect
        var rectToUse: NSRect?
        
        // Prefer good fresh rect > suspicious fresh rect > cached rect > fallback
        if let fresh = freshAnchor {
            let suspicious = isSuspiciousCaretRect(fresh)
            if suspicious {
                NSLog("[CKC] fresh caret rect is SUSPICIOUS (near corner/edge): %@ - will keep trying to upgrade",
                      NSStringFromRect(fresh))
            } else {
                NSLog("[CKC] fresh caret rect is GOOD: %@", NSStringFromRect(fresh))
            }
            // Always use fresh rect if we got one, but cache good rects preferentially
            lastKnownCaretRect = fresh
            rectToUse = fresh
            screen = screenFor(fresh.origin)
            visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        } else if let cached = lastKnownCaretRect {
            // No fresh rect, use cached (might be suspicious but better than fallback)
            let suspicious = isSuspiciousCaretRect(cached)
            NSLog("[CKC] using cached caret rect%@: %@",
                  suspicious ? " (suspicious, but no fresh rect available)" : "",
                  NSStringFromRect(cached))
            rectToUse = cached
            screen = screenFor(cached.origin)
            visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        } else {
            // No rect at all - use stable fallback
            let mouse = NSEvent.mouseLocation
            screen = screenFor(mouse)
            visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
        
        let size = frame.size
        var origin: NSPoint
        
        if let rect = rectToUse {
            // Use caret position (fresh or cached)
            // Prefer below caret; flip above if not enough room.
            origin = NSPoint(x: rect.origin.x, y: rect.origin.y - size.height - 6)
            if origin.y < visible.minY + 8 {
                origin.y = rect.maxY + 6
            }
        } else {
            // Fallback: capture initial position once per session.
            // Use lower-center of screen (stable, never tracks mouse movement).
            if let cached = initialFallbackPosition {
                origin = cached
            } else {
                origin = NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.minY + max(120, visible.height * 0.35)
                )
                initialFallbackPosition = origin
                NSLog("[CKC] no caret rect available — using stable fallback position at screen lower-center: %@",
                      NSStringFromPoint(origin))
            }
        }

        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))

        // Only nudge if we would cover the strip; still client-first.
        origin = originClearingStatusConsole(origin, size: size, visible: visible)

        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Best-effort caret / insert-point rect from the IMK client.
    /// Returns the first GOOD (non-suspicious) rect, or falls back to a suspicious rect.
    private func caretAnchor(near client: AnyObject?) -> NSRect? {
        guard let client = client else { return nil }

        var candidateRects: [(rect: NSRect, suspicious: Bool)] = []

        if let input = client as? IMKTextInput {
            // Try indices near the marked text end / current composition position.
            // Chrome/Docs/Word may return bogus rects for index 0 but correct for the end.
            let markedRange = input.markedRange()
            var indicesToTry: [Int] = []
            if markedRange.location != NSNotFound && markedRange.length > 0 {
                // Prioritize marked text range positions - Chrome updates these after setMarkedText
                let end = markedRange.location + markedRange.length
                indicesToTry.append(end)
                if end > 0 { indicesToTry.append(end - 1) }
                indicesToTry.append(markedRange.location)
                if markedRange.length > 1 { indicesToTry.append(markedRange.location + 1) }
            }
            // Also try 0, 1, 2 as fallbacks
            indicesToTry.append(contentsOf: [0, 1, 2])
            
            for idx in indicesToTry {
                var lineRect = NSRect.zero
                _ = input.attributes(forCharacterIndex: idx, lineHeightRectangle: &lineRect)
                if isPlausibleCaretRect(lineRect) {
                    let suspicious = isSuspiciousCaretRect(lineRect)
                    candidateRects.append((lineRect, suspicious))
                    // If we found a good rect, use it immediately
                    if !suspicious {
                        return lineRect
                    }
                }
            }
        }

        if let tic = client as? NSTextInputClient {
            let sel = tic.selectedRange()
            var actual = NSRange(location: NSNotFound, length: 0)
            // Try selection end first (most relevant for composition), then start, then zero
            var ranges: [NSRange] = []
            if sel.location != NSNotFound {
                let end = sel.location + sel.length
                ranges.append(NSRange(location: end, length: 0))
                if end > 0 { ranges.append(NSRange(location: end - 1, length: 0)) }
                ranges.append(sel)
                ranges.append(NSRange(location: max(0, sel.location), length: 0))
            }
            ranges.append(NSRange(location: 0, length: 0))
            
            for range in ranges {
                actual = NSRange(location: NSNotFound, length: 0)
                let r = tic.firstRect(forCharacterRange: range, actualRange: &actual)
                if isPlausibleCaretRect(r) {
                    let suspicious = isSuspiciousCaretRect(r)
                    candidateRects.append((r, suspicious))
                    // If we found a good rect, use it immediately
                    if !suspicious {
                        return r
                    }
                }
            }
        }
        
        // If we only found suspicious rects, return the first one as last resort
        if let first = candidateRects.first {
            return first.rect
        }
        
        return nil
    }

    /// Reject zero/garbage rects that IMK returns when there is no marked text.
    private func isPlausibleCaretRect(_ r: NSRect) -> Bool {
        guard r.width > 0.5 || r.height > 0.5 else { return false }
        // Reject empty-ish or wildly off-screen origins (common bogus idle values).
        if r.origin == .zero && r.width < 2 && r.height < 2 { return false }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return true }
        let pad: CGFloat = 200
        return screens.contains { screen in
            screen.frame.insetBy(dx: -pad, dy: -pad).intersects(r)
        }
    }
    
    /// Detect suspicious rects that Chrome/Docs returns before the user clicks.
    /// These pass basic plausibility but cluster near corners/edges (especially top-left).
    /// We'll use them as last resort but keep trying to upgrade to better rects.
    private func isSuspiciousCaretRect(_ r: NSRect) -> Bool {
        guard !NSScreen.screens.isEmpty else { return false }
        
        // Find which screen this rect is on
        let screen = NSScreen.screens.first { $0.frame.contains(r.origin) } 
            ?? NSScreen.main 
            ?? NSScreen.screens.first!
        let frame = screen.frame
        let visible = screen.visibleFrame
        
        // Chrome/Docs often returns rects clustered near (0,0) content origin
        // or near top-left of visible area before the user clicks.
        // Reject rects within 100pt of any screen corner or edge.
        let cornerMargin: CGFloat = 100
        let edgeMargin: CGFloat = 80
        
        let x = r.origin.x
        let y = r.origin.y
        
        // Too close to any corner
        let nearTopLeft = x < frame.minX + cornerMargin && y > frame.maxY - cornerMargin
        let nearTopRight = x > frame.maxX - cornerMargin && y > frame.maxY - cornerMargin
        let nearBottomLeft = x < frame.minX + cornerMargin && y < frame.minY + cornerMargin
        let nearBottomRight = x > frame.maxX - cornerMargin && y < frame.minY + cornerMargin
        
        if nearTopLeft || nearTopRight || nearBottomLeft || nearBottomRight {
            return true
        }
        
        // Too close to any edge (especially top and left where Chrome/Docs bogus rects cluster)
        let nearLeft = x < visible.minX + edgeMargin
        let nearTop = y > visible.maxY - edgeMargin
        let nearRight = x > visible.maxX - edgeMargin
        let nearBottom = y < visible.minY + edgeMargin
        
        // Top-left edge cluster is the most common bad rect from Chrome/Docs
        if nearLeft && nearTop {
            return true
        }
        
        // Suspicious if very close to any screen edge
        if nearLeft || nearTop || nearRight || nearBottom {
            return true
        }
        
        return false
    }

    private func screenFor(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// If the candidate panel would intersect the status strip, shift above/below/sideways.
    private func originClearingStatusConsole(_ origin: NSPoint, size: NSSize, visible: NSRect) -> NSPoint {
        let console = StatusConsole.shared
        guard console.isVisible else { return origin }
        let gap: CGFloat = 10
        let consoleFrame = console.frame.insetBy(dx: -gap, dy: -gap)
        var frame = NSRect(origin: origin, size: size)
        guard frame.intersects(consoleFrame) else { return origin }

        // Try above the console, then below, then to the side — keep on-screen.
        let aboveY = consoleFrame.maxY + 2
        let belowY = consoleFrame.minY - size.height - 2
        if aboveY + size.height <= visible.maxY - 8 {
            frame.origin.y = aboveY
        } else if belowY >= visible.minY + 8 {
            frame.origin.y = belowY
        }

        if frame.intersects(consoleFrame) {
            let rightX = consoleFrame.maxX + 2
            let leftX = consoleFrame.minX - size.width - 2
            if rightX + size.width <= visible.maxX - 8 {
                frame.origin.x = rightX
            } else if leftX >= visible.minX + 8 {
                frame.origin.x = leftX
            }
        }

        frame.origin.x = min(max(frame.origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        frame.origin.y = min(max(frame.origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        return frame.origin
    }
}

// MARK: - Row

/// Clickable candidate row as an actual NSButton for proper cursor + hover in nonactivating panels.
/// Real NSButton has cursor support that works where NSView/NSControl cursor rects fail.
private final class CandidateRowView: NSButton {
    private let numberLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private var labelWidthConstraint: NSLayoutConstraint!
    var onClicked: (() -> Void)?
    fileprivate(set) var isEmpty: Bool = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
        // NSButton configuration for transparent clickable area
        isBordered = false
        bezelStyle = .inline
        title = ""
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 6
        
        // Cursor: AppKit has no NSButton.cursor; use resetCursorRects + local
        // mouseMoved monitor (startCursorMonitoring) for nonactivating panels.

        // Labels as non-interactive subviews for display
        numberLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .left
        numberLabel.lineBreakMode = .byClipping
        numberLabel.isEditable = false
        numberLabel.isSelectable = false
        numberLabel.isBordered = false
        numberLabel.drawsBackground = false
        numberLabel.allowsEditingTextAttributes = false

        textLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isEditable = false
        textLabel.isSelectable = false
        textLabel.isBordered = false
        textLabel.drawsBackground = false
        textLabel.allowsEditingTextAttributes = false

        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberLabel)
        addSubview(textLabel)

        labelWidthConstraint = numberLabel.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelWidthConstraint,
            textLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 4),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        
        // Wire button action
        target = self
        action = #selector(handleClick)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    
    @objc private func handleClick() {
        guard !isEmpty else { return }
        onClicked?()
    }

    override func resetCursorRects() {
        discardCursorRects()
        if !isEmpty {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    func configure(label: String, text: String, selected: Bool, labelWidth: CGFloat = 16) {
        isEmpty = text.isEmpty
        
        numberLabel.stringValue = label
        textLabel.stringValue = text
        labelWidthConstraint.constant = labelWidth
        
        // Enable/disable; cursor via resetCursorRects + local monitor
        if isEmpty {
            isEnabled = false
        } else {
            isEnabled = true
        }
        window?.invalidateCursorRects(for: self)
        
        if selected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            numberLabel.textColor = .controlAccentColor
            textLabel.textColor = .labelColor
            textLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            numberLabel.textColor = .secondaryLabelColor
            textLabel.textColor = .labelColor
            textLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        }
    }
}
