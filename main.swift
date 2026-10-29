import AppKit
import ApplicationServices
import QuartzCore

// MARK: - Configuration

private let quitKeyCode: CGKeyCode = 12 // kVK_ANSI_Q
private let syntheticMarker: Int64 = 0x5155_4954 // "QUIT"

// MARK: - HUD

private final class HUDView: NSView {
    var appName = "" {
        didSet { needsDisplay = true }
    }

    var progress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let background = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 18,
            yRadius: 18
        )
        NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.10, alpha: 0.95).setFill()
        background.fill()

        NSColor(calibratedWhite: 1, alpha: 0.09).setStroke()
        background.lineWidth = 1
        background.stroke()

        drawCentered(
            "Hold \u{2318}Q to Quit",
            font: .systemFont(ofSize: 15.5, weight: .semibold),
            color: .white,
            y: 23
        )

        let subtitle = appName.isEmpty
            ? "Release to cancel"
            : "\(appName) will quit when the bar fills"
        drawCentered(
            subtitle,
            font: .systemFont(ofSize: 11.5, weight: .regular),
            color: NSColor(calibratedWhite: 1, alpha: 0.55),
            y: 48
        )

        let bar = NSRect(x: 24, y: 81, width: bounds.width - 48, height: 5)
        let radius = bar.height / 2

        NSColor(calibratedWhite: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        guard progress > 0 else { return }
        let clamped = min(max(progress, 0), 1)
        let fillWidth = max(bar.height, bar.width * clamped)
        let fillRect = NSRect(x: bar.minX, y: bar.minY, width: fillWidth, height: bar.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }

    private func drawCentered(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let rect = NSRect(x: 20, y: y, width: bounds.width - 40, height: font.pointSize + 7)
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

private final class HUDWindow: NSPanel {
    private static let size = NSSize(width: 380, height: 112)

    private let hudView = HUDView()
    private var generation = 0

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        hudView.frame = NSRect(origin: .zero, size: Self.size)
        hudView.autoresizingMask = [.width, .height]
        contentView = hudView
        alphaValue = 0
    }

    var progress: CGFloat {
        get { hudView.progress }
        set { hudView.progress = newValue }
    }

    func show(appName: String) {
        generation += 1
        hudView.appName = appName
        hudView.progress = 0
        positionOnActiveScreen()

        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func hide(immediately: Bool = false) {
        guard isVisible else { return }

        generation += 1

        if immediately {
            alphaValue = 0
            orderOut(nil)
            return
        }

        let currentGeneration = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.orderOut(nil)
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(mouse, $0.frame) } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: (visible.midX - Self.size.width / 2).rounded(),
            y: (visible.midY - Self.size.height / 2).rounded()
        )
        setFrameOrigin(origin)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase {
        case idle
        case holding
        case committing
        case quitting
    }

    private let hud = HUDWindow()
    private let settings = AppSettings.shared
    private lazy var settingsWindowController = SettingsWindowController()

    private var statusItem: NSStatusItem?
    private var enabledItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var holdInfoItem: NSMenuItem?
    private var previewItem: NSMenuItem?
    private var statusTextItem: NSMenuItem?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var hudTimer: Timer?
    private var permissionTimer: Timer?
    private var quitResetWorkItem: DispatchWorkItem?

    private var phase: Phase = .idle
    private var holdStartedAt: CFTimeInterval = 0
    private var targetPID: pid_t?
    private var physicalQDown = false
    private var isPreview = false
    private var isDemo = false

    private var didPromptAccessibility = false
    private var didPromptInputMonitoring = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        isDemo = CommandLine.arguments.contains("--demo")
        let settingsDemo = CommandLine.arguments.contains("--settings-demo")
        let showsLoginItemStatus = CommandLine.arguments.contains("--login-item-status")
        let registersLoginItem = CommandLine.arguments.contains("--register-login-item")
        let isCLIMode = showsLoginItemStatus || registersLoginItem

        if !isDemo, !settingsDemo, !isCLIMode, hasAnotherInstance() {
            NSApp.terminate(nil)
            return
        }

        if isCLIMode {
            if registersLoginItem {
                if settings.launchAtLogin {
                    settings.ensureLaunchAtLogin()
                } else {
                    settings.launchAtLogin = true
                }
            } else {
                settings.refreshLoginItemStatus()
            }
            print("Login item status: \(settings.loginItemStatus)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
            return
        }

        settings.onEnabledChange = { [weak self] in
            self?.enabledSettingChanged()
        }
        settings.onLaunchAtLoginChange = { [weak self] in
            self?.updateMenu()
        }

        buildMainMenu()

        if settingsDemo {
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                NSApp.terminate(nil)
            }
            return
        }

        if isDemo {
            runDemo()
            return
        }

        buildStatusItem()
        if settings.launchAtLogin {
            settings.ensureLaunchAtLogin()
        }

        if settings.isEnabled {
            startInterceptor()
        }
        updateMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hudTimer?.invalidate()
        permissionTimer?.invalidate()
        quitResetWorkItem?.cancel()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "CmdQGuard", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "CmdQGuard")
        appMenu.addItem(
            withTitle: "About CmdQGuard",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        let settingsMenuItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsMenuItem.target = self
        appMenu.addItem(settingsMenuItem)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit CmdQGuard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "command", accessibilityDescription: "CmdQGuard") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "\u{2318}"
        }
        item.button?.toolTip = "CmdQGuard \u{2014} hold \u{2318}Q to quit"

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let titleItem = NSMenuItem(title: "CmdQGuard", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let settingsMenuItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        menu.addItem(.separator())

        let enabled = NSMenuItem(
            title: "Warn Before Quitting",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enabled.target = self
        menu.addItem(enabled)
        enabledItem = enabled

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        launchAtLoginItem = launchAtLogin

        let holdInfo = NSMenuItem(
            title: "Hold \u{2318}Q for \(formattedHoldDuration) to quit",
            action: nil,
            keyEquivalent: ""
        )
        holdInfo.isEnabled = false
        menu.addItem(holdInfo)
        holdInfoItem = holdInfo

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusTextItem = status

        menu.addItem(.separator())

        let preview = NSMenuItem(
            title: "Show Preview",
            action: #selector(showPreviewFromMenu),
            keyEquivalent: ""
        )
        preview.target = self
        menu.addItem(preview)
        previewItem = preview

        let accessibility = NSMenuItem(
            title: "Accessibility Settings\u{2026}",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibility.target = self
        menu.addItem(accessibility)

        let inputMonitoring = NSMenuItem(
            title: "Input Monitoring Settings\u{2026}",
            action: #selector(openInputMonitoringSettings),
            keyEquivalent: ""
        )
        inputMonitoring.target = self
        menu.addItem(inputMonitoring)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit CmdQGuard",
            action: #selector(quitGuard),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
    }

    private func updateMenu() {
        guard let statusItem, let enabledItem, let statusTextItem else { return }

        enabledItem.state = settings.isEnabled ? .on : .off
        launchAtLoginItem?.state = settings.launchAtLogin ? .on : .off
        holdInfoItem?.title = "Hold \u{2318}Q for \(formattedHoldDuration) to quit"
        previewItem?.isEnabled = settings.isEnabled && phase == .idle

        let hasAccessibility = AXIsProcessTrusted()
        let hasInputMonitoring = CGPreflightListenEventAccess()
        let needsPermission = settings.isEnabled
            && (eventTap == nil || !hasAccessibility || !hasInputMonitoring)

        let symbolName = needsPermission ? "exclamationmark.triangle.fill" : "command"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CmdQGuard") {
            image.isTemplate = true
            statusItem.button?.image = image
        }

        if !settings.isEnabled {
            statusTextItem.title = "Status: Paused"
        } else if !hasAccessibility {
            statusTextItem.title = "Status: Accessibility permission needed"
        } else if !hasInputMonitoring {
            statusTextItem.title = "Status: Input Monitoring permission needed"
        } else if eventTap == nil {
            statusTextItem.title = "Status: Starting\u{2026}"
        } else {
            let count = settings.enabledAppKeys.count
            if count == 0 {
                statusTextItem.title = "Status: Ready \u{2014} no apps protected"
            } else {
                statusTextItem.title = "Status: Ready \u{2014} \(count) app\(count == 1 ? "" : "s") protected"
            }
        }

        statusItem.button?.appearsDisabled = !settings.isEnabled
        statusItem.button?.toolTip = settings.isEnabled
            ? "CmdQGuard \u{2014} hold \u{2318}Q to quit"
            : "CmdQGuard \u{2014} paused"
    }

    private var formattedHoldDuration: String {
        String(format: "%.1f s", settings.holdDuration)
    }

    // MARK: Menu actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        settings.isEnabled.toggle()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        settings.launchAtLogin.toggle()
    }

    @objc private func showSettings() {
        settingsWindowController.present()
    }

    private func enabledSettingChanged() {
        if settings.isEnabled {
            if eventTap == nil {
                startInterceptor()
            }
        } else {
            resetInteraction()
            stopPermissionPolling()
        }
        updateMenu()
    }

    @objc private func showPreviewFromMenu() {
        showPreview()
    }

    @objc private func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    @objc private func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
        if settings.isEnabled, eventTap == nil {
            startPermissionPolling()
        }
        updateMenu()
    }

    @objc private func quitGuard() {
        NSApp.terminate(nil)
    }

    // MARK: Preview / demo

    private func showPreview() {
        guard phase == .idle, settings.isEnabled || isDemo else { return }

        isPreview = true
        phase = .holding
        holdStartedAt = CACurrentMediaTime()
        hud.show(appName: isDemo ? "Preview App" : "Your App")
        startHUDTimer()

        if isDemo {
            print("CmdQGuard demo: showing the hold-to-quit warning\u{2026}")
        }
    }

    private func runDemo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showPreview()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            NSApp.terminate(nil)
        }
    }

    // MARK: Event tap

    private func startInterceptor() {
        guard settings.isEnabled, !isDemo else { return }

        // An active event tap needs both TCC grants:
        // - Input Monitoring to observe key events
        // - Accessibility to swallow and inject them
        guard AXIsProcessTrusted() else {
            if !didPromptAccessibility {
                didPromptAccessibility = true
                promptForAccessibility()
            }
            startPermissionPolling()
            updateMenu()
            return
        }

        guard CGPreflightListenEventAccess() else {
            if !didPromptInputMonitoring {
                didPromptInputMonitoring = true
                _ = CGRequestListenEventAccess()
            }
            startPermissionPolling()
            updateMenu()
            return
        }

        if installEventTap() {
            stopPermissionPolling()
        } else {
            startPermissionPolling()
        }
        updateMenu()
    }

    private func installEventTap() -> Bool {
        if eventTap != nil { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    private func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }

        let timer = Timer(
            timeInterval: 1.25,
            target: self,
            selector: #selector(permissionTick(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    @objc private func permissionTick(_ timer: Timer) {
        guard AXIsProcessTrusted() else {
            updateMenu()
            return
        }

        guard CGPreflightListenEventAccess() else {
            if !didPromptInputMonitoring {
                didPromptInputMonitoring = true
                _ = CGRequestListenEventAccess()
            }
            updateMenu()
            return
        }

        if installEventTap() {
            stopPermissionPolling()
        }
        updateMenu()
    }

    func eventTapWasDisabled() {
        resetInteraction()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        updateMenu()
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return passThrough
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let userData = event.getIntegerValueField(.eventSourceUserData)

        // Synthetic events posted after the hold are tagged so the tap lets
        // them reach the app instead of swallowing them again.
        if userData == syntheticMarker {
            return passThrough
        }

        guard settings.isEnabled else { return passThrough }

        if type == .flagsChanged {
            if phase == .holding, !flags.contains(.maskCommand) {
                cancelHold()
            }
            return passThrough
        }

        guard keyCode == Int64(quitKeyCode) else { return passThrough }

        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            // A hold began for this physical key-down. Swallow every repeat,
            // even if the hold was cancelled by releasing Command first.
            if physicalQDown {
                return nil
            }

            if phase != .idle {
                // Swallow Q while a preview or commit is in progress, and keep
                // swallowing its repeats until the physical key is released.
                physicalQDown = true
                return nil
            }

            guard !isRepeat else { return passThrough }

            let disallowed: CGEventFlags = [.maskShift, .maskControl, .maskAlternate]
            guard flags.contains(.maskCommand), flags.isDisjoint(with: disallowed) else {
                return passThrough
            }

            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  settings.isProtected(frontmost) else {
                return passThrough
            }

            beginHold(target: frontmost)
            return nil

        case .keyUp:
            switch phase {
            case .holding:
                physicalQDown = false
                cancelHold()
                return nil
            case .committing:
                physicalQDown = false
                return nil
            case .quitting:
                physicalQDown = false
                targetPID = nil
                phase = .idle
                quitResetWorkItem?.cancel()
                quitResetWorkItem = nil
                return nil
            case .idle:
                if physicalQDown {
                    // Finish swallowing the release of a cancelled hold.
                    physicalQDown = false
                    return nil
                }
                return passThrough
            }

        default:
            return passThrough
        }
    }

    // MARK: Hold lifecycle

    private func beginHold(target: NSRunningApplication) {
        guard phase == .idle else { return }

        phase = .holding
        holdStartedAt = CACurrentMediaTime()
        physicalQDown = true
        targetPID = target.processIdentifier

        hud.show(appName: target.localizedName ?? "The current app")
        startHUDTimer()
    }

    private func cancelHold() {
        guard phase == .holding || phase == .committing else { return }

        hudTimer?.invalidate()
        hudTimer = nil
        phase = .idle
        isPreview = false
        targetPID = nil
        hud.hide()
        updateMenu()
    }

    private func startHUDTimer() {
        hudTimer?.invalidate()

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(hudTick(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
    }

    @objc private func hudTick(_ timer: Timer) {
        guard phase == .holding else {
            timer.invalidate()
            return
        }

        let elapsed = CACurrentMediaTime() - holdStartedAt
        let progress = min(1, elapsed / settings.holdDuration)
        hud.progress = CGFloat(progress)

        guard progress >= 1 else { return }

        timer.invalidate()
        hudTimer = nil
        phase = .committing

        // Let the full bar render for a couple of frames before acting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.phase == .committing else { return }
            self.finishHold()
        }
    }

    private func finishHold() {
        if isPreview {
            isPreview = false
            phase = .idle
            hud.hide()
            if isDemo {
                print("CmdQGuard demo complete \u{2014} no app was quit.")
            }
            return
        }

        guard settings.isEnabled else {
            resetInteraction()
            return
        }

        // Focus could have changed while the key was held, or the app may have
        // been switched off in Settings. Never quit a different app than the
        // one named in the warning.
        guard let targetPID,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == targetPID,
              settings.isProtected(frontmost) else {
            phase = .idle
            self.targetPID = nil
            hud.hide()
            return
        }

        phase = .quitting
        hud.hide(immediately: true)
        postSyntheticQuit()

        if physicalQDown {
            scheduleQuitReset()
        } else {
            // Q was already released during the short commit delay; there are
            // no repeats to swallow, so return to idle immediately.
            phase = .idle
            self.targetPID = nil
        }
        updateMenu()
    }

    private func postSyntheticQuit() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            phase = .idle
            return
        }

        let down = CGEvent(keyboardEventSource: source, virtualKey: quitKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: quitKeyCode, keyDown: false)

        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)

        down?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            up?.post(tap: .cghidEventTap)
        }
    }

    private func scheduleQuitReset() {
        quitResetWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.phase == .quitting {
                self.phase = .idle
            }
            self.targetPID = nil
            self.physicalQDown = false
        }
        quitResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func resetInteraction() {
        hudTimer?.invalidate()
        hudTimer = nil
        quitResetWorkItem?.cancel()
        quitResetWorkItem = nil
        isPreview = false
        targetPID = nil
        physicalQDown = false
        phase = .idle
        hud.hide()
    }

    // MARK: Helpers

    private func hasAnotherInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1
    }
}

// MARK: - Event tap callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        delegate.eventTapWasDisabled()
        return Unmanaged.passUnretained(event)
    }

    return delegate.handleEvent(type: type, event: event)
}

// MARK: - Entry point

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
