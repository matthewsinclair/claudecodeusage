import SwiftUI
import Foundation
import CryptoKit

/// Reads and writes Claude Code's global config files in its config dir
/// (~/.claude, or $CLAUDE_CONFIG_DIR when set)
@MainActor
class ClaudeConfigManager: ObservableObject {
    @Published var claudeMdText: String = ""
    @Published var cleanupPeriodDays: String = ""
    @Published var statusMessage: String?
    @Published var loadError: String?

    // Resolve the real home directory (works even if the app is ever sandboxed)
    static let homeDir: URL = {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
    }()

    /// CLAUDE_CONFIG_DIR exactly as Claude Code sees it, or nil when unset.
    /// Apps launched from Finder or at login don't inherit shell variables, so
    /// fall back to the launchd user environment (`launchctl setenv`).
    static let configDirOverride: String? = {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return dir
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "CLAUDE_CONFIG_DIR"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let dir = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return dir.isEmpty ? nil : dir
    }()

    static let claudeDir: URL = {
        guard let dir = configDirOverride else {
            return homeDir.appendingPathComponent(".claude")
        }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    }()

    /// The config dir for display, eg "~/.claude"
    static let claudeDirDisplay: String = {
        let path = claudeDir.path
        let home = homeDir.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }()

    /// Keychain services that may hold Claude Code's OAuth credentials, best first.
    /// With CLAUDE_CONFIG_DIR set, Claude Code suffixes the service with the
    /// first 8 hex digits of the SHA-256 of that value, so each config dir keeps
    /// its own login.
    static let keychainServices: [String] = {
        let base = "Claude Code-credentials"
        guard let dir = configDirOverride else { return [base] }
        let digest = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return ["\(base)-\(digest.prefix(8))", base]
    }()

    var claudeMdURL: URL { Self.claudeDir.appendingPathComponent("CLAUDE.md") }
    var settingsJsonURL: URL { Self.claudeDir.appendingPathComponent("settings.json") }

    func load() {
        loadError = nil
        statusMessage = nil

        claudeMdText = (try? String(contentsOf: claudeMdURL, encoding: .utf8)) ?? ""

        if let data = try? Data(contentsOf: settingsJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let days = (json["cleanupPeriodDays"] as? NSNumber)?.intValue {
                cleanupPeriodDays = String(days)
            } else {
                cleanupPeriodDays = ""
            }
        } else if FileManager.default.fileExists(atPath: settingsJsonURL.path) {
            loadError = "Could not parse settings.json"
        } else {
            cleanupPeriodDays = ""
        }
    }

    func saveClaudeMd() {
        do {
            try FileManager.default.createDirectory(at: Self.claudeDir, withIntermediateDirectories: true)
            try claudeMdText.write(to: claudeMdURL.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
            statusMessage = "Saved CLAUDE.md"
        } catch {
            statusMessage = "Failed to save CLAUDE.md: \(error.localizedDescription)"
        }
    }

    /// Updates only cleanupPeriodDays, preserving every other key in settings.json
    func saveCleanupPeriod() {
        let trimmed = cleanupPeriodDays.trimmingCharacters(in: .whitespaces)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsJsonURL) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                statusMessage = "settings.json is not valid JSON — not overwriting it"
                return
            }
            json = existing
        }

        if trimmed.isEmpty {
            json.removeValue(forKey: "cleanupPeriodDays")
        } else if let days = Int(trimmed), days > 0 {
            json["cleanupPeriodDays"] = days
        } else {
            statusMessage = "Retention must be a positive number of days"
            return
        }

        do {
            try FileManager.default.createDirectory(at: Self.claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsJsonURL.resolvingSymlinksInPath(), options: .atomic)
            statusMessage = trimmed.isEmpty ? "Retention reset to Claude Code default (30 days)" : "Saved: keep conversations \(trimmed) days"
        } catch {
            statusMessage = "Failed to save settings.json: \(error.localizedDescription)"
        }
    }
}

