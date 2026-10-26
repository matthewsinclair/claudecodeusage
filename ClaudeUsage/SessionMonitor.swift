import Foundation
import AppKit
import UserNotifications

struct ClaudeSession: Identifiable, Equatable {
    enum Status: String {
        case running
        case needsAttention = "needs_attention"
        case finished
    }

    let id: String
    let status: Status
    let cwd: String
    let message: String
    let updatedAt: Date
    let termProgram: String
    let tty: String
    /// User has clicked through to this session since it last asked for attention
    let acknowledged: Bool

    var projectName: String {
        cwd.isEmpty ? "Unknown project" : URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// Watches session status sidecar files written by the ClaudeUsage hook script
/// installed into Claude Code's settings.json.
@MainActor
class SessionMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var hooksInstalled = false
    /// nil = not yet determined, true = allowed, false = denied in System Settings
    @Published var notificationsAuthorized: Bool?
    @Published var notificationError: String?

    /// User preference: show macOS notification pop-ups (menu bar bell always works)
    var popupNotificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "popupNotificationsEnabled") as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "popupNotificationsEnabled")
        }
    }

    private var timer: Timer?
    private var notifiedKeys = Set<String>()

    static let baseDir = ClaudeConfigManager.claudeDir.appendingPathComponent("claudeusage")
    static let sessionsDir = baseDir.appendingPathComponent("sessions")
    static let hookScriptURL = baseDir.appendingPathComponent("session-hook.sh")
    static let settingsURL = ClaudeConfigManager.claudeDir.appendingPathComponent("settings.json")

    /// Substring that identifies our hook entries in settings.json
    static let hookMarker = "claudeusage/session-hook.sh"
    static let hookEvents = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    var needsAttentionSessions: [ClaudeSession] {
        sessions.filter { $0.status == .needsAttention && !$0.acknowledged }
    }

    init() {
        hooksInstalled = Self.checkHooksInstalled()
        refreshNotificationAuthStatus()
        if hooksInstalled {
            // Keep the installed hook script up to date with this app version
            try? writeHookScript()
            start()
        }
        // Note: notification permission is requested from applicationDidFinishLaunching,
        // not here — this init runs before the app has finished launching and
        // requesting too early fails silently.
    }

    // MARK: - Polling

    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessions = []
    }

    private func scan() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.sessionsDir, includingPropertiesForKeys: nil) else {
            if !sessions.isEmpty { sessions = [] }
            return
        }

        var found: [ClaudeSession] = []
        let now = Date()

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["session_id"] as? String,
                  let statusRaw = json["status"] as? String,
                  let status = ClaudeSession.Status(rawValue: statusRaw) else { continue }

            let updatedAt = Date(timeIntervalSince1970: (json["updated_at"] as? NSNumber)?.doubleValue ?? 0)

            // Delete sidecars from long-dead sessions, hide anything idle > 12h
            if now.timeIntervalSince(updatedAt) > 48 * 3600 {
                try? fm.removeItem(at: file)
                continue
            }
            if now.timeIntervalSince(updatedAt) > 12 * 3600 { continue }

            found.append(ClaudeSession(
                id: sid,
                status: status,
                cwd: json["cwd"] as? String ?? "",
                message: json["message"] as? String ?? "",
                updatedAt: updatedAt,
                termProgram: json["term_program"] as? String ?? "",
                tty: json["tty"] as? String ?? "",
                acknowledged: json["acknowledged"] as? Bool ?? false
            ))
        }

        found.sort { $0.updatedAt > $1.updatedAt }
        if found != sessions {
            sessions = found
        }
        notifyNewAttention()
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor in
                self?.notificationError = error?.localizedDescription
                self?.refreshNotificationAuthStatus()
            }
        }
    }

    func refreshNotificationAuthStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self?.notificationsAuthorized = true
                case .denied:
                    self?.notificationsAuthorized = false
                default:
                    self?.notificationsAuthorized = nil
                }
            }
        }
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Claude Code needs you"
        content.body = "Test notification — this is what a session alert looks like"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func notifyNewAttention() {
        for session in needsAttentionSessions {
            let key = "\(session.id):\(Int(session.updatedAt.timeIntervalSince1970))"
            guard !notifiedKeys.contains(key) else { continue }
            notifiedKeys.insert(key)

            guard popupNotificationsEnabled else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Claude Code needs you"
            content.body = session.message.isEmpty
                ? session.projectName
                : "\(session.projectName): \(session.message)"
            content.sound = .default
            content.userInfo = ["session_id": session.id]

            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: key, content: content, trigger: nil)
            )
        }
        if notifiedKeys.count > 500 { notifiedKeys.removeAll() }
    }

    // MARK: - Click-to-focus

    /// Bring the terminal window/tab running this session to the front.
    func focusSession(_ session: ClaudeSession) {
        acknowledge(session)
        let devTTY = session.tty.isEmpty ? nil : "/dev/\(session.tty)"

        switch session.termProgram {
        case "Apple_Terminal":
            runAppleScript(Self.terminalFocusScript(tty: devTTY))
        case "iTerm.app":
            runAppleScript(Self.itermFocusScript(tty: devTTY))
        case "vscode":
            activateApp(bundleIdentifier: "com.microsoft.VSCode")
        default:
            // tmux or unknown — best effort: bring Terminal forward
            runAppleScript(Self.terminalFocusScript(tty: devTTY))
        }
    }

    func focusSession(id: String) {
        if let session = sessions.first(where: { $0.id == id }) {
            focusSession(session)
        }
    }

    /// Clear the alert for a session the user has jumped to. The sidecar keeps the
    /// flag until the next hook event overwrites the file with fresh state.
    private func acknowledge(_ session: ClaudeSession) {
        guard session.status == .needsAttention, !session.acknowledged else { return }

        let file = Self.sessionsDir.appendingPathComponent("\(session.id).json")
        if let data = try? Data(contentsOf: file),
           var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json["acknowledged"] = true
            if let out = try? JSONSerialization.data(withJSONObject: json) {
                try? out.write(to: file, options: .atomic)
            }
        }

        // Update in-memory immediately so the bell clears without waiting for the next scan
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = ClaudeSession(
                id: session.id,
                status: session.status,
                cwd: session.cwd,
                message: session.message,
                updatedAt: session.updatedAt,
                termProgram: session.termProgram,
                tty: session.tty,
                acknowledged: true
            )
        }
    }

    private func activateApp(bundleIdentifier: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func runAppleScript(_ source: String) {
        // NSAppleScript is not thread-safe and silently no-ops off the main thread;
        // run osascript as a subprocess instead so focusing never blocks the UI.
        let logURL = Self.baseDir.appendingPathComponent("focus-debug.log")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = errPipe
            do {
                try process.run()
                process.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: errData, encoding: .utf8) ?? ""
                let result = "exit=\(process.terminationStatus) \(err)\n"
                try? result.write(to: logURL, atomically: true, encoding: .utf8)
            } catch {
                try? "failed to run osascript: \(error)\n".write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func terminalFocusScript(tty: String?) -> String {
        let selectTab: String
        if let tty = tty {
            selectTab = """
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is equal to "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            """
        } else {
            selectTab = ""
        }
        return """
        tell application "Terminal"
            activate
        \(selectTab)
        end tell
        """
    }

    private static func itermFocusScript(tty: String?) -> String {
        let selectSession: String
        if let tty = tty {
            selectSession = """
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is equal to "\(tty)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            """
        } else {
            selectSession = ""
        }
        return """
        tell application "iTerm2"
            activate
        \(selectSession)
        end tell
        """
    }

    // MARK: - Enable / disable

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try installHooks()
            hooksInstalled = true
            requestNotificationPermission()
            start()
        } else {
            try uninstallHooks()
            hooksInstalled = false
            stop()
        }
    }

    // MARK: - Hook install

    static func checkHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }

        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(hookMarker) == true
                }
            }
        }
    }

    private func writeHookScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.sessionsDir, withIntermediateDirectories: true)
        try Self.hookScript.write(to: Self.hookScriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.hookScriptURL.path)
    }

    private func installHooks() throws {
        try writeHookScript()

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.settingsURL) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw SessionMonitorError.invalidSettingsJson
            }
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let ourEntry: [String: Any] = [
            "hooks": [["type": "command", "command": Self.hookScriptURL.path]]
        ]

        for event in Self.hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyInstalled = entries.contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(Self.hookMarker) == true
                }
            }
            if !alreadyInstalled {
                entries.append(ourEntry)
            }
            hooks[event] = entries
        }

        json["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.settingsURL, options: .atomic)
    }

    private func uninstallHooks() throws {
        if let data = try? Data(contentsOf: Self.settingsURL),
           var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var hooks = json["hooks"] as? [String: Any] {

            for (event, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { entry in
                    ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                        ($0["command"] as? String)?.contains(Self.hookMarker) == true
                    }
                }
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }

            if hooks.isEmpty {
                json.removeValue(forKey: "hooks")
            } else {
                json["hooks"] = hooks
            }

            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: Self.settingsURL.resolvingSymlinksInPath(), options: .atomic)
        }

        try? FileManager.default.removeItem(at: Self.baseDir)
    }

    /// POSIX sh script — no jq/python dependencies. Writes one JSON sidecar per session.
    static let hookScript = #"""
    #!/bin/sh
    # ClaudeUsage session status hook (installed by ClaudeUsage.app)
    # Reads the Claude Code hook event from stdin and writes a status sidecar
    # file that the ClaudeUsage menu bar app watches.
    # Sessions live beside this script, inside whichever config dir it was
    # installed into (~/.claude or $CLAUDE_CONFIG_DIR).
    DIR="$(dirname "$0")/sessions"
    mkdir -p "$DIR" 2>/dev/null
    INPUT=$(cat)

    get_field() {
      printf '%s' "$INPUT" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
    }

    SID=$(get_field session_id)
    EVENT=$(get_field hook_event_name)
    CWD=$(get_field cwd)
    MSG=""

    [ -n "$SID" ] || exit 0
    FILE="$DIR/$SID.json"

    case "$EVENT" in
      SessionEnd) rm -f "$FILE"; exit 0 ;;
      UserPromptSubmit|PostToolUse) STATUS="running" ;;
      Notification) STATUS="needs_attention"; MSG=$(get_field message) ;;
      Stop) STATUS="finished" ;;
      *) exit 0 ;;
    esac

    esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

    # Terminal identity for click-to-focus. Hooks run without a controlling
    # terminal, so walk up the process tree to the claude process, which has one.
    PID=$$
    TTY=""
    HOPS=0
    while [ "$PID" -gt 1 ] && [ "$HOPS" -lt 10 ]; do
      T=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
      if [ -n "$T" ] && [ "$T" != "??" ]; then TTY=$T; break; fi
      PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
      [ -z "$PID" ] && break
      HOPS=$((HOPS+1))
    done

    printf '{"session_id":"%s","status":"%s","cwd":"%s","message":"%s","term_program":"%s","tty":"%s","updated_at":%s}\n' \
      "$(esc "$SID")" "$STATUS" "$(esc "$CWD")" "$(esc "$MSG")" "$(esc "${TERM_PROGRAM:-}")" "$(esc "$TTY")" "$(date +%s)" > "$FILE"
    exit 0
    """#
}

enum SessionMonitorError: LocalizedError {
    case invalidSettingsJson

    var errorDescription: String? {
        switch self {
        case .invalidSettingsJson:
            return "settings.json is not valid JSON — not modifying it"
        }
    }
}
