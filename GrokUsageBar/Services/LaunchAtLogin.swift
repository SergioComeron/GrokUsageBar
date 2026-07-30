//
//  LaunchAtLogin.swift
//  GrokUsageBar
//
//  Registers the main app as a macOS login item via SMAppService (macOS 13+).
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// Whether the system currently has this app registered to open at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Human-readable status for Settings.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Opens automatically when you log in."
        case .notRegistered:
            return "Not registered as a login item."
        case .notFound:
            return "App bundle not found for registration. Run the built .app (not a raw binary)."
        case .requiresApproval:
            return "Waiting for approval in System Settings → General → Login Items."
        @unknown default:
            return "Unknown login item status."
        }
    }

    /// Enable or disable launch at login. Returns an error message on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .enabled { return nil }
                try service.register()
            } else {
                if service.status == .notRegistered { return nil }
                try service.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
