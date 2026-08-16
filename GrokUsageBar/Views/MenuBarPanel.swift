//
//  MenuBarPanel.swift
//  GrokUsageBar
//

import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("GrokLogo")
                .resizable()
                .renderingMode(.template)
                .frame(width: 22, height: 22)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Grok usage")
                    .font(.headline)
                if let email = store.sessionEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let plan = store.usage?.subscription {
                Text(plan.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
                    .help(plan.rawTier.map { "JWT tier \($0)" } ?? plan.displayName)
            }
            if store.isMockData {
                Text("MOCK")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .needsLogin:
            loginBlock

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Could not load usage", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .loaded(let usage):
            usageBlock(usage)
        }
    }

    @ViewBuilder
    private var loginBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No Grok session", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)

            switch store.loginProgress {
            case .idle:
                Text("Sign in with your Grok account. Grok Build does not need to be open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Sign in with Grok") {
                    store.startLogin()
                }
                .keyboardShortcut("l", modifiers: .command)

            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting sign-in…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .waiting(let userCode, let url):
                Text("Finish in the browser that just opened. If it didn’t, use this code at accounts.x.ai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(userCode)
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                HStack {
                    Button("Open browser again") {
                        NSWorkspace.shared.open(url)
                    }
                    Button("Cancel") {
                        store.cancelLogin()
                    }
                }

            case .finishing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving session…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    store.startLogin()
                }
            }
        }
    }

    private func usageBlock(_ usage: BillingUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Primary: weekly (or period) limit — same number as CLI /usage.
            HStack(alignment: .firstTextBaseline) {
                Text(usage.percentDisplay)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color(for: usage.usageLevel))
                VStack(alignment: .leading, spacing: 1) {
                    Text(usage.periodKind.titleLabel)
                        .font(.subheadline.weight(.medium))
                    Text("of \(usage.periodKind.shortLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let plan = usage.subscription {
                row("Plan", plan.displayName)
            }

            ProgressView(value: min(max(usage.creditUsagePercent, 0), 100), total: 100)
                .tint(color(for: usage.usageLevel))

            // Personal 7-day window from xAI (not Mon–Sun). Show range + countdown.
            if usage.periodRangeDisplay != nil || usage.nextResetDisplay != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(usage.periodKind == .weekly ? "Your week" : "Period")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let range = usage.periodRangeDisplay {
                        row("Window", range)
                    }
                    if let rel = usage.resetInDisplay {
                        row("Resets", rel)
                    }
                    if let abs = usage.nextResetDisplay {
                        row("At", abs)
                    }
                    if usage.periodKind == .weekly {
                        Text("Rolling 7 days from your account — not the calendar week.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }

            if !usage.productUsage.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("By product")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(usage.productUsage.sorted { $0.usagePercent > $1.usagePercent }) { item in
                        HStack {
                            Text(item.displayName)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(BillingUsage.formatPercent(item.usagePercent))
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 2)
            }

            // Secondary: monthly credit units (pool), when the API still exposes it.
            if let used = usage.monthlyUsed, let limit = usage.monthlyLimit, limit > 0 {
                Divider().padding(.vertical, 2)
                let monthPct = (used / limit) * 100
                VStack(alignment: .leading, spacing: 4) {
                    Text("Monthly credits")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    row("Used", formatUnits(used) + " / " + formatUnits(limit)
                        + "  (\(BillingUsage.formatPercent(monthPct)))")
                }
            }

            if let cap = usage.onDemandCap, cap > 0 {
                let onDemand = usage.onDemandUsed ?? 0
                row("On-demand", formatUnits(onDemand) + " / " + formatUnits(cap))
            }

            if usage.history.count >= 2 {
                SparklineView(
                    points: usage.history,
                    barColor: color(for: usage.usageLevel)
                )
            }

            Text("Updated \(usage.fetchedAt, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Billing vals look like credit units (e.g. 15000 monthly); show without currency noise.
    private func formatUnits(_ value: Double) -> String {
        if value >= 100 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                Task { await store.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Billing…") {
                store.openBillingPage()
            }

            SettingsLink {
                Text("Settings…")
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func color(for level: UsageLevel) -> Color {
        switch level {
        case .ok: return .green
        case .warn: return .orange
        case .high: return .red
        case .unknown: return .secondary
        }
    }
}
