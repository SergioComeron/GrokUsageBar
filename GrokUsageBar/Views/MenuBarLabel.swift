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
            if store.isStale {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Stale")
            }
        }
        .opacity(store.isStale ? 0.55 : 1)
        .help(helpText)
    }

    private var labelText: String {
        switch store.state {
        case .loaded(let usage), .stale(let usage, _):
            // Weekly limit is the number that gates real usage (same as /usage).
            return usage.menuBarDisplay
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
            return detail(for: usage, stale: nil)
        case .stale(let usage, let reason):
            return detail(for: usage, stale: reason ?? "Refreshing")
        case .loading:
            return "Refreshing Grok usage…"
        case .needsLogin:
            return "Sign in with Grok"
        case .failed(let message):
            return message
        case .idle:
            return "Grok usage"
        }
    }

    private func detail(for usage: BillingUsage, stale: String?) -> String {
        let mock = store.isMockData ? " (mock)" : ""
        var parts: [String] = []
        if let stale {
            parts.append("Stale — \(stale)")
        }
        if let plan = usage.subscription {
            parts.append(plan.displayName)
        }
        parts.append("\(usage.periodKind.titleLabel) \(usage.percentDisplay)\(mock)")
        if let summary = usage.periodSummaryDisplay {
            parts.append(summary)
        }
        return parts.joined(separator: " · ")
    }
}
