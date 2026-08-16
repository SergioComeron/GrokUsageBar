//
//  LaunchAtLogin.swift
//  GrokUsageBar
//
//  Auto-start always launches /Applications/GrokUsageBar.app — never the
//  Debug/Xcode copy that last toggled the switch (SMAppService.mainApp
//  rebinds the login item to whichever bundle called register()).
//

import Darwin
import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static let preferenceKey = "openAtLogin"
    static let agentLabel = "com.sergiocomeron.GrokUsageBar.login"
    static let canonicalAppURL = URL(fileURLWithPath: "/Applications/GrokUsageBar.app")

    static var isRunningFromCanonicalInstall: Bool {
        Bundle.main.bundleURL.standardizedFileURL == canonicalAppURL.standardizedFileURL
    }

    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// User wants login, regardless of which binary is running.
    static var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: preferenceKey) as? Bool {
            return stored
        }
        return inferredEnabled
    }

    static var statusDescription: String {
        if !FileManager.default.fileExists(atPath: canonicalAppURL.path) {
            return "Install to /Applications first (./install.sh). Login always starts that copy."
        }
        if isEnabled {
            return "Starts /Applications/GrokUsageBar.app when you log in — not a Debug/Xcode build."
        }
        return "Not registered. When enabled, login starts /Applications/GrokUsageBar.app."
    }

    /// Enable or disable. Always targets the Applications copy.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        return apply(enabled: enabled)
    }

    /// Call once at launch: drop any Debug-bound SMAppService item and pin
    /// the LaunchAgent to /Applications if the user still wants login.
    static func reconcileOnLaunch() {
        if UserDefaults.standard.object(forKey: preferenceKey) == nil {
            UserDefaults.standard.set(inferredEnabled, forKey: preferenceKey)
        }
        _ = apply(enabled: isEnabled)
    }

    // MARK: - Apply

    private static var inferredEnabled: Bool {
        agentPlistPresent
            || smAppServiceActive
            || legacyLoginItemPresent
    }

    private static var agentPlistPresent: Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    private static var smAppServiceActive: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    private static var legacyLoginItemPresent: Bool {
        let script = """
        tell application "System Events"
          repeat with li in (get login items)
            if name of li is "GrokUsageBar" then return true
          end repeat
        end tell
        return false
        """
        return (try? runAppleScript(script))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private static func apply(enabled: Bool) -> String? {
        // SMAppService.mainApp is bound to *this* bundle URL. Never leave it
        // on: a later Debug run would steal login away from Applications.
        try? SMAppService.mainApp.unregister()
        removeLegacyLoginItems()

        guard enabled else {
            return removeAgent()
        }

        guard FileManager.default.fileExists(atPath: canonicalAppURL.path) else {
            return "GrokUsageBar is not in /Applications. Run ./install.sh, then try again."
        }

        if let error = installAgent() {
            return error
        }
        return nil
    }

    // MARK: - LaunchAgent (fixed path)

    private static func installAgent() -> String? {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", canonicalAppURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let dir = agentPlistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPlistURL, options: .atomic)
        } catch {
            return "Could not write login agent: \(error.localizedDescription)"
        }
        _ = launchctl(["bootout", guiDomain, agentLabel])
        let boot = launchctl(["bootstrap", guiDomain, agentPlistURL.path])
        if boot.status != 0 {
            let err = boot.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // Already loaded after a partial write — try kickstart via bootout/bootstrap once more.
            if !err.contains("already exists") && !err.isEmpty {
                return "Could not load login agent: \(err)"
            }
        }
        return nil
    }

    private static func removeAgent() -> String? {
        _ = launchctl(["bootout", guiDomain, agentLabel])
        if FileManager.default.fileExists(atPath: agentPlistURL.path) {
            do {
                try FileManager.default.removeItem(at: agentPlistURL)
            } catch {
                return "Could not remove login agent: \(error.localizedDescription)"
            }
        }
        return nil
    }

    private static var guiDomain: String {
        "gui/\(getuid())"
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let err = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Leftovers from the old SMAppService / System Events item

    private static func removeLegacyLoginItems() {
        let script = """
        tell application "System Events"
          set doomed to {}
          repeat with li in (get login items)
            if name of li is "GrokUsageBar" then
              set end of doomed to li
            end if
          end repeat
          repeat with li in doomed
            delete li
          end repeat
        end tell
        """
        _ = try? runAppleScript(script)
    }

    private static func runAppleScript(_ source: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "LaunchAtLogin",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr]
            )
        }
        return stdout
    }
}
