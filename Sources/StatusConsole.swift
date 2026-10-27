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
/// Shows 縱 on/off · 繁/簡 · digit-source (小鍵盤/鍵盤) · candidate anchor (光/錨).
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

    /// Master compose gate. On (default): CKC compose works. Off: keys pass through as a normal keyboard.
    private(set) var ckcEnabled: Bool = true {
        didSet { refreshLabels(); UserDefaults.standard.set(ckcEnabled, forKey: Self.ckcEnabledKey) }
    }

    var onDigitSourceChanged: ((DigitSource) -> Void)?
    var onOutputModeChanged: ((OutputMode) -> Void)?
    var onCandidateAnchorChanged: ((CandidateAnchor) -> Void)?
    var onCkcEnabledChanged: ((Bool) -> Void)?

    private static let digitSourceKey = "ckc.digitSource"
    private static let outputModeKey = "ckc.outputMode"
    private static let candidateAnchorKey = "ckc.candidateAnchor"
    private static let ckcEnabledKey = "ckc.ckcEnabled"
    private static let originXKey = "ckc.statusConsole.originX"
    private static let originYKey = "ckc.statusConsole.originY"

    // Shared across all IMK controller instances. Per-instance DispatchWorkItem
    // cannot cancel another controller's pending hide (Notes/Messages/Chrome churn).
    private static var pendingHideWork: DispatchWorkItem?
    private static var hideGeneration: UInt64 = 0
    private static let hideDelay: TimeInterval = 0.30

    private static let widthKey = "ckc.statusConsole.width"
    private static let heightKey = "ckc.statusConsole.height"

    private var effectView: NSVisualEffectView!
    private var chromeView: ChromeView!
    /// Clipped rounded container (cornerRadius + masksToBounds). Border lives here.
    private var containerView: NSView!
    private var sourceButton: NSButton!
    private var outputModeButton: NSButton!
    private var anchorButton: NSButton!
    private var gripView: DragGripView!
    private var resizeGripView: ResizeGripView!
    private let cornerRadius: CGFloat = 12
    /// Default width when nothing persisted: grip + 縱 on/off · 繁/簡 · 小鍵盤/鍵盤 · 光/錨 + BR resize.
    private static let defaultStripWidth: CGFloat = 220
    private static let minStripWidth: CGFloat = 180
    private static let maxStripWidth: CGFloat = 420
    /// Floor/ceiling wide enough for Default and Large menu-bar text without clipping.
    /// Floor tracks chrome around raised buttons (see preferredStripHeight).
    private static let minStripHeight: CGFloat = 26
    private static let maxStripHeight: CGFloat = 56

    /// Live size (persisted). Width-first resize; height optional within tight bounds.
    private var stripWidth: CGFloat = StatusConsole.defaultStripWidth
    private var stripHeight: CGFloat = StatusConsole.preferredStripHeight()
    private var ckcEnabledButton: NSButton!

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var resizeStartMouse: NSPoint?
    private var resizeStartSize: NSSize?

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

        // bool(forKey:) is false when missing — only override default (true) when key exists.
        if UserDefaults.standard.object(forKey: Self.ckcEnabledKey) != nil {
            ckcEnabled = UserDefaults.standard.bool(forKey: Self.ckcEnabledKey)
        }

        stripWidth = Self.loadPersistedWidth()
        stripHeight = Self.loadPersistedHeight()

        buildUI()
        orderOut(nil)
    }

    private static func loadPersistedWidth() -> CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: widthKey) != nil else { return defaultStripWidth }
        let w = CGFloat(defaults.double(forKey: widthKey))
        return min(max(w, minStripWidth), maxStripWidth)
    }

    private static let heightChromeKey = "ckc.statusConsole.heightChrome"
    /// Bump when default vertical chrome changes so older taller persisted heights reset.
    private static let heightChromeToken = "tight-0.2.33"

    private static func loadPersistedHeight() -> CGFloat {
        let defaults = UserDefaults.standard
        // One-shot: drop auto/older tall heights after chrome tighten (keeps width).
        if defaults.string(forKey: heightChromeKey) != heightChromeToken {
            defaults.removeObject(forKey: heightKey)
            defaults.set(heightChromeToken, forKey: heightChromeKey)
        }
        let preferred = preferredStripHeight()
        guard defaults.object(forKey: heightKey) != nil else { return preferred }
        let h = CGFloat(defaults.double(forKey: heightKey))
        // Never shrink below what the live menu-bar font needs (raises older short strips).
        return min(max(max(h, preferred), minStripHeight), maxStripHeight)
    }

    /// System Settings menu-bar font. `ofSize: 0` reads the live menu bar text size.
    private static func menuBarChromeFont(weight: NSFont.Weight = .regular) -> NSFont {
        let menu = NSFont.menuBarFont(ofSize: 0)
        guard weight != .regular else { return menu }
        return NSFont.systemFont(ofSize: menu.pointSize, weight: weight)
    }

    /// Strip height from live menu-bar metrics + chrome above/below buttons.
    /// Middle ground: was +14 (roomy) then +8 (too tight); +10 gives a little air without the old tall strip.
    private static func preferredStripHeight(for font: NSFont = NSFont.menuBarFont(ofSize: 0)) -> CGFloat {
        let line = ceil(font.ascender - font.descender + font.leading)
        let raw = line + 10
        return min(max(raw, minStripHeight), maxStripHeight)
    }

    private static func chromeControlSize(for font: NSFont) -> NSControl.ControlSize {
        if font.pointSize >= 15 { return .regular }
        if font.pointSize >= 12 { return .small }
        return .mini
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
        // Vibrancy often ignores a parent clip; round-mask the effect view itself too.
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.backgroundColor = NSColor.clear.cgColor
        effectView.autoresizingMask = [.width, .height]

        ckcEnabledButton = RaisedChromeButton(title: "縱", target: self, action: #selector(toggleCkcEnabled(_:)))
        ckcEnabledButton.setContentHuggingPriority(.required, for: .horizontal)
        ckcEnabledButton.toolTip = "縱橫輸入開／關（關閉後為一般鍵盤）"

        outputModeButton = RaisedChromeButton(title: outputMode.label, target: self, action: #selector(toggleOutputMode(_:)))
        outputModeButton.setContentHuggingPriority(.required, for: .horizontal)

        sourceButton = RaisedChromeButton(title: digitSource.label, target: self, action: #selector(toggleSource(_:)))
        sourceButton.setContentHuggingPriority(.required, for: .horizontal)

        anchorButton = RaisedChromeButton(title: candidateAnchor.label, target: self, action: #selector(toggleAnchor(_:)))
        anchorButton.setContentHuggingPriority(.required, for: .horizontal)
        anchorButton.toolTip = candidateAnchor.toolTip

        applyChromeFonts()

        gripView = DragGripView(frame: .zero)
        gripView.panel = self
        gripView.translatesAutoresizingMaskIntoConstraints = false
        gripView.toolTip = "拖曳移動狀態列"

        resizeGripView = ResizeGripView(frame: .zero)
        resizeGripView.panel = self
        resizeGripView.translatesAutoresizingMaskIntoConstraints = false
        resizeGripView.toolTip = "拖曳調整狀態列寬度"

        let stack = NSStackView(views: [ckcEnabledButton, outputModeButton, sourceButton, anchorButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(gripView)
        effectView.addSubview(stack)
        effectView.addSubview(resizeGripView)
        NSLayoutConstraint.activate([
            gripView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 4),
            gripView.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            gripView.widthAnchor.constraint(equalToConstant: 14),
            gripView.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: gripView.trailingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: resizeGripView.leadingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            resizeGripView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -2),
            resizeGripView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -2),
            resizeGripView.widthAnchor.constraint(equalToConstant: 14),
            resizeGripView.heightAnchor.constraint(equalToConstant: 14),
        ])

        container.addSubview(effectView)
        containerView = container

        // Wrap in ChromeView for drag support. No outer glow (glow caused
        // rectangular haze); container below holds the clipped rounded border.
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
        observeMenuBarChromeChanges()
    }

    /// Re-read NSFont.menuBarFont(ofSize: 0) for every chrome label/button.
    private func applyChromeFonts() {
        let menu = NSFont.menuBarFont(ofSize: 0)
        let control = Self.chromeControlSize(for: menu)
        ckcEnabledButton?.font = Self.menuBarChromeFont(weight: .bold)
        ckcEnabledButton?.controlSize = control
        outputModeButton?.font = Self.menuBarChromeFont(weight: .semibold)
        outputModeButton?.controlSize = control
        sourceButton?.font = Self.menuBarChromeFont(weight: .medium)
        sourceButton?.controlSize = control
        anchorButton?.font = Self.menuBarChromeFont(weight: .semibold)
        anchorButton?.controlSize = control
    }

    /// Grow strip if current height would clip the live menu-bar glyphs.
    private func ensureStripFitsMenuBarFont() {
        applyChromeFonts()
        let needed = Self.preferredStripHeight()
        guard stripHeight + 0.5 < needed else { return }
        let heightDelta = needed - stripHeight
        stripHeight = needed
        var origin = frame.origin
        origin.y -= heightDelta
        origin = clampedOrigin(origin)
        setFrame(NSRect(origin: origin, size: NSSize(width: stripWidth, height: stripHeight)), display: true)
        updateChromeShadowPath()
        persistSize(currentSize())
    }

    private func observeMenuBarChromeChanges() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(systemChromeMetricsMayHaveChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(systemChromeMetricsMayHaveChanged(_:)),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func systemChromeMetricsMayHaveChanged(_ notification: Notification?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.ensureStripFitsMenuBarFont()
            self.applyAppearance()
        }
    }

    @objc private func toggleCkcEnabled(_ sender: Any?) {
        ckcEnabled.toggle()
        onCkcEnabledChanged?(ckcEnabled)
        NSLog("[CKC] ckcEnabled → %d", ckcEnabled ? 1 : 0)
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
        applyChromeFonts()
        sourceButton?.title = digitSource.label
        outputModeButton?.title = outputMode.label
        anchorButton?.title = candidateAnchor.label
        anchorButton?.toolTip = candidateAnchor.toolTip
        applyCkcEnabledChrome()
    }

    /// On = bright LED blue; Off = dim LED blue (same hue, unlit).
    private func applyCkcEnabledChrome() {
        guard let button = ckcEnabledButton else { return }
        let color = ckcEnabled ? Self.ckcEnabledOnColor : Self.ckcEnabledOffColor
        let font = button.font ?? Self.menuBarChromeFont(weight: .bold)
        button.attributedTitle = NSAttributedString(
            string: "縱",
            attributes: [
                .foregroundColor: color,
                .font: font,
            ]
        )
        button.toolTip = ckcEnabled
            ? "縱橫輸入：開（點擊關閉，變為一般鍵盤）"
            : "縱橫輸入：關（點擊開啟組成）"
        if #available(macOS 10.14, *) {
            button.contentTintColor = color
        }
        button.needsDisplay = true
    }

    /// Bright LED blue — vivid electric/cyan, punchier than default controlAccentColor.
    private static var ckcEnabledOnColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if dark {
                // Lit LED on dark HUD (~ sRGB 0.30, 0.78, 1.00)
                return NSColor(srgbRed: 0.30, green: 0.78, blue: 1.00, alpha: 1)
            }
            // Lit LED on light (~ sRGB 0.05, 0.52, 0.98)
            return NSColor(srgbRed: 0.05, green: 0.52, blue: 0.98, alpha: 1)
        }
    }

    /// Dim LED blue — same hue family as on-state, unlit/dim (not plain gray).
    private static var ckcEnabledOffColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if dark {
                // Dim LED on dark (~ sRGB 0.26, 0.40, 0.58)
                return NSColor(srgbRed: 0.26, green: 0.40, blue: 0.58, alpha: 1)
            }
            // Dim LED on light (~ sRGB 0.28, 0.40, 0.56)
            return NSColor(srgbRed: 0.28, green: 0.40, blue: 0.56, alpha: 1)
        }
    }

    private func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectView.appearance = NSApp.effectiveAppearance
        effectView.material = dark ? .hudWindow : .popover

        // No soft outer glow. A white CALayer shadow (even with rounded shadowPath) still
        // blurs into a light rectangular haze around the pill on dark backgrounds — that
        // was the remaining console-corner haze. Visibility comes from the thin border on
        // the clipped rounded container instead (same pattern as CandidateWindow).
        if let chromeLayer = chromeView?.layer {
            chromeLayer.masksToBounds = false
            chromeLayer.shadowOpacity = 0
            chromeLayer.shadowRadius = 0
            chromeLayer.shadowOffset = .zero
            chromeLayer.shadowPath = nil
            chromeLayer.shadowColor = nil
        }
        if let containerLayer = containerView?.layer {
            containerLayer.cornerRadius = cornerRadius
            containerLayer.masksToBounds = true
            if #available(macOS 10.15, *) {
                containerLayer.cornerCurve = .continuous
            }
            containerLayer.borderWidth = 1.0
            if dark {
                containerLayer.borderColor = NSColor.white.withAlphaComponent(0.38).cgColor
            } else {
                containerLayer.borderColor = NSColor.black.withAlphaComponent(0.20).cgColor
            }
        }
        // Vibrancy must round-mask itself; parent clip alone is not enough.
        effectView?.layer?.cornerRadius = cornerRadius
        effectView?.layer?.masksToBounds = true
        if #available(macOS 10.15, *), let effectLayer = effectView?.layer {
            effectLayer.cornerCurve = .continuous
        }
        gripView?.needsDisplay = true
        resizeGripView?.needsDisplay = true
        ckcEnabledButton?.needsDisplay = true
        outputModeButton?.needsDisplay = true
        sourceButton?.needsDisplay = true
        anchorButton?.needsDisplay = true
    }

    /// Kept as a no-op refresh hook so resize/show call sites stay valid if a
    /// non-rectangular shadow is ever reintroduced. Currently clears any leftover path.
    private func updateChromeShadowPath() {
        guard let chromeLayer = chromeView?.layer else { return }
        chromeLayer.shadowOpacity = 0
        chromeLayer.shadowPath = nil
    }

    // MARK: - Position (default / persist / clamp)

    private func currentSize() -> NSSize {
        NSSize(width: stripWidth, height: stripHeight)
    }

    private func defaultOrigin() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = currentSize()
        return NSPoint(
            x: visible.midX - size.width / 2,
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

    private func persistSize(_ size: NSSize) {
        let defaults = UserDefaults.standard
        defaults.set(Double(size.width), forKey: Self.widthKey)
        defaults.set(Double(size.height), forKey: Self.heightKey)
    }

    /// Keep the strip fully inside some screen's visible frame (prefer the one containing the center).
    /// Uses the **current** persisted/live size, not a fixed constant.
    private func clampedOrigin(_ origin: NSPoint) -> NSPoint {
        let size = currentSize()
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
        let size = currentSize()
        let origin = clampedOrigin(savedOrigin() ?? defaultOrigin())
        setFrame(NSRect(origin: origin, size: size), display: true)
        updateChromeShadowPath()
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

    // MARK: - Resize (from ResizeGripView, BR corner)

    func beginResize(with event: NSEvent) {
        resizeStartMouse = NSEvent.mouseLocation
        resizeStartSize = frame.size
        NSCursor.resizeLeftRight.push()
    }

    func continueResize(with event: NSEvent) {
        guard let startMouse = resizeStartMouse, let startSize = resizeStartSize else { return }
        let mouse = NSEvent.mouseLocation
        // Width-first: horizontal delta drives width. Small vertical delta optionally tweaks height.
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y  // AppKit: up is positive; dragging BR down decreases y → negative
        let nextW = min(max(startSize.width + dx, Self.minStripWidth), Self.maxStripWidth)
        // Prefer keeping height unless user clearly drags vertically.
        var nextH = startSize.height
        if abs(dy) > 4 {
            // Dragging down (mouse.y decreases) → grow height slightly so BR corner follows finger.
            nextH = min(max(startSize.height - dy, Self.minStripHeight), Self.maxStripHeight)
        }
        stripWidth = nextW
        stripHeight = nextH
        // Pin top-left (origin.x, origin.y+height) while growing from BR: adjust origin.y when height changes.
        let heightDelta = nextH - frame.height
        var origin = frame.origin
        origin.y -= heightDelta
        origin = clampedOrigin(origin)
        setFrame(NSRect(origin: origin, size: NSSize(width: nextW, height: nextH)), display: true)
        updateChromeShadowPath()
    }

    func endResize(with event: NSEvent) {
        if resizeStartMouse != nil {
            NSCursor.pop()
        }
        resizeStartMouse = nil
        resizeStartSize = nil
        let size = currentSize()
        let origin = clampedOrigin(frame.origin)
        setFrame(NSRect(origin: origin, size: size), display: true)
        updateChromeShadowPath()
        persistOrigin(origin)
        persistSize(size)
        if candidateAnchor == .console {
            CandidateWindow.shared.repositionForCurrentAnchor()
        }
        NSLog("[CKC] StatusConsole size saved (%.0f × %.0f) origin (%.0f, %.0f)",
              size.width, size.height, origin.x, origin.y)
    }

    // MARK: - Shared deferred hide

    /// Append one line to /tmp/ckc-ime.log (unified log often redacts NSLog).
    private static func ckcLog(_ message: String) {
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

    /// Cancel any pending hide from ANY controller instance.
    func cancelPendingHide() {
        Self.pendingHideWork?.cancel()
        Self.pendingHideWork = nil
        Self.hideGeneration &+= 1
    }

    /// Schedule hide; only the matching generation may call hide().
    func scheduleDeferredHide(clientBundle: String) {
        cancelPendingHide()
        let gen = Self.hideGeneration
        let delay = Self.hideDelay
        let work = DispatchWorkItem {
            guard gen == Self.hideGeneration else { return }
            Self.ckcLog("StatusConsole deferred-hide fire client=\(clientBundle)")
            StatusConsole.shared.hide()
            Self.pendingHideWork = nil
        }
        Self.pendingHideWork = work
        Self.ckcLog("StatusConsole schedule-deferred-hide delay=\(delay) client=\(clientBundle)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func showNearScreenBottom() {
        cancelPendingHide()
        ensureStripFitsMenuBarFont()
        applyAppearance()
        placeUsingSavedOrDefault()
        orderFrontRegardless()
    }

    func show(near client: AnyObject?) {
        cancelPendingHide()
        ensureStripFitsMenuBarFont()
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

    /// Raised 3D chrome button for StatusConsole strip.
    /// Idle = beveled/raised; mouse-down = pressed-in (darker fill + title nudge).
    private final class RaisedChromeButton: NSButton {
        private let cornerRadius: CGFloat = 6

        convenience init(title: String, target: AnyObject?, action: Selector?) {
            self.init(frame: .zero)
            self.title = title
            self.target = target
            self.action = action
            commonInit()
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            commonInit()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            commonInit()
        }

        private func commonInit() {
            bezelStyle = .shadowlessSquare
            setButtonType(.momentaryPushIn)
            isBordered = false
            isTransparent = false
            wantsLayer = false
            focusRingType = .none
        }

        override var intrinsicContentSize: NSSize {
            let base = super.intrinsicContentSize
            // Extra padding so the bevel reads around the glyph/label.
            return NSSize(width: max(base.width + 10, 28), height: max(base.height + 4, 22))
        }

        override var isHighlighted: Bool {
            didSet { needsDisplay = true }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let window = window else { return }
            highlight(true)
            needsDisplay = true
            var tracking = true
            while tracking {
                guard let next = window.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                ) else { break }
                let local = convert(next.locationInWindow, from: nil)
                let inside = bounds.contains(local)
                switch next.type {
                case .leftMouseDragged:
                    if isHighlighted != inside {
                        highlight(inside)
                        needsDisplay = true
                    }
                case .leftMouseUp:
                    highlight(false)
                    needsDisplay = true
                    if inside {
                        sendAction(action, to: target)
                    }
                    tracking = false
                default:
                    break
                }
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let pressed = isHighlighted
            let insetBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: insetBounds, xRadius: cornerRadius, yRadius: cornerRadius)

            // Face fill: raised lighter, pressed darker / inset.
            let fill: NSColor
            if pressed {
                fill = dark
                    ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.92)
                    : NSColor(srgbRed: 0.72, green: 0.74, blue: 0.78, alpha: 0.95)
            } else {
                fill = dark
                    ? NSColor(srgbRed: 0.22, green: 0.24, blue: 0.30, alpha: 0.92)
                    : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 0.95)
            }
            fill.setFill()
            path.fill()

            // Bevel edges drawn inside bounds (parent masksToBounds would clip layer shadows).
            let topEdge = pressed
                ? (dark ? NSColor.black.withAlphaComponent(0.45) : NSColor.black.withAlphaComponent(0.22))
                : (dark ? NSColor.white.withAlphaComponent(0.42) : NSColor.white.withAlphaComponent(0.95))
            let bottomEdge = pressed
                ? (dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.35))
                : (dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.22))
            let sideEdge = dark
                ? NSColor.white.withAlphaComponent(pressed ? 0.08 : 0.16)
                : NSColor.black.withAlphaComponent(pressed ? 0.10 : 0.12)

            let clip = NSBezierPath(roundedRect: insetBounds, xRadius: cornerRadius, yRadius: cornerRadius)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()

            // Top highlight (raised) or top shade (pressed).
            let top = NSBezierPath()
            top.move(to: NSPoint(x: insetBounds.minX + 2, y: insetBounds.maxY - 1))
            top.line(to: NSPoint(x: insetBounds.maxX - 2, y: insetBounds.maxY - 1))
            top.lineWidth = pressed ? 1.0 : 1.25
            topEdge.setStroke()
            top.stroke()

            // Bottom shade (raised) or bottom lift (pressed inset).
            let bottom = NSBezierPath()
            bottom.move(to: NSPoint(x: insetBounds.minX + 2, y: insetBounds.minY + 1))
            bottom.line(to: NSPoint(x: insetBounds.maxX - 2, y: insetBounds.minY + 1))
            bottom.lineWidth = pressed ? 1.0 : 1.25
            bottomEdge.setStroke()
            bottom.stroke()

            NSGraphicsContext.restoreGraphicsState()

            // Outer rim
            sideEdge.setStroke()
            path.lineWidth = 1.0
            path.stroke()

            // Title — nudge down 1pt while pressed for tactile sink.
            let drawTitle: NSAttributedString
            if attributedTitle.length > 0 {
                drawTitle = attributedTitle
            } else {
                let color = dark ? NSColor.labelColor : NSColor.labelColor
                let fontToUse = font ?? NSFont.menuBarFont(ofSize: 0)
                drawTitle = NSAttributedString(
                    string: title,
                    attributes: [
                        .foregroundColor: color,
                        .font: fontToUse,
                    ]
                )
            }
            let titleSize = drawTitle.size()
            let titleOrigin = NSPoint(
                x: bounds.midX - titleSize.width / 2,
                y: bounds.midY - titleSize.height / 2 + (pressed ? -1.0 : 0.5)
            )
            drawTitle.draw(at: titleOrigin)
        }
    }

    /// Hosts the vibrancy chrome (no outer layer shadow). Drag is owned only by
    /// DragGripView so 繁/簡 / 鍵盤 / 錨 buttons never fight mouse tracking.
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

    /// Airport-board style BR resize grip: diagonal hatch lines (tertiary label color).
    /// Dedicated resize-only zone — does not fight left DragGripView or 繁/簡 / 鍵盤 / 光/錨 buttons.
    private final class ResizeGripView: NSView {
        weak var panel: StatusConsole?

        override var isOpaque: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color = (dark
                ? NSColor.tertiaryLabelColor.withAlphaComponent(0.90)
                : NSColor.tertiaryLabelColor.withAlphaComponent(0.75))
            color.setStroke()

            // Three short diagonal lines in the BR corner (NW→SE hatch), like ATC FIDS resize.
            let inset: CGFloat = 1.5
            let path = NSBezierPath()
            path.lineWidth = 1.25
            path.lineCapStyle = .round
            let offsets: [CGFloat] = [3.5, 6.5, 9.5]
            for o in offsets {
                // Lines parallel to the SE diagonal, anchored near bottom-right.
                let x0 = bounds.maxX - inset - o
                let y0 = bounds.minY + inset
                let x1 = bounds.maxX - inset
                let y1 = bounds.minY + inset + o
                guard x0 >= bounds.minX - 0.5 else { continue }
                path.move(to: NSPoint(x: x0, y: y0))
                path.line(to: NSPoint(x: x1, y: y1))
            }
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            guard let panel = panel, let window = window else { return }
            panel.beginResize(with: event)
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
                    panel.continueResize(with: next)
                case .leftMouseUp:
                    panel.endResize(with: next)
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
