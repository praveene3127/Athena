// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Athena",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "Athena",
            targets: ["Athena"]
        ),
    ],
    targets: [
        .target(
            name: "Athena",
            path: "Runner",
            exclude: [
                "Assets.xcassets",
                "Base.lproj",
                "Info.plist",
                "Info-Debug.plist",
                "Runner.entitlements",
                "PrivacyInfo.xcprivacy"
            ],
            sources: [
                "AppDelegate.swift",
                "SceneDelegate.swift"
            ]
        ),
    ]
)
