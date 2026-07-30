//
//  SettingsView.swift
//  GrokUsageBar
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        Form {
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
                Toggle("Alert at 80% and 100%", isOn: $store.notificationsEnabled)
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
        .frame(width: 420, height: 340)
        .padding()
    }
}
