import Cocoa

/// Output mode: Traditional vs Simplified Chinese characters.
enum OutputMode: String {
    case traditional
    case simplified

    var label: String {
        switch self {
        case .traditional: return "繁"
        case .simplified: return "簡"
        }
    }

    mutating func toggle() {
        self = (self == .traditional) ? .simplified : .traditional
    }
}

/// Digit source for CKC codes: numpad (default) vs top number-row (laptop fallback).
enum DigitSource: String {
    case numpad
    case numberRow

    var label: String {
        switch self {
        case .numpad: return "小鍵盤"
        case .numberRow: return "鍵盤"
        }
    }

    /// Bare 字 end-key glyph: ÷ (numpad /) or Y (number-row).
    var charEndKey: String {
        switch self {
        case .numpad: return "÷"   // U+00F7
        case .numberRow: return "Y"
        }
    }

    /// Bare 詞 end-key glyph: × (numpad *) or T (number-row).
    var phraseEndKey: String {
        switch self {
        case .numpad: return "×"   // U+00D7
        case .numberRow: return "T"
        }
    }

    /// Left column header: 選字÷ or 選字Y (Chinese + end-key, no space).
    var charColumnHeader: String { "選字\(charEndKey)" }

    /// Right column header: 選詞× or 選詞T.
    var phraseColumnHeader: String { "選詞\(phraseEndKey)" }

    mutating func toggle() {
        self = (self == .numpad) ? .numberRow : .numpad
    }
}

/// Compact modern floating status strip (vibrancy HUD).
/// Shows logo · 繁/簡 · digit-source toggle (小鍵盤/鍵盤).
/// Drag empty chrome / labels to reposition; buttons keep normal clicks.
final class StatusConsole: NSPanel {
    static let shared = StatusConsole()

    private(set) var digitSource: DigitSource = .numpad {
        didSet { refreshLabels(); UserDefaults.standard.set(digitSource.rawValue, forKey: Self.digitSourceKey) }
    }

    private(set) var outputMode: OutputMode = .traditional {
        didSet { refreshLabels(); UserDefaults.standard.set(outputMode.rawValue, forKey: Self.outputModeKey) }
    }

    var onDigitSourceChanged: ((DigitSource) -> Void)?
    var onOutputModeChanged: ((OutputMode) -> Void)?

    private static let digitSourceKey = "ckc.digitSource"
    private static let outputModeKey = "ckc.outputMode"
    private static let originXKey = "ckc.statusConsole.originX"
    private static let originYKey = "ckc.statusConsole.originY"

    private var effectView: NSVisualEffectView!
    private var chromeView: ChromeView!
    private var sourceButton: NSButton!
    private var outputModeButton: NSButton!
    private let cornerRadius: CGFloat = 12
    private let stripHeight: CGFloat = 26
    private let stripWidth: CGFloat = 140

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: stripWidth, height: stripHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        // Same transparent NSPanel + rounded mask issue as CandidateWindow:
        // rectangular AppKit shadow leaks black corners; use layer shadow instead.
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // Borderless panels are not movable by background; we handle drag ourselves.
        isMovable = false
        isMovableByWindowBackground = false

        if let raw = UserDefaults.standard.string(forKey: Self.digitSourceKey),
           let saved = DigitSource(rawValue: raw) {
            digitSource = saved
        }

        if let raw = UserDefaults.standard.string(forKey: Self.outputModeKey),
           let saved = OutputMode(rawValue: raw) {
            outputMode = saved
        }

