//
//  GrokUsageBarApp.swift
//  GrokUsageBar
//
//  Menu bar utility that mirrors Grok Build's /usage credit percentage.
//

import SwiftUI

@main
struct GrokUsageBarApp: App {
    @StateObject private var usageStore = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(usageStore)
        } label: {
            MenuBarLabel()
                .environmentObject(usageStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(usageStore)
        }
    }
}
