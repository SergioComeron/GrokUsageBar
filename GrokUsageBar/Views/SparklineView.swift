//
//  SparklineView.swift
//  GrokUsageBar
//
//  Compact monthly usage bars for the menu panel.
//

import SwiftUI

struct SparklineView: View {
    let points: [UsageHistoryPoint]
    var barColor: Color = .accentColor

    private let minBarHeight: CGFloat = 3

    var body: some View {
        if points.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("History")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    let maxValue = max(points.map(\.totalUsed).max() ?? 0, 1)
                    let spacing: CGFloat = 4
                    let count = CGFloat(points.count)
                    let barWidth = max(4, (geo.size.width - spacing * (count - 1)) / count)

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(points) { point in
                            let ratio = CGFloat(point.totalUsed / maxValue)
                            let height = max(minBarHeight, geo.size.height * ratio)

                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(point.isCurrent ? barColor : barColor.opacity(0.45))
                                .frame(width: barWidth, height: height)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .help(tooltip(for: point))
                                .accessibilityLabel(tooltip(for: point))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 36)

                HStack {
                    if let first = points.first {
                        Text(first.monthLabel)
                    }
                    Spacer()
                    if let last = points.last {
                        Text(last.isCurrent ? "\(last.monthLabel) · now" : last.monthLabel)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func tooltip(for point: UsageHistoryPoint) -> String {
        let amount: String
        if point.totalUsed >= 100 || point.totalUsed.rounded() == point.totalUsed {
            amount = String(format: "%.0f", point.totalUsed)
        } else {
            amount = String(format: "%.1f", point.totalUsed)
        }
        let tag = point.isCurrent ? " (current)" : ""
        return "\(point.monthLabel) \(point.year): \(amount)\(tag)"
    }
}