        buildUI()
        orderOut(nil)
    }

    private func buildUI() {
        // Single container with rounded mask - no borders or stacked radii
        let container = NSView(frame: NSRect(x: 0, y: 0, width: stripWidth, height: stripHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true
        
        // EffectView fills container exactly, inheriting the rounded clip
        effectView = NSVisualEffectView(frame: container.bounds)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .followsWindowActiveState
        effectView.wantsLayer = true
        // No separate cornerRadius or border - container masks it
        effectView.layer?.backgroundColor = NSColor.clear.cgColor
        effectView.autoresizingMask = [.width, .height]

        let logo = NSTextField(labelWithString: "縱")
        logo.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        logo.textColor = .controlAccentColor

        outputModeButton = NSButton(title: outputMode.label, target: self, action: #selector(toggleOutputMode(_:)))
        outputModeButton.bezelStyle = .rounded
        outputModeButton.controlSize = .mini
        outputModeButton.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        outputModeButton.setButtonType(.momentaryPushIn)
        outputModeButton.setContentHuggingPriority(.required, for: .horizontal)

        sourceButton = NSButton(title: digitSource.label, target: self, action: #selector(toggleSource(_:)))
        sourceButton.bezelStyle = .rounded
        sourceButton.controlSize = .mini
        sourceButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        sourceButton.setButtonType(.momentaryPushIn)
        sourceButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [logo, outputModeButton, sourceButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        container.addSubview(effectView)
        
        // Wrap in ChromeView for drag support
        chromeView = ChromeView(frame: container.bounds)
        chromeView.panel = self
        chromeView.autoresizingMask = [.width, .height]
        chromeView.wantsLayer = true
        chromeView.layer?.backgroundColor = NSColor.clear.cgColor
        chromeView.addSubview(container)
        container.autoresizingMask = [.width, .height]
        
        contentView = chromeView
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        applyAppearance()
        refreshLabels()
    }

    @objc private func toggleSource(_ sender: Any?) {
        digitSource.toggle()
        onDigitSourceChanged?(digitSource)
        NSLog("[CKC] digitSource → %@", digitSource.rawValue)
    }

    @objc private func toggleOutputMode(_ sender: Any?) {
        outputMode.toggle()
        onOutputModeChanged?(outputMode)
        NSLog("[CKC] outputMode → %@", outputMode.rawValue)
    }

    func toggleDigitSource() {
        digitSource.toggle()
        onDigitSourceChanged?(digitSource)
    }

    func setDigitSource(_ source: DigitSource) {
        digitSource = source
        onDigitSourceChanged?(digitSource)
    }

    private func refreshLabels() {
        sourceButton?.title = digitSource.label
        outputModeButton?.title = outputMode.label
    }

    private func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectView.appearance = NSApp.effectiveAppearance
        effectView.material = dark ? .hudWindow : .popover
    }

    // MARK: - Position (default / persist / clamp)

    private func defaultOrigin() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(
            x: visible.midX - stripWidth / 2,
            y: visible.minY + 24
        )
    }

    private func savedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXKey) != nil,
              defaults.object(forKey: Self.originYKey) != nil else {
            return nil
        }
        return NSPoint(
            x: defaults.double(forKey: Self.originXKey),
            y: defaults.double(forKey: Self.originYKey)
        )
    }

    private func persistOrigin(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: Self.originXKey)
        defaults.set(Double(origin.y), forKey: Self.originYKey)
    }

    /// Keep the strip fully inside some screen's visible frame (prefer the one containing the center).
    private func clampedOrigin(_ origin: NSPoint) -> NSPoint {
        let size = NSSize(width: stripWidth, height: stripHeight)
        var frame = NSRect(origin: origin, size: size)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return origin }

        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = screens.first(where: { $0.frame.contains(center) })
            ?? screens.max(by: { a, b in
                a.visibleFrame.intersection(frame).area < b.visibleFrame.intersection(frame).area
            })
            ?? screens[0]
        let visible = screen.visibleFrame

        if frame.width > visible.width {
            frame.origin.x = visible.midX - frame.width / 2
        } else {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        }
        if frame.height > visible.height {
            frame.origin.y = visible.midY - frame.height / 2
        } else {
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        return frame.origin
    }

    private func placeUsingSavedOrDefault() {
        let origin = clampedOrigin(savedOrigin() ?? defaultOrigin())
        setFrame(NSRect(origin: origin, size: NSSize(width: stripWidth, height: stripHeight)), display: true)
    }

    // MARK: - Drag (from ChromeView)

    func beginDrag(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = frame.origin
        NSCursor.closedHand.push()
    }

    func continueDrag(with event: NSEvent) {
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        let next = clampedOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        setFrameOrigin(next)
    }

    func endDrag(with event: NSEvent) {
        if dragStartMouse != nil {
            NSCursor.pop()
        }
        dragStartMouse = nil
        dragStartOrigin = nil
        let origin = clampedOrigin(frame.origin)
        if origin != frame.origin {
            setFrameOrigin(origin)
        }
        persistOrigin(origin)
        NSLog("[CKC] StatusConsole origin saved (%.0f, %.0f)", origin.x, origin.y)
    }

    func showNearScreenBottom() {
        applyAppearance()
        placeUsingSavedOrDefault()
        orderFrontRegardless()
    }

    func show(near client: AnyObject?) {
        applyAppearance()
        // Restore last dragged position (or bottom-center default); ignore caret for the strip.
        placeUsingSavedOrDefault()
        orderFrontRegardless()
    }

    func hide() {
        // Persist current origin before hiding so relaunch/activate restores it.
        let origin = frame.origin
        if origin != .zero || savedOrigin() != nil {
            persistOrigin(clampedOrigin(origin))
        }
        orderOut(nil)
    }

    /// Content view that claims clicks on empty chrome / labels so the panel can drag,
    /// while leaving NSControl (buttons) hit-testing alone for normal clicks.
    private final class ChromeView: NSView {
        weak var panel: StatusConsole?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            // Keep real controls clickable; everything else (labels, stack, effect, chrome) drags.
            var v: NSView? = hit
            while let cur = v {
                if cur is NSControl { return hit }
                v = cur.superview
            }
            return self
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            guard let panel = panel, let window = window else { return }
            panel.beginDrag(with: event)
            // Track until mouse-up so drag continues off the strip.
            var tracking = true
            while tracking {
                guard let next = window.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                ) else { break }
                switch next.type {
                case .leftMouseDragged:
                    panel.continueDrag(with: next)
                case .leftMouseUp:
                    panel.endDrag(with: next)
                    tracking = false
                default:
                    break
                }
            }
        }
    }
}

private extension NSRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
