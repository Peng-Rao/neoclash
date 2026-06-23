import NeoClashCore
import AppKit
import ServiceManagement
import SwiftUI

// ============================================================
//  Shared preference types — read across the Settings window,
//  the menu bar status item, and the runtime coordinator.
// ============================================================

enum SettingsKey {
    static let launchAtLogin = "launchAtLogin"
    static let appTheme = "appTheme"
    static let statusBarMode = "statusBarMode"
    static let appLanguage = "appLanguage"
    static let menuShowGroups = "menuShowGroups"
    static let menuShowTrends = "menuShowTrends"
    static let menuShowMetrics = "menuShowMetrics"
    static let menuShowSubscription = "menuShowSubscription"
    static let menuShowCopyProxy = "menuShowCopyProxy"
    static let wifiDisableEnabled = "wifiDisableEnabled"
    static let wifiDisableSSIDs = "wifiDisableSSIDs"
}

extension Notification.Name {
    /// Posted when the status-bar display mode changes so the menu bar item refreshes immediately.
    static let neoStatusBarModeChanged = Notification.Name("NeoClashStatusBarModeChanged")
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the theme to every NeoClash window at once (main, settings, menu bar popover).
    @MainActor
    func apply() {
        NSApplication.shared.appearance = appearance
    }

    /// Reads the persisted theme, falling back to following the system appearance.
    static var stored: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appTheme) ?? "") ?? .system
    }
}

enum StatusBarMode: String, CaseIterable, Identifiable {
    case iconAndSpeed, iconOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconAndSpeed: "Icon and Speed"
        case .iconOnly: "Icon Only"
        }
    }

    static var stored: StatusBarMode {
        StatusBarMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.statusBarMode) ?? "") ?? .iconAndSpeed
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, chinese

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .chinese: "简体中文"
        }
    }
}

/// The shell `export` snippet that points common proxy env vars at the local mixed port.
func terminalProxyExportCommand() -> String {
    let port = UserDefaults.standard.object(forKey: "mixedPort") as? Int ?? 7897
    return "export https_proxy=http://127.0.0.1:\(port) http_proxy=http://127.0.0.1:\(port) all_proxy=socks5://127.0.0.1:\(port)"
}

// ============================================================
//  Settings window — tabbed preferences
// ============================================================

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 580)
    }
}

/// Scrolling glass-card layout shared by every settings tab, over the app's mesh background.
private struct SettingsScaffold<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                content()
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }
}

// ============================================================
//  General tab
// ============================================================