struct ClaudeSettingsView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var statusMonitor: StatusMonitor
    @StateObject private var config = ClaudeConfigManager()
    @State private var alertsEnabled = false
    @State private var menuBarStyle = MenuBarAppearance.style
    @State private var menuBarMetric = MenuBarAppearance.metric
    @Environment(\.openURL) var openURL

    var body: some View {
        VStack(spacing: 0) {
            Form {
                menuBarSection
                sessionAlertsSection
                statusAlertsSection
                retentionSection
                claudeMdSection
            }
            .formStyle(.grouped)

            Divider()
            statusBar
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 620, idealHeight: 660)
        .onAppear {
            config.load()
            alertsEnabled = sessionMonitor.hooksInstalled
            sessionMonitor.refreshNotificationAuthStatus()
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        Section {
            Picker("Style", selection: $menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: menuBarStyle) { newValue in
                MenuBarAppearance.style = newValue
                AppDelegate.shared?.updateStatusItem()
            }

            Picker("Show", selection: $menuBarMetric) {
                ForEach(MenuBarMetric.allCases) { metric in
                    Text(metric.label).tag(metric)
                }
            }
            .onChange(of: menuBarMetric) { newValue in
                MenuBarAppearance.metric = newValue
                AppDelegate.shared?.updateStatusItem()
            }
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("Native matches your menu bar and colors the number only when a limit runs hot. Tinted colors the icon by usage level. Emoji is the classic 🟢 look. While a session needs you, the icon becomes an orange bell with a count.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Session alerts

    private var sessionAlertsSection: some View {
        Section {
            Toggle("Alert when a session needs attention", isOn: $alertsEnabled)
                .onChange(of: alertsEnabled) { newValue in
                    guard newValue != sessionMonitor.hooksInstalled else { return }
                    do {
                        try sessionMonitor.setEnabled(newValue)
                        config.statusMessage = newValue
                            ? "Saved: session hooks installed"
                            : "Saved: session hooks removed"
                    } catch {
                        alertsEnabled = !newValue
                        config.statusMessage = "Failed: \(error.localizedDescription)"
                    }
                }

            Toggle("Show notification pop-ups", isOn: Binding(
                get: { sessionMonitor.popupNotificationsEnabled },
                set: { sessionMonitor.popupNotificationsEnabled = $0 }
            ))
            .disabled(!alertsEnabled)

            if alertsEnabled {
                notificationPermissionRow
            }
        } header: {
            Text("Session Alerts")
        } footer: {
            Text("Installs status hooks into \(ClaudeConfigManager.claudeDirDisplay)/settings.json (your other settings and hooks are preserved). Takes effect for Claude Code sessions started or resumed after enabling.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var notificationPermissionRow: some View {
        HStack {
            switch sessionMonitor.notificationsAuthorized {
            case false:
                Label("Notifications are off in System Settings", systemImage: "bell.slash.fill")
                    .foregroundColor(.orange)
                Spacer()
                Button("Open Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                }
            case nil:
                Label("Notification permission not granted yet", systemImage: "bell.badge")
                    .foregroundColor(.orange)
                Spacer()
                Button("Request") {
                    sessionMonitor.requestNotificationPermission()
                }
            default:
                Label("Notifications allowed", systemImage: "bell.fill")
                    .foregroundColor(.green)
                Spacer()
                Button("Send Test") {
                    sessionMonitor.sendTestNotification()
                }
            }
        }
        .font(.callout)
    }

    // MARK: - Claude status

    private var statusAlertsSection: some View {
        Section {
            Toggle("Alert when Claude status changes", isOn: Binding(
                get: { statusMonitor.alertsEnabled },
                set: { statusMonitor.alertsEnabled = $0 }
            ))
        } header: {
            Text("Claude Status")
        } footer: {
            Text("Notifies when status.claude.com reports an outage — and when service recovers. Checked every 5 minutes.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Conversation retention

    private var retentionSection: some View {
        Section {
            HStack {
                Text("Keep conversations for")
                Spacer()
                TextField("30", text: $config.cleanupPeriodDays)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                Text("days")
                    .foregroundColor(.secondary)
                Button("Save") {
                    config.saveCleanupPeriod()
                }
            }
        } header: {
            Text("Conversation Retention")
        } footer: {
            Text("How long Claude Code keeps local transcripts (cleanupPeriodDays in \(ClaudeConfigManager.claudeDirDisplay)/settings.json). Leave empty for the default of 30 days.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - CLAUDE.md

    private var claudeMdSection: some View {
        Section {
            TextEditor(text: $config.claudeMdText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )

            HStack {
                Button("Save CLAUDE.md") {
                    config.saveClaudeMd()
                }
                Button("Reload") {
                    config.load()
                }
                Spacer()
                if let error = config.loadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        } header: {
            Text("How You Like to Work")
        } footer: {
            Text("Global instructions Claude Code reads in every project (\(ClaudeConfigManager.claudeDirDisplay)/CLAUDE.md): coding style, tools, how you want Claude to communicate.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            if let status = config.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundColor(status.hasPrefix("Saved") || status.hasPrefix("Retention") ? .green : .orange)
            }
            Spacer()
            Text(ClaudeConfigManager.claudeDirDisplay)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

#Preview {
    ClaudeSettingsView(sessionMonitor: SessionMonitor(), statusMonitor: StatusMonitor())
}
