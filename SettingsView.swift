import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Login item

enum LoginItemStatus: Equatable {
    case unknown
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case failed(String)
}

// MARK: - Applications

struct ManagedApp: Identifiable {
    let id: String
    let name: String
    let bundleID: String?
    let path: String
    let icon: NSImage
    let isRunning: Bool
}

// MARK: - Shared settings

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let enabled = "enabled"
        static let launchAtLogin = "launchAtLogin"
        static let holdDuration = "holdDuration"
        static let enabledApps = "enabledAppKeys"
        static let customApps = "customAppPaths"
        static let safari = "bundle:com.apple.Safari"
    }

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
            onEnabledChange?()
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLoginPreference()
            onLaunchAtLoginChange?()
        }
    }

    @Published var holdDuration: TimeInterval {
        didSet {
            guard oldValue != holdDuration else { return }
            defaults.set(holdDuration, forKey: Key.holdDuration)
        }
    }

    @Published private(set) var enabledAppKeys: Set<String>
    @Published private(set) var applications: [ManagedApp] = []
    @Published private(set) var loginItemStatus: LoginItemStatus = .unknown

    var onEnabledChange: (() -> Void)?
    var onLaunchAtLoginChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var customAppPaths: [String]
    private var hasScannedApplications = false

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.launchAtLogin: true,
            Key.holdDuration: 0.6
        ])

        isEnabled = defaults.bool(forKey: Key.enabled)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        holdDuration = min(max(defaults.double(forKey: Key.holdDuration), 0.3), 3.0)

        // This version uses a whitelist. Start with Safari enabled and ignore
        // per-app exceptions saved by the earlier all-apps version.
        defaults.removeObject(forKey: "disabledAppKeys")
        if defaults.object(forKey: Key.enabledApps) == nil {
            defaults.set([Key.safari], forKey: Key.enabledApps)
        }
        enabledAppKeys = Set(
            defaults.stringArray(forKey: Key.enabledApps) ?? [Key.safari]
        )
        customAppPaths = defaults.stringArray(forKey: Key.customApps) ?? []
        refreshLoginItemStatus()
    }

    // MARK: Per-app protection

    static func key(for app: NSRunningApplication) -> String? {
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
            return "bundle:\(bundleID)"
        }
        if let path = app.bundleURL?.path {
            return "path:\(path)"
        }
        return nil
    }

    /// Whether CmdQGuard should warn before quitting this app.
    func isProtected(_ app: NSRunningApplication?) -> Bool {
        guard isEnabled, let app else { return false }
        guard let key = Self.key(for: app) else { return false }
        return enabledAppKeys.contains(key)
    }

    func isProtected(_ app: ManagedApp) -> Bool {
        enabledAppKeys.contains(app.id)
    }

    func setProtected(_ protected: Bool, for app: ManagedApp) {
        var updated = enabledAppKeys
        if protected {
            updated.insert(app.id)
        } else {
            updated.remove(app.id)
        }
        enabledAppKeys = updated
        defaults.set(Array(updated).sorted(), forKey: Key.enabledApps)
    }

    // MARK: Application list

    func loadApplicationsIfNeeded() {
        guard !hasScannedApplications else { return }
        refreshApplications()
    }

    func refreshApplications() {
        hasScannedApplications = true

        var found: [String: ManagedApp] = [:]

        func add(url: URL, isRunning: Bool) {
            guard url.pathExtension.lowercased() == "app" else { return }
            guard let bundle = Bundle(url: url) else { return }

            let bundleID = bundle.bundleIdentifier
            if bundleID == Bundle.main.bundleIdentifier { return }

            let id = bundleID.map { "bundle:\($0)" } ?? "path:\(url.path)"
            if let existing = found[id] {
                if isRunning, !existing.isRunning {
                    found[id] = ManagedApp(
                        id: existing.id,
                        name: existing.name,
                        bundleID: existing.bundleID,
                        path: existing.path,
                        icon: existing.icon,
                        isRunning: true
                    )
                }
                return
            }

            let finderName = FileManager.default.displayName(atPath: url.path)
            let name =
                finderName.isEmpty
                ? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? url.deletingPathExtension().lastPathComponent)
                : finderName

            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)

            found[id] = ManagedApp(
                id: id,
                name: name,
                bundleID: bundleID,
                path: url.path,
                icon: icon,
                isRunning: isRunning
            )
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL {
                add(url: url, isRunning: true)
            }
        }

        for root in applicationSearchRoots {
            for url in appURLs(in: root, depth: 1) {
                add(url: url, isRunning: false)
            }
        }

        for path in customAppPaths where FileManager.default.fileExists(atPath: path) {
            add(url: URL(fileURLWithPath: path), isRunning: false)
        }

        applications = found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        if CommandLine.arguments.contains("--settings-demo") {
            let safari = applications.first { $0.bundleID == "com.apple.Safari" }
            let vscode = applications.first { $0.bundleID == "com.microsoft.VSCode" }
            print(
                "Settings demo: scanned \(applications.count) apps; "
                + "Safari enabled: \(safari.map { isProtected($0) } ?? false); "
                + "VSCode enabled: \(vscode.map { isProtected($0) } ?? false); "
                + "hold: \(String(format: "%.1f", holdDuration)) s"
            )
        }
    }

    func addApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if !customAppPaths.contains(url.path) {
            customAppPaths.append(url.path)
            defaults.set(customAppPaths, forKey: Key.customApps)
        }

        let key = Self.key(forAppAt: url)
        if !enabledAppKeys.contains(key) {
            var updated = enabledAppKeys
            updated.insert(key)
            enabledAppKeys = updated
            defaults.set(Array(updated).sorted(), forKey: Key.enabledApps)
        }

        refreshApplications()
    }

    static func key(forAppAt url: URL) -> String {
        if let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty {
            return "bundle:\(bundleID)"
        }
        return "path:\(url.path)"
    }

    private var applicationSearchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    private func appURLs(in directory: URL, depth: Int) -> [URL] {
        // Do not skip hidden entries: macOS exposes Safari (and some other
        // system apps) as hidden-flag symlinks inside /Applications.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        var result: [URL] = []
        for url in entries {
            if url.pathExtension.lowercased() == "app" {
                result.append(url)
            } else if depth > 0,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result.append(contentsOf: appURLs(in: url, depth: depth - 1))
            }
        }
        return result
    }

    // MARK: Launch at login

    func ensureLaunchAtLogin() {
        guard launchAtLogin else {
            refreshLoginItemStatus()
            return
        }

        let service = SMAppService.mainApp

        switch service.status {
        case .enabled, .requiresApproval:
            loginItemStatus = service.status == .enabled ? .enabled : .requiresApproval

        case .notRegistered, .notFound:
            do {
                try service.register()
                refreshLoginItemStatus()
            } catch {
                loginItemStatus = .failed(error.localizedDescription)
            }

        @unknown default:
            loginItemStatus = .unknown
        }
    }

    func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItemStatus = .enabled
        case .requiresApproval:
            loginItemStatus = .requiresApproval
        case .notRegistered:
            loginItemStatus = .notRegistered
        case .notFound:
            loginItemStatus = .notFound
        @unknown default:
            loginItemStatus = .unknown
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func applyLaunchAtLoginPreference() {
        if launchAtLogin {
            ensureLaunchAtLogin()
            return
        }

        let service = SMAppService.mainApp
        do {
            try service.unregister()
        } catch {
            // Unregistering an item that is no longer registered is harmless.
        }
        refreshLoginItemStatus()
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var query = ""

    private var filteredApps: [ManagedApp] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return settings.applications }
        return settings.applications.filter { app in
            app.name.localizedCaseInsensitiveContains(search)
                || (app.bundleID?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            generalSection
            applicationsSection
            Text("Changes are saved automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 620, height: 760)
        .onAppear {
            settings.loadApplicationsIfNeeded()
            if settings.launchAtLogin {
                settings.refreshLoginItemStatus()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CmdQGuard")
                .font(.system(size: 24, weight: .bold))
            Text("Hold \u{2318}Q to quit an app. Release early to cancel.")
                .foregroundColor(.secondary)
        }
    }

    private var generalSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable hold-to-quit", isOn: $settings.isEnabled)

                HStack(spacing: 10) {
                    Text("Hold time")
                    Slider(value: $settings.holdDuration, in: 0.3...3.0, step: 0.1)
                    Text(String(format: "%.1f s", settings.holdDuration))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Toggle("Launch CmdQGuard at login", isOn: $settings.launchAtLogin)
                loginItemStatusRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("General")
        }
    }

    @ViewBuilder
    private var loginItemStatusRow: some View {
        if settings.launchAtLogin {
            switch settings.loginItemStatus {
            case .enabled:
                Label("CmdQGuard starts automatically at login.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)

            case .requiresApproval:
                HStack(spacing: 8) {
                    Label("Approve CmdQGuard in System Settings \u{203A} Login Items.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("Open Login Items") {
                        settings.openLoginItemsSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

            case .notRegistered, .notFound:
                HStack(spacing: 8) {
                    Text("Not registered yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Register") {
                        settings.ensureLaunchAtLogin()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

            case .failed(let message):
                HStack(spacing: 8) {
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                    Button("Try Again") {
                        settings.ensureLaunchAtLogin()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    Button("Open Login Items") {
                        settings.openLoginItemsSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

            case .unknown:
                EmptyView()
            }
        }
    }

    private var applicationsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(settings.enabledAppKeys.count) protected. Only apps you turn on are protected; all other apps quit immediately with a single \u{2318}Q.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search applications", text: $query)
                        .textFieldStyle(.plain)

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .frame(height: 16)

                    Button {
                        settings.addApplication()
                    } label: {
                        Label("Add Protected App\u{2026}", systemImage: "plus")
                    }
                    .controlSize(.small)

                    Button {
                        settings.refreshApplications()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Refresh application list")
                }

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if filteredApps.isEmpty {
                            Text(settings.applications.isEmpty ? "Loading applications\u{2026}" : "No matching applications.")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 30)
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(filteredApps) { app in
                                AppRow(
                                    app: app,
                                    isMasterEnabled: settings.isEnabled,
                                    isProtected: Binding(
                                        get: { settings.isProtected(app) },
                                        set: { settings.setProtected($0, for: app) }
                                    )
                                )
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: 330)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("Applications")
        }
    }
}

private struct AppRow: View {
    let app: ManagedApp
    let isMasterEnabled: Bool
    @Binding var isProtected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(app.bundleID ?? app.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(isProtected ? "Protected" : "Off")
                .font(.system(size: 11))
                .foregroundColor(isProtected ? .secondary : .orange)
                .frame(width: 60, alignment: .trailing)

            Toggle("", isOn: $isProtected)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isMasterEnabled)
        }
        .padding(.vertical, 5)
        .opacity(isMasterEnabled ? 1 : 0.55)
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController {
    private var hasPositionedWindow = false

    init() {
        let host = NSHostingController(rootView: SettingsView(settings: .shared))
        let window = NSWindow(contentViewController: host)
        window.title = "CmdQGuard Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 760))
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }

        if !hasPositionedWindow, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.midY - size.height / 2).rounded()
            ))
            hasPositionedWindow = true
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