struct GeneralSettingsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator

    @AppStorage(SettingsKey.launchAtLogin) private var launchAtLogin = false
    @AppStorage(SettingsKey.appTheme) private var appTheme = AppTheme.system
    @AppStorage(SettingsKey.statusBarMode) private var statusBarMode = StatusBarMode.iconAndSpeed
    @AppStorage(SettingsKey.appLanguage) private var appLanguage = AppLanguage.system

    @AppStorage(SettingsKey.menuShowGroups) private var menuShowGroups = true
    @AppStorage(SettingsKey.menuShowTrends) private var menuShowTrends = true
    @AppStorage(SettingsKey.menuShowMetrics) private var menuShowMetrics = true
    @AppStorage(SettingsKey.menuShowSubscription) private var menuShowSubscription = true
    @AppStorage(SettingsKey.menuShowCopyProxy) private var menuShowCopyProxy = true

    @AppStorage(SettingsKey.wifiDisableEnabled) private var wifiDisableEnabled = false
    @AppStorage(SettingsKey.wifiDisableSSIDs) private var wifiDisableSSIDs = ""

    var body: some View {
        SettingsScaffold {
            generalCard
            appearanceCard
            menuBarCard
            wifiCard
        }
    }

    private var generalCard: some View {
        GlassCard(title: "General", systemImage: "gearshape", padded: false) {
            SetRow(name: "Launch at Login", desc: "Start NeoClash automatically when you sign in") {
                Toggle("", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var appearanceCard: some View {
        GlassCard(title: "Appearance", systemImage: "paintbrush", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Status Bar", desc: "What the menu bar item shows") {
                    Picker("", selection: $statusBarMode) {
                        ForEach(StatusBarMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .onChange(of: statusBarMode) { _, _ in
                        NotificationCenter.default.post(name: .neoStatusBarModeChanged, object: nil)
                    }
                }
                Divider().opacity(0.5)
                SetRow(name: "Language", desc: "Restart to apply") {
                    Picker("", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Divider().opacity(0.5)
                themeRow
            }
        }
    }

    private var themeRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Theme").font(.system(size: 13, weight: .medium))
                Text("Match macOS or force a mode").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                ForEach(AppTheme.allCases) { theme in
                    ThemeThumbnail(theme: theme, isSelected: appTheme == theme) {
                        appTheme = theme
                        theme.apply()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var menuBarCard: some View {
        GlassCard(title: "Menu Bar", systemImage: "menubar.rectangle", padded: false) {
            VStack(spacing: 0) {
                menuToggleRow("Proxy Groups", "Switch nodes from the menu bar panel", $menuShowGroups)
                Divider().opacity(0.5)
                menuToggleRow("Traffic Trends", "Show a recent throughput sparkline", $menuShowTrends)
                Divider().opacity(0.5)
                menuToggleRow("Network Metrics", "Connections, upload and download", $menuShowMetrics)
                Divider().opacity(0.5)
                menuToggleRow("Subscription Info", "Active profile and last update time", $menuShowSubscription)
                Divider().opacity(0.5)
                menuToggleRow("Copy Terminal Proxy", "Shell export-command shortcut", $menuShowCopyProxy)
            }
        }
    }

    private func menuToggleRow(_ name: String, _ desc: String, _ binding: Binding<Bool>) -> some View {
        SetRow(name: name, desc: desc) {
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private var wifiCard: some View {
        GlassCard(title: "Disable Proxy on Specific Wi-Fi", systemImage: "wifi.slash", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Enable", desc: "Turn off the system proxy on the networks below") {
                    Toggle("", isOn: $wifiDisableEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: wifiDisableEnabled) { _, _ in coordinator.applyWiFiPolicyNow() }
                }
                if wifiDisableEnabled {
                    Divider().opacity(0.5)
                    wifiListSection
                }
            }
        }
    }

    private var wifiListSection: some View {
        let ssids = parsedSSIDs
        let current = runtime.networkStatus.wifiSSID
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wifi").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(current.map { "Current network · \($0)" } ?? "No Wi-Fi network detected")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if let current, !ssids.contains(current) {
                    Button { addSSID(current) } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if ssids.isEmpty {
                Text("Add networks where NeoClash should keep the system proxy off.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            } else {
                ForEach(ssids, id: \.self) { ssid in
                    HStack(spacing: 8) {
                        CodeChip(text: ssid)
                        Spacer(minLength: 8)
                        Button { removeSSID(ssid) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                            .help("Remove network")
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var parsedSSIDs: [String] {
        wifiDisableSSIDs.split(separator: "\n").map(String.init)
    }

    private func addSSID(_ ssid: String) {
        var list = parsedSSIDs
        guard !ssid.isEmpty, !list.contains(ssid) else { return }
        list.append(ssid)
        wifiDisableSSIDs = list.joined(separator: "\n")
        coordinator.applyWiFiPolicyNow()
    }

    private func removeSSID(_ ssid: String) {
        wifiDisableSSIDs = parsedSSIDs.filter { $0 != ssid }.joined(separator: "\n")
        coordinator.applyWiFiPolicyNow()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            // Reflect the real (unchanged) login-item state if the system rejected the request.
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

/// macOS-style window mock used to preview the System / Light / Dark theme choices.
private struct ThemeThumbnail: View {
    var theme: AppTheme
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                preview
                    .frame(width: 76, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: isSelected ? 2.5 : 1)
                    }
            }
            .buttonStyle(.plain)
            Text(theme.label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .animation(.snappy(duration: 0.18), value: isSelected)
    }

    @ViewBuilder
    private var preview: some View {
        switch theme {
        case .system:
            HStack(spacing: 0) {
                windowMock(dark: false)
                windowMock(dark: true)
            }
        case .light:
            windowMock(dark: false)
        case .dark:
            windowMock(dark: true)
        }
    }

    private func windowMock(dark: Bool) -> some View {
        let bg = dark ? Color(white: 0.16) : Color(white: 0.97)
        let bar = dark ? Color(white: 0.25) : Color(white: 0.88)
        let line = dark ? Color(white: 0.45) : Color(white: 0.72)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color.red.opacity(0.8)).frame(width: 4, height: 4)
                Circle().fill(Color.yellow.opacity(0.8)).frame(width: 4, height: 4)
                Circle().fill(Color.green.opacity(0.8)).frame(width: 4, height: 4)
            }
            .padding(.horizontal, 5).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bar)
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 1.5).fill(line).frame(width: 26, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(line.opacity(0.7)).frame(width: 20, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(line.opacity(0.7)).frame(width: 23, height: 3)
            }
            .padding(.horizontal, 5).padding(.top, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bg)
        }
    }
}

// ============================================================
//  Advanced tab — ports, DNS, TUN, behavior
// ============================================================

struct AdvancedSettingsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("autoCloseConnections") private var autoCloseConnections = true
    @AppStorage("enhancedDNS") private var enhancedDNS = true
    @AppStorage("autoRoute") private var autoRoute = true
    @AppStorage("coreLogLevel") private var coreLogLevel = CoreLogLevel.error.rawValue
    @AppStorage("tunStack") private var tunStack = TUNSettings.defaultStack

    @State private var secretShown = false

    var body: some View {
        SettingsScaffold {
            portsCard
            HStack(alignment: .top, spacing: 14) {
                dnsCard
                tunCard
            }
            behaviorCard
        }
        .onAppear { normalizeTUNStackSelection() }
        .onChange(of: tunStack) { _, _ in
            guard normalizeTUNStackSelection() else { return }
            coordinator.restartForTUNSettingsChange()
        }
        .onChange(of: autoRoute) { _, _ in
            coordinator.restartForTUNSettingsChange()
        }
    }

    private var portsCard: some View {
        GlassCard(title: "Ports & Controller", systemImage: "link", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Mixed Port", desc: "HTTP + SOCKS5 on a single port") {
                    portField($mixedPort)
                }
                Divider().opacity(0.5)
                SetRow(name: "External Controller", desc: "RESTful API for the dashboard") {
                    portField($controllerPort)
                }
                Divider().opacity(0.5)
                SetRow(name: "Bind Address", desc: "Locked to loopback for safety") {
                    HStack(spacing: 8) {
                        CodeChip(text: "127.0.0.1")
                        Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(.green)
                    }
                }
                Divider().opacity(0.5)
                SetRow(name: "Controller Secret", desc: "Regenerated on every launch") {
                    HStack(spacing: 6) {
                        CodeChip(text: secretShown ? "k9_3fA2··Qe7Lm" : "••••••••••", width: 150)
                        Button { secretShown.toggle() } label: {
                            Image(systemName: secretShown ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var dnsCard: some View {
        GlassCard(title: "DNS", systemImage: "network", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Enhanced DNS", desc: "fake-ip mode") {
                    Toggle("", isOn: $enhancedDNS).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().opacity(0.5)
                SetRow(name: "Nameserver") { CodeChip(text: "https://1.1.1.1/dns") }
                Divider().opacity(0.5)
                SetRow(name: "fake-ip-range") { CodeChip(text: "198.18.0.1/16") }
            }
        }
    }

    private var tunCard: some View {
        GlassCard(title: "TUN", systemImage: "shield.lefthalf.filled", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "TUN Mode", desc: "System-wide capture · needs admin") {
                    Toggle("", isOn: Binding(get: { runtime.isTUNEnabled }, set: { coordinator.setTUNEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().opacity(0.5)
                SetRow(name: "Stack") {
                    Picker("", selection: $tunStack) {
                        ForEach(TUNSettings.supportedStacks, id: \.self) { stack in
                            Text(stackDisplayName(stack)).tag(stack)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider().opacity(0.5)
                SetRow(name: "Auto Route", desc: "Manage routing table") {
                    Toggle("", isOn: $autoRoute).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private var behaviorCard: some View {
        GlassCard(title: "Behavior", systemImage: "slider.horizontal.3", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Close Connections", desc: "After switching node") {
                    Toggle("", isOn: $autoCloseConnections).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().opacity(0.5)
                SetRow(name: "Default Mode", desc: "Outbound routing mode") {
                    Picker("", selection: Binding(get: { runtime.mode }, set: { coordinator.setMode($0) })) {
                        ForEach(RoutingMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider().opacity(0.5)
                SetRow(name: "Core Log Level", desc: "Restart required") {
                    Picker("", selection: $coreLogLevel) {
                        ForEach(coreLogLevels) { level in
                            Text(level.rawValue.capitalized).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
        }
    }

    private var coreLogLevels: [CoreLogLevel] {
        [.error, .warning, .info, .debug]
    }

    @discardableResult
    private func normalizeTUNStackSelection() -> Bool {
        guard let normalized = TUNSettings.normalizedStack(tunStack) else {
            tunStack = TUNSettings.defaultStack
            return false
        }
        if normalized != tunStack {
            tunStack = normalized
            return false
        }
        return true
    }

    private func stackDisplayName(_ stack: String) -> String {
        stack == "gvisor" ? "gVisor" : stack
    }

    private func portField(_ binding: Binding<Int>) -> some View {
        let validPort = Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = min(max($0, 1), 65_535) }
        )
        return TextField("", value: validPort, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 90)
    }
}

// ============================================================
//  Permissions tab
// ============================================================

struct PermissionsSettingsView: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        SettingsScaffold {
            accessCard
            privacyCard
        }
    }

    private var accessCard: some View {
        GlassCard(title: "System Access", systemImage: "lock.shield", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "System Proxy", desc: "Sets the macOS HTTP/SOCKS proxy via networksetup") {
                    Badge(kind: runtime.isSystemProxyEnabled ? .run : .neutral, dot: true,
                          text: runtime.isSystemProxyEnabled ? "active" : "off")
                }
                Divider().opacity(0.5)
                SetRow(name: "TUN Mode", desc: "Creates a utun device · requires administrator") {
                    Badge(kind: runtime.isTUNEnabled ? .run : .neutral, dot: true,
                          text: runtime.isTUNEnabled ? "active" : "off")
                }
                Divider().opacity(0.5)
                SetRow(name: "Keychain", desc: "Stores subscription URLs and tokens securely") {
                    Badge(kind: .run, text: "enabled")
                }
                Divider().opacity(0.5)
                SetRow(name: "Local Network", desc: "Probes router and Wi-Fi status for diagnostics") {
                    Badge(kind: .neutral, text: "on demand")
                }
            }
        }
    }

    private var privacyCard: some View {
        GlassCard(title: "Privacy & Security", systemImage: "lock") {
            VStack(alignment: .leading, spacing: 9) {
                privacyNote("Subscription URLs and tokens are stored in the macOS Keychain, never in plaintext config.")
                privacyNote("Diagnostics reports redact IPs, tokens, and hostnames before copying.")
                privacyNote("The external controller binds only to 127.0.0.1 and rotates its secret each launch.")
            }
        }
    }

    private func privacyNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield").font(.system(size: 13)).foregroundStyle(.green)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// ============================================================
//  About tab
// ============================================================

struct AboutSettingsView: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        SettingsScaffold {
            identityCard
            coreCard
        }
    }

    private var identityCard: some View {
        GlassCard(padded: true) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: "bolt.horizontal.fill").font(.system(size: 22)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text("NeoClash").font(.system(size: 18, weight: .bold))
                    Text("A Liquid Glass client for the Mihomo core on macOS.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: URL(string: "https://github.com/MetaCubeX/mihomo")!) {
                        Label("Mihomo on GitHub", systemImage: "link").font(.system(size: 11.5))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var coreCard: some View {
        GlassCard(title: "Core & Updates", systemImage: "cpu", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Mihomo Core", desc: "Embedded high-performance engine") {
                    HStack(spacing: 8) {
                        Text(runtime.coreVersion).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        Badge(kind: .run, dot: true, text: "verified")
                    }
                }
                Divider().opacity(0.5)
                SetRow(name: "Signature", desc: "SHA-256 checked against release manifest") {
                    Badge(kind: .run, text: "valid")
                }
                Divider().opacity(0.5)
                SetRow(name: "App Version", desc: "NeoClash for macOS 26") {
                    HStack(spacing: 8) {
                        Text("1.4.0 (134)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        Button("Check for updates") {}.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }
}
