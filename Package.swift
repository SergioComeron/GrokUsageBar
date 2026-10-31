// swift-tools-version:5.9
// The menu-bar app itself is GrokUsageBar.xcodeproj (AppKit). This package
// compiles the Foundation-only sources so `swift test` can run on Linux,
// where xcodebuild is not available.
import PackageDescription

let package = Package(
    name: "GrokUsageBarCore",
    targets: [
        .target(
            name: "GrokUsageBarCore",
            path: "GrokUsageBar",
            exclude: [
                "Assets.xcassets",
                "GrokUsageBar.entitlements",
                "GrokUsageBarApp.swift",
                "Services/LaunchAtLogin.swift",
                "Services/UsageNotifier.swift",
                "Services/UsageStore.swift",
                "Views",
            ],
            sources: [
                "Models/BillingUsage.swift",
                "Models/UsagePace.swift",
                "Services/BillingService.swift",
                "Services/GrokAuthFileLock.swift",
                "Services/GrokAuthStore.swift",
                "Services/GrokDeviceLogin.swift",
                "Services/GrokHTTP.swift",
                "Services/RefreshCoalescer.swift",
                "Services/UsageAlertPolicy.swift",
            ]
        ),
        .testTarget(
            name: "GrokUsageBarCoreTests",
            dependencies: ["GrokUsageBarCore"],
            path: "Tests/GrokUsageBarCoreTests"
        ),
    ]
)
