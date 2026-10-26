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
    private var codeLabel: NSTextField!
    private var pageLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var columnsStack: NSStackView!
    private var leftStack: NSStackView!
    private var rightStack: NSStackView!
    private var leftColumnBox: NSView!
    private var rightColumnBox: NSView!
    private var charRowViews: [CandidateRowView] = []
    private var phraseRowViews: [CandidateRowView] = []

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
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

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
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let container = NSView(frame: effectView.bounds)
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.28
        container.layer?.shadowRadius = 18
        container.layer?.shadowOffset = CGSize(width: 0, height: -2)
        container.autoresizingMask = [.width, .height]
        effectView.autoresizingMask = [.width, .height]
        container.addSubview(effectView)

        codeLabel = NSTextField(labelWithString: "")
        codeLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        codeLabel.textColor = .secondaryLabelColor
        codeLabel.alignment = .left
        codeLabel.lineBreakMode = .byTruncatingTail

        pageLabel = NSTextField(labelWithString: "")
        pageLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = .tertiaryLabelColor
        pageLabel.alignment = .right

        let header = NSStackView(views: [codeLabel, pageLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 8
        codeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Left column: chars numbered 1–9
        leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 1
        leftStack.distribution = .fill
        for _ in 0..<pageSize {
            let row = CandidateRowView()
            charRowViews.append(row)
            leftStack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        leftColumnBox = wrapColumn(leftStack, title: "選字", minWidth: charColWidth)

        // Right column: phrases numbered 1–9 (pick after T/*)
        rightStack = NSStackView()
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 1
        rightStack.distribution = .fill
        for _ in 0..<pageSize {
            let row = CandidateRowView()
            phraseRowViews.append(row)
            rightStack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: rightStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        rightColumnBox = wrapColumn(rightStack, title: "選詞", minWidth: phraseColWidth)

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

        hintLabel = NSTextField(labelWithString: "↑↓選  ←→欄  T/*後1–9選詞  Y//後1–9選字  −/=翻頁  Space確認")
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
    }

    private func wrapColumn(_ stack: NSStackView, title: String, minWidth: CGFloat) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

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
    func show(
        composition: String,
        chars: [String],
        phrases: [String],
        mode: CandidateDisplayMode = .both,
        focus: CandidateColumn? = nil,
        near client: AnyObject?
    ) {
        self.composition = composition
        self.charCandidates = chars
        self.phraseCandidates = phrases
        self.displayMode = mode

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

        reloadRows()
        position(near: client)
        // Always raise — StatusConsole may have been orderFront'd; keep candidates on top after T/Y/*/ /.
        alphaValue = 1
        level = .popUpMenu
        orderFrontRegardless()
        applyAppearance()
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

    // MARK: - Layout / paint

    private func reloadRows() {
        applyAppearance()
        codeLabel.stringValue = composition.isEmpty ? " " : composition
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
        let colTitleH: CGFloat = 16  // 選字 / 選詞 column titles
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
        // Always anchor to the IMK text client / caret — never StatusConsole as primary.
        let anchor = caretAnchor(near: client)

        let screen = screenFor(anchor?.origin ?? NSEvent.mouseLocation)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = frame.size

        var origin: NSPoint
        if let a = anchor {
            // Prefer below caret; flip above if not enough room.
            origin = NSPoint(x: a.origin.x, y: a.origin.y - size.height - 6)
            if origin.y < visible.minY + 8 {
                origin.y = a.maxY + 6
            }
        } else {
            // Fallback: near mouse (typing area), else lower-center of the client screen.
            // Do NOT park beside StatusConsole.
            let mouse = NSEvent.mouseLocation
            if visible.contains(mouse) {
                origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
            } else {
                origin = NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.minY + max(120, visible.height * 0.35)
                )
            }
        }

        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))

        // Only nudge if we would cover the strip; still client-first.
        origin = originClearingStatusConsole(origin, size: size, visible: visible)

        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Best-effort caret / insert-point rect from the IMK client.
    private func caretAnchor(near client: AnyObject?) -> NSRect? {
        guard let client = client else { return nil }

        if let input = client as? IMKTextInput {
            // Try a few character indices — idle punct often has empty marked text.
            for idx in [0, 1, 2] {
                var lineRect = NSRect.zero
                _ = input.attributes(forCharacterIndex: idx, lineHeightRectangle: &lineRect)
                if isPlausibleCaretRect(lineRect) {
                    return lineRect
                }
            }
        }

        if let tic = client as? NSTextInputClient {
            let sel = tic.selectedRange()
            var actual = NSRange(location: NSNotFound, length: 0)
            let ranges: [NSRange] = [
                sel,
                NSRange(location: max(0, sel.location), length: 0),
                NSRange(location: 0, length: 0),
            ]
            for range in ranges {
                actual = NSRange(location: NSNotFound, length: 0)
                let r = tic.firstRect(forCharacterRange: range, actualRange: &actual)
                if isPlausibleCaretRect(r) {
                    return r
                }
            }
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

private final class CandidateRowView: NSView {
    private let numberLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private var selected = false
    private var labelWidthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        numberLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .left
        numberLabel.lineBreakMode = .byClipping

        textLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingTail

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func configure(label: String, text: String, selected: Bool, labelWidth: CGFloat = 16) {
        self.selected = selected
        numberLabel.stringValue = label
        textLabel.stringValue = text
        labelWidthConstraint.constant = labelWidth
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
