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
    /// Default width when nothing persisted: grip + 縱 · 繁/簡 · 小鍵盤/鍵盤 · 光/錨 + BR resize.
    private static let defaultStripWidth: CGFloat = 220
    private static let minStripWidth: CGFloat = 180
    private static let maxStripWidth: CGFloat = 420
    /// Floor/ceiling wide enough for Default and Large menu-bar text without clipping.
    private static let minStripHeight: CGFloat = 28
    private static let maxStripHeight: CGFloat = 56

    /// Live size (persisted). Width-first resize; height optional within tight bounds.
    private var stripWidth: CGFloat = StatusConsole.defaultStripWidth
    private var stripHeight: CGFloat = StatusConsole.preferredStripHeight()
    private var logoLabel: NSTextField!

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

    private static func loadPersistedHeight() -> CGFloat {
        let defaults = UserDefaults.standard
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

    /// Strip height from live menu-bar metrics + rounded-bezel padding.
    private static func preferredStripHeight(for font: NSFont = NSFont.menuBarFont(ofSize: 0)) -> CGFloat {
        let line = ceil(font.ascender - font.descender + font.leading)
        let raw = line + 14
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

        logoLabel = NSTextField(labelWithString: "縱")
        logoLabel.textColor = .controlAccentColor

        outputModeButton = NSButton(title: outputMode.label, target: self, action: #selector(toggleOutputMode(_:)))
        outputModeButton.bezelStyle = .rounded
        outputModeButton.setButtonType(.momentaryPushIn)
        outputModeButton.setContentHuggingPriority(.required, for: .horizontal)

        sourceButton = NSButton(title: digitSource.label, target: self, action: #selector(toggleSource(_:)))
        sourceButton.bezelStyle = .rounded
        sourceButton.setButtonType(.momentaryPushIn)
        sourceButton.setContentHuggingPriority(.required, for: .horizontal)

        anchorButton = NSButton(title: candidateAnchor.label, target: self, action: #selector(toggleAnchor(_:)))
        anchorButton.bezelStyle = .rounded
        anchorButton.setButtonType(.momentaryPushIn)
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

        let stack = NSStackView(views: [logoLabel, outputModeButton, sourceButton, anchorButton])
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
        observeMenuBarChromeChanges()
    }

    /// Re-read NSFont.menuBarFont(ofSize: 0) for every chrome label/button.
    private func applyChromeFonts() {
        let menu = NSFont.menuBarFont(ofSize: 0)
        let control = Self.chromeControlSize(for: menu)
        logoLabel?.font = Self.menuBarChromeFont(weight: .bold)
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
    }

    private func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectView.appearance = NSApp.effectiveAppearance
        effectView.material = dark ? .hudWindow : .popover

        // Soft layer glow on outer chrome (not NSPanel.hasShadow — that leaks black corners).
        // Thin border on the clipped rounded container so the edge reads as a "shadow border".
        // IMPORTANT: always set a rounded shadowPath. Without it, Core Animation casts from the
        // rectangular chrome bounds and leaves a light semi-transparent square haze outside the
        // rounded strip (especially visible at the right corners on dark backgrounds).
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
        // Keep vibrancy + glow path in sync with the rounded container.
        effectView?.layer?.cornerRadius = cornerRadius
        effectView?.layer?.masksToBounds = true
        updateChromeShadowPath()
        gripView?.needsDisplay = true
        resizeGripView?.needsDisplay = true
    }

    /// Rounded shadow path matching the strip — prevents rectangular white/black glow haze.
    private func updateChromeShadowPath() {
        guard let chromeView = chromeView, let chromeLayer = chromeView.layer else { return }
        let bounds = chromeView.bounds
        guard bounds.width > 0.5, bounds.height > 0.5 else {
            chromeLayer.shadowPath = nil
            return
        }
        chromeLayer.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
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
