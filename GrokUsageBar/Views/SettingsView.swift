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
                    Text("Usage alerts")
                }
                .toggleStyle(.switch)
                .tint(switchTint)
                ForEach(UsageAlertPolicy.catalog, id: \.self) { threshold in
                    Toggle(isOn: thresholdBinding(threshold)) {
                        Text("Alert at \(threshold)%")
                    }
                    .toggleStyle(.switch)
                    .tint(switchTint)
                    .disabled(!store.notificationsEnabled)
                }
                Toggle(isOn: $store.paceAlertsEnabled) {
                    Text("Alert if pace hits 100% before reset")
                }
                .toggleStyle(.switch)
                .tint(switchTint)
                .disabled(!store.notificationsEnabled)
                Text("Each alert fires once per billing period. 80% and 100% are on by default. Requires notification permission in System Settings.")
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
                    Button("Sign out") {
                        store.signOut()
                    }
                    Text("Removes this Grok account from ~/.grok/auth.json. API keys and any other accounts in that file stay. If this is the only account, the Grok CLI has to sign in again too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let signOutError = store.signOutError {
                        Text(signOutError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("No session")
                        .foregroundStyle(.secondary)
                    Button("Sign in with Grok") {
                        store.startLogin()
                    }
                    if case .waiting(let userCode, _) = store.loginProgress {
                        Text("Code: \(userCode)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if case .failed(let message) = store.loginProgress {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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
        .frame(width: 440, height: 640)
        .padding()
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginDetail = LaunchAtLogin.statusDescription
        }
    }

    private func thresholdBinding(_ threshold: Int) -> Binding<Bool> {
        Binding(
            get: { store.alertThresholds.contains(threshold) },
            set: { enabled in
                if enabled {
                    store.alertThresholds.insert(threshold)
                } else {
                    store.alertThresholds.remove(threshold)
                }
            }
        )
    }
}
