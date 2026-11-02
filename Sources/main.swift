import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

/// System-wide hotkey via Carbon (needs no Accessibility permission).
final class HotKey {
    private static var action: (() -> Void)?
    private var reference: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x474C_4D4E), id: 1),
                            GetApplicationEventTarget(), 0, &reference)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private let prefs = Prefs.shared
    private let panel = FloatingPanel()
    private let notifier = Notifier()
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var modifierTimer: Timer?
    private var visibilityTimer: Timer?
    private var hiddenForFullScreen = false
    private var statusItem: NSStatusItem?
    private var lastScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: RootView(m: monitor))
        host.sizingOptions = []
        panel.contentView = host
        place(animated: false)
        if prefs.hidden { showStatusItem() } else { panel.orderFrontRegardless() }

        // @Published fires before the value is stored, so re-place on the next runloop turn.
        let relayout = { [weak self] in DispatchQueue.main.async { self?.place(animated: true) } }
        monitor.$expanded.dropFirst().sink { [weak self] _ in relayout(); self?.updateMouseHandling() }.store(in: &cancellables)
        monitor.$alert.dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in relayout() }.store(in: &cancellables)
        prefs.$pillItems.dropFirst().sink { _ in relayout() }.store(in: &cancellables)
        prefs.$minimized.dropFirst().sink { _ in relayout() }.store(in: &cancellables)
        prefs.$hidden.dropFirst().removeDuplicates().sink { [weak self] hidden in
            DispatchQueue.main.async { self?.setHidden(hidden) }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place(animated: false) }
            .store(in: &cancellables)

        prefs.$opacity.sink { [weak self] in self?.panel.alphaValue = $0 }.store(in: &cancellables)
        prefs.$hideFromSharing.sink { [weak self] in self?.panel.sharingType = $0 ? .none : .readOnly }.store(in: &cancellables)
        prefs.$clickThrough.sink { [weak self] in self?.setClickThrough($0) }.store(in: &cancellables)

        monitor.onDrag = { [weak self] in self?.drag() }
        monitor.onDragEnd = { [weak self] in self?.endDrag() }
        monitor.onShutDown = { [weak self] in self?.shutDown() }
        monitor.onSnapToCorner = { [weak self] in
            self?.anchor = nil
            self?.cardAnchor = nil
            self?.place(animated: true)
        }

        notifier.setup()
        monitor.onAlert = { [weak self] in self?.notifier.post($0) }
        notifier.onQuit = { [weak self] pid in
            self?.monitor.kill(pid: pid, name: "process", force: false, key: "alert")
            self?.monitor.dismissAlert()
        }
        notifier.onIgnore = { [weak self] name in self?.monitor.ignore(processName: name) }
        notifier.onOpen = { [weak self] in withAnimation(.snappy(duration: 0.25)) { self?.monitor.expanded = true } }

        hotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: cmdKey | optionKey) { [weak self] in
            guard let self else { return }
            if prefs.hidden { prefs.hidden = false; return }
            if hiddenForFullScreen { panel.orderFrontRegardless() }
            withAnimation(.snappy(duration: 0.25)) { self.monitor.expanded.toggle() }
        }

        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updateFullScreenVisibility()
        }

        monitor.start()
        if CommandLine.arguments.contains("--expanded") { monitor.expanded = true }
        if let tab = CommandLine.arguments.first(where: { $0.hasPrefix("--tab=") })
            .flatMap({ ListTab(rawValue: String($0.dropFirst(6))) }) { monitor.tab = tab }
        if CommandLine.arguments.contains("--test-alert") { monitor.showTestAlert() }
        LoginItem.migrate()
        if CommandLine.arguments.contains("--register-login") { LoginItem.setEnabled(true) }
        if CommandLine.arguments.contains("--unregister-login") { LoginItem.setEnabled(false) }
        if CommandLine.arguments.contains("--shut-down") { DispatchQueue.main.async { self.shutDown() } }
        // Opened again after Shut Down: bring back Open at Login (the agent's copy then takes over).
        if UserDefaults.standard.bool(forKey: "shutDown") {
            UserDefaults.standard.removeObject(forKey: "shutDown")
            LoginItem.setEnabled(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.saveHistory()
    }

    /// Quits and stays off, also at login, until the user opens the app again.
    private func shutDown() {
        monitor.saveHistory()
        guard LoginItem.isEnabled else { return NSApp.terminate(nil) }
        UserDefaults.standard.set(true, forKey: "shutDown")
        LoginItem.setEnabled(false)
        NSApp.terminate(nil)
    }

    // MARK: Click-through

    private func setClickThrough(_ on: Bool) {
        modifierTimer?.invalidate()
        modifierTimer = nil
        if on {
            // Polling the modifier state needs no Accessibility permission, unlike a global event monitor.
            modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateMouseHandling()
            }
        }
        DispatchQueue.main.async { self.updateMouseHandling() }
    }

    private func updateMouseHandling() {
        let interactive = !prefs.clickThrough || monitor.expanded || NSEvent.modifierFlags.contains(.option)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    // MARK: Full-screen hiding

    private func updateFullScreenVisibility() {
        guard !prefs.hidden else { return }
        let hide = prefs.hideInFullScreen && !monitor.expanded && frontAppIsFullScreen()
        guard hide != hiddenForFullScreen else { return }
        hiddenForFullScreen = hide
        hide ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    // MARK: Hidden in the menu bar

    private func setHidden(_ hidden: Bool) {
        if hidden {
            monitor.expanded = false
            panel.orderOut(nil)
            showStatusItem()
        } else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            hiddenForFullScreen = false
            place(animated: false)
            panel.orderFrontRegardless()
        }
    }

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.menuBarIcon
        item.button?.toolTip = "Glass Monitor is hidden · click to show it · right-click for more"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else {
            prefs.hidden = false
            return
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Glass Monitor", action: #selector(menuShow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Panel  (⌥⌘M)", action: #selector(menuOpenPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Shut Down Glass Monitor", action: #selector(menuShutDown), keyEquivalent: "").target = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil // so the next left click shows the pill again instead of the menu
    }

    @objc private func menuShow() { prefs.hidden = false }
    @objc private func menuOpenPanel() {
        prefs.hidden = false
        DispatchQueue.main.async { withAnimation(.snappy(duration: 0.25)) { self.monitor.expanded = true } }
    }
    @objc private func menuShutDown() { shutDown() }

    /// Menu bar icon: a mini version of the app icon (gradient squircle, glass pill with three rings, pulse line),
    /// simplified so it stays crisp at 18 pt. Drawn as vectors, so it's sharp on Retina.
    private static let menuBarIcon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let squircle = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 17, height: 17), xRadius: 4.3, yRadius: 4.3)
        NSGradient(colors: [NSColor(red: 0.07, green: 0.09, blue: 0.20, alpha: 1),
                            NSColor(red: 0.10, green: 0.22, blue: 0.42, alpha: 1),
                            NSColor(red: 0.05, green: 0.42, blue: 0.52, alpha: 1)])!.draw(in: squircle, angle: 60)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        squircle.lineWidth = 0.6
        squircle.stroke()

        let pill = NSBezierPath(roundedRect: NSRect(x: 2.3, y: 8.6, width: 13.4, height: 5.8), xRadius: 2.9, yRadius: 2.9)
        NSColor.white.withAlphaComponent(0.22).setFill()
        pill.fill()
        for (i, color) in [NSColor.systemGreen, .systemOrange, .systemCyan].enumerated() {
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: 5.3 + Double(i) * 3.7, y: 11.5), radius: 1.45, startAngle: 0, endAngle: 360)
            ring.lineWidth = 1.1
            color.setStroke()
            ring.stroke()
        }

        let pulse = NSBezierPath()
        let points: [(Double, Double)] = [(1.5, 5.2), (6, 5.2), (7.2, 3.2), (8.6, 7.2), (10, 2.4), (11.2, 5.2), (16.5, 5.2)]
        pulse.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for p in points.dropFirst() { pulse.line(to: NSPoint(x: p.0, y: p.1)) }
        pulse.lineWidth = 1
        pulse.lineJoinStyle = .round
        pulse.lineCapStyle = .round
        NSColor(red: 0.45, green: 0.95, blue: 0.75, alpha: 0.9).setStroke()
        pulse.stroke()
        return true
    }

    /// True when the frontmost app has a window exactly covering the panel's screen (native or video full screen).
    private func frontAppIsFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let screen = lastScreen ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return false }
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == front,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.minX - target.minX) < 1 && abs(rect.minY - target.minY) < 1
                && abs(rect.width - target.width) < 1 && abs(rect.height - target.height) < 1
        }
    }

    // MARK: Placement

    /// Top-right corner of the panel in global screen coordinates; nil means "default corner".
    /// Anchoring on the top-right keeps the pill in place when it expands or collapses.
    private var anchor: NSPoint? {
        get { Self.point("anchor") }
        set { Self.setPoint(newValue, "anchor") }
    }

    /// Where the user dragged the minimized card (top-right corner); nil means "right edge, level with the pill".
    private var cardAnchor: NSPoint? {
        get { Self.point("card") }
        set { Self.setPoint(newValue, "card") }
    }

    private static func point(_ key: String) -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: key + "X") != nil else { return nil }
        return NSPoint(x: d.double(forKey: key + "X"), y: d.double(forKey: key + "Y"))
    }

    private static func setPoint(_ p: NSPoint?, _ key: String) {
        let d = UserDefaults.standard
        if let p {
            d.set(p.x, forKey: key + "X")
            d.set(p.y, forKey: key + "Y")
        } else {
            d.removeObject(forKey: key + "X")
            d.removeObject(forKey: key + "Y")
        }
    }

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func endDrag() {
        dragStart = nil
        // The card and the pill each remember their own spot.
        // Save the corner clamped to the screen under the mouse, so a drop past an edge doesn't store an
        // off-screen point (which would no longer match any screen).
        let frame = panel.frame
        let mouse = NSEvent.mouseLocation
        let bounds = (NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) } ?? NSScreen.main)?.frame ?? frame
        let corner = NSPoint(x: min(max(frame.maxX, bounds.minX + frame.width), bounds.maxX),
                             y: min(max(frame.maxY, bounds.minY + frame.height), bounds.maxY))
        if edgeTabShown { cardAnchor = corner } else { anchor = corner }
        place(animated: true)
    }

    private var edgeTabShown: Bool {
        RootView.showsEdgeTab(expanded: monitor.expanded, alert: monitor.alert != nil, minimized: prefs.minimized)
    }

    private func place(animated: Bool) {
        let size = RootView.size(expanded: monitor.expanded, alert: monitor.alert != nil, items: prefs.pillItems,
                                 minimized: prefs.minimized)
        let margin: CGFloat = 10

        let screen: NSScreen?
        var topRight: NSPoint
        let card = edgeTabShown ? cardAnchor : nil
        if let corner = card ?? anchor {
            screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(corner) } ?? NSScreen.main
            topRight = corner
        } else {
            screen = NSScreen.screens.first { $0.localizedName == monitor.screenName } ?? NSScreen.main
            let area = screen?.visibleFrame ?? .zero
            topRight = NSPoint(x: area.maxX - margin, y: area.maxY - margin)
        }
        guard let screen else { return }
        lastScreen = screen
        let area = screen.visibleFrame

        // Until it's dragged somewhere, the card hugs the right edge of the screen.
        if edgeTabShown && card == nil { topRight.x = area.maxX - 4 }
        // Keep the whole panel on screen. The pill and the card may sit over the menu bar or the Dock;
        // the expanded panel stays inside the visible area so nothing of it is covered.
        let bounds = monitor.expanded ? area : screen.frame
        topRight.x = min(max(topRight.x, bounds.minX + size.width), bounds.maxX)
        topRight.y = min(max(topRight.y, bounds.minY + size.height), bounds.maxY)
        let frame = NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height)
        guard animated else { return panel.setFrame(frame, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1) // springy ease-out
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }
}

guard LoginItem.claimSingleInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
