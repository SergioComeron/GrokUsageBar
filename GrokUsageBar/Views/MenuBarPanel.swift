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
        .frame(width: 280)
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
            VStack(alignment: .leading, spacing: 8) {
                Label("No Grok session", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                Text("Run `grok login` in a terminal, then refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

    private func usageBlock(_ usage: BillingUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage.percentDisplay)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color(for: usage.usageLevel))
                Text("of period")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ProgressView(value: min(max(usage.creditUsagePercent, 0), 100), total: 100)
                .tint(color(for: usage.usageLevel))

            grid(usage)

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

    @ViewBuilder
    private func grid(_ usage: BillingUsage) -> some View {
        VStack(spacing: 4) {
            if let used = usage.totalUsed, let limit = usage.monthlyLimit {
                row("Used", formatUnits(used) + " / " + formatUnits(limit))
            } else if let used = usage.totalUsed {
                row("Used", formatUnits(used))
            }
            if let cap = usage.onDemandCap, cap > 0 {
                let onDemand = usage.onDemandUsed ?? 0
                row("On-demand", formatUnits(onDemand) + " / " + formatUnits(cap))
            }
            if let start = usage.billingPeriodStart, let end = usage.billingPeriodEnd {
                row(
                    "Period",
                    "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
                )
            }
        }
        .font(.caption)
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
        }
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
