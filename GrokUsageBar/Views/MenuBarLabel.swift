//
//  MenuBarLabel.swift
//  GrokUsageBar
//

import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        // MenuBarExtra prefers a compact HStack of image + text.
        // GrokLogo is a template asset (black glyph) so it follows menu-bar tint.
        HStack(spacing: 4) {
            Image("GrokLogo")
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text(labelText)
                .monospacedDigit()
        }
        .help(helpText)
    }

    private var labelText: String {
        switch store.state {
        case .loaded(let usage):
            return usage.percentDisplay
        case .loading:
            return "…"
        case .needsLogin:
            return "—"
        case .failed:
            return "!"
        case .idle:
            return "Grok"
        }
    }

    private var helpText: String {
        switch store.state {
        case .loaded(let usage):
            let mock = store.isMockData ? " (mock)" : ""
            return "Grok usage \(usage.percentDisplay)\(mock)"
        case .loading:
            return "Refreshing Grok usage…"
        case .needsLogin:
            return "Sign in with grok login"
        case .failed(let message):
            return message
        case .idle:
            return "Grok usage"
        }
    }
}
