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


/// Where the candidate popup anchors: IMK caret (default) or above the StatusConsole strip.
/// Console-follow helps Google Docs/Chrome where caret rects are unreliable.
enum CandidateAnchor: String {
    case caret
    case console

    var label: String {
        switch self {
        case .caret: return "光"
        case .console: return "錨"
        }
    }

    var toolTip: String {
        switch self {
        case .caret: return "候選跟隨游標（點擊切換為跟隨狀態列）"
        case .console: return "候選跟隨狀態列（點擊切換為跟隨游標）"
        }
    }

    mutating func toggle() {
        self = (self == .caret) ? .console : .caret
    }
}

/// Compact modern floating status strip (vibrancy HUD).
/// Shows logo · 繁/簡 · digit-source (小鍵盤/鍵盤) · candidate anchor (光/錨).
/// Drag empty chrome / labels to reposition; buttons keep normal clicks.
final class StatusConsole: NSPanel {
    static let shared = StatusConsole()

    private(set) var digitSource: DigitSource = .numpad {
        didSet { refreshLabels(); UserDefaults.standard.set(digitSource.rawValue, forKey: Self.digitSourceKey) }
    }

    private(set) var outputMode: OutputMode = .traditional {
        didSet { refreshLabels(); UserDefaults.standard.set(outputMode.rawValue, forKey: Self.outputModeKey) }
    }

    private(set) var candidateAnchor: CandidateAnchor = .caret {
        didSet { refreshLabels(); UserDefaults.standard.set(candidateAnchor.rawValue, forKey: Self.candidateAnchorKey) }
    }

    var onDigitSourceChanged: ((DigitSource) -> Void)?
    var onOutputModeChanged: ((OutputMode) -> Void)?
    var onCandidateAnchorChanged: ((CandidateAnchor) -> Void)?

    private static let digitSourceKey = "ckc.digitSource"
    private static let outputModeKey = "ckc.outputMode"
    private static let candidateAnchorKey = "ckc.candidateAnchor"
    private static let originXKey = "ckc.statusConsole.originX"
    private static let originYKey = "ckc.statusConsole.originY"

    private var effectView: NSVisualEffectView!
    private var chromeView: ChromeView!
    /// Clipped rounded container (cornerRadius + masksToBounds). Border lives here.
    private var containerView: NSView!
    private var sourceButton: NSButton!
    private var outputModeButton: NSButton!
    private var anchorButton: NSButton!
    private var gripView: DragGripView!
    private let cornerRadius: CGFloat = 12
    private let stripHeight: CGFloat = 26
    /// Grip (~14) + 縱 · 繁/簡 · 小鍵盤/鍵盤 · 光/錨
    private let stripWidth: CGFloat = 190

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

        if let raw = UserDefaults.standard.string(forKey: Self.candidateAnchorKey),
           let saved = CandidateAnchor(rawValue: raw) {
            candidateAnchor = saved
        }

