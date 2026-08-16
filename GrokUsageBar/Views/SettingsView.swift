//
//  SettingsView.swift
//  GrokUsageBar
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?
    @State private var launchAtLoginDetail = LaunchAtLogin.statusDescription

    /// System accent so ON switches light up even in LSUIElement / dark Settings windows.
    private var switchTint: Color {
        Color(nsColor: .controlAccentColor)
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle(isOn: $launchAtLogin) {
                    Text("Open at login")
                }
                .toggleStyle(.switch)
                .tint(switchTint)
                .onChange(of: launchAtLogin) { _, newValue in
                    if let error = LaunchAtLogin.setEnabled(newValue) {
                        launchAtLoginMessage = error
                        // Re-sync UI with system state after failure.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    } else {
                        launchAtLoginMessage = nil
                    }
                    launchAtLoginDetail = LaunchAtLogin.statusDescription
                }
                Text(launchAtLoginDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !LaunchAtLogin.isRunningFromCanonicalInstall {
                    Text("This is not the /Applications copy. Login still starts /Applications/GrokUsageBar.app.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Refresh") {
                Stepper(
                    value: $store.refreshIntervalMinutes,
                    in: 1...120,
                    step: 1
                ) {
                    Text("Every \(Int(store.refreshIntervalMinutes)) minutes")
                }
            }

            Section("Notifications") {
                Toggle(isOn: $store.notificationsEnabled) {
                    Text("Alert at 80% and 100%")
                }
                .toggleStyle(.switch)
                .tint(switchTint)
                Text("Fires once per billing period for each threshold. Requires notification permission in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Session") {
                LabeledContent("Auth file") {
                    Text("~/.grok/auth.json")
                        .foregroundStyle(.secondary)
                }
                if let email = store.sessionEmail {
                    LabeledContent("Account", value: email)
                } else {
                    Text("No session — run grok login")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Data source") {
                LabeledContent("Provider") {
                    Text(store.isMockData ? "Mock" : "Live (cli-chat-proxy)")
                        .foregroundStyle(store.isMockData ? .orange : .secondary)
                }
                Text("GET https://cli-chat-proxy.grok.com/v1/billing with your Grok Build session token. Force mock with GROK_USAGE_MOCK=1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 430)
        .padding()
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginDetail = LaunchAtLogin.statusDescription
        }
    }
}