        buildUI()
        orderOut(nil)
    }

    private func buildUI() {
        // Single container with rounded mask. Border is applied in applyAppearance()
        // on this same clipped layer so no sharp light corners escape the round rect.
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

        anchorButton = NSButton(title: candidateAnchor.label, target: self, action: #selector(toggleAnchor(_:)))
        anchorButton.bezelStyle = .rounded
        anchorButton.controlSize = .mini
        anchorButton.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        anchorButton.setButtonType(.momentaryPushIn)
        anchorButton.setContentHuggingPriority(.required, for: .horizontal)
        anchorButton.toolTip = candidateAnchor.toolTip

        gripView = DragGripView(frame: .zero)
        gripView.panel = self
        gripView.translatesAutoresizingMaskIntoConstraints = false
        gripView.toolTip = "拖曳移動狀態列"

        let stack = NSStackView(views: [logo, outputModeButton, sourceButton, anchorButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(gripView)
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            gripView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 4),
            gripView.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            gripView.widthAnchor.constraint(equalToConstant: 14),
            gripView.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: gripView.trailingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        container.addSubview(effectView)
        containerView = container

        // Wrap in ChromeView for drag support. Shadow lives on chromeView
        // (masksToBounds must stay false so the glow can extend outside).
        chromeView = ChromeView(frame: container.bounds)
        chromeView.panel = self
        chromeView.autoresizingMask = [.width, .height]
        chromeView.wantsLayer = true
        chromeView.layer?.backgroundColor = NSColor.clear.cgColor
        chromeView.layer?.masksToBounds = false
        chromeView.addSubview(container)
        container.autoresizingMask = [.width, .height]

        contentView = chromeView
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        contentView?.layer?.masksToBounds = false
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

    @objc private func toggleAnchor(_ sender: Any?) {
        candidateAnchor.toggle()
        onCandidateAnchorChanged?(candidateAnchor)
        NSLog("[CKC] candidateAnchor → %@ (follow-console=%d)",
              candidateAnchor.rawValue, candidateAnchor == .console ? 1 : 0)
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
        anchorButton?.title = candidateAnchor.label
        anchorButton?.toolTip = candidateAnchor.toolTip
    }

    private func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectView.appearance = NSApp.effectiveAppearance
        effectView.material = dark ? .hudWindow : .popover

        // Soft layer glow on outer chrome (not NSPanel.hasShadow — that leaks black corners).
        // Thin border on the clipped rounded container so the edge reads as a "shadow border".
        if let chromeLayer = chromeView?.layer {
            chromeLayer.masksToBounds = false
            chromeLayer.shadowOffset = .zero
            chromeLayer.shadowRadius = dark ? 10 : 8
            if dark {
                chromeLayer.shadowColor = NSColor.white.cgColor
                chromeLayer.shadowOpacity = 0.50
            } else {
                chromeLayer.shadowColor = NSColor.black.cgColor
                chromeLayer.shadowOpacity = 0.28
            }
        }
        if let containerLayer = containerView?.layer {
            containerLayer.cornerRadius = cornerRadius
            containerLayer.masksToBounds = true
            containerLayer.borderWidth = 0.75
            if dark {
                containerLayer.borderColor = NSColor.white.withAlphaComponent(0.42).cgColor
            } else {
                containerLayer.borderColor = NSColor.black.withAlphaComponent(0.22).cgColor
            }
        }
        gripView?.needsDisplay = true
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
        if candidateAnchor == .console {
            CandidateWindow.shared.repositionForCurrentAnchor()
        }
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
        if candidateAnchor == .console {
            CandidateWindow.shared.repositionForCurrentAnchor()
        }
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

    /// Hosts the vibrancy chrome + layer shadow. Drag is owned only by DragGripView
    /// so 繁/簡 / 鍵盤 / 錨 buttons never fight mouse tracking.
    private final class ChromeView: NSView {
        weak var panel: StatusConsole?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }

    /// Airport-board style left grip: 3×6 grid of small tertiary-label dots.
    /// Dedicated drag-only zone — mouseDown here moves the StatusConsole.
    private final class DragGripView: NSView {
        weak var panel: StatusConsole?

        private let columns = 3
        private let rows = 6
        private let dotRadius: CGFloat = 1.1

        override var isOpaque: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color = (dark
                ? NSColor.tertiaryLabelColor.withAlphaComponent(0.85)
                : NSColor.tertiaryLabelColor.withAlphaComponent(0.70))
            color.setFill()

            let padX: CGFloat = 2.0
            let padY: CGFloat = 1.5
            let usableW = max(1, bounds.width - padX * 2)
            let usableH = max(1, bounds.height - padY * 2)
            let stepX = usableW / CGFloat(columns - 1)
            let stepY = usableH / CGFloat(rows - 1)
            for col in 0..<columns {
                for row in 0..<rows {
                    let cx = padX + CGFloat(col) * stepX
                    let cy = padY + CGFloat(row) * stepY
                    let r = NSRect(
                        x: cx - dotRadius,
                        y: cy - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    NSBezierPath(ovalIn: r).fill()
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let panel = panel, let window = window else { return }
            panel.beginDrag(with: event)
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
