// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "telnyx-webrtc-ios",
    platforms: [
        .iOS(.v13),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "telnyx-webrtc-ios",
            targets: ["TelnyxRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.8")
    ],
    targets: [
        .target(
            name: "TelnyxRTC",
            dependencies: [
                .product(name: "Starscream", package: "Starscream"),
                "WebRTC"
            ],
            path: "TelnyxRTC",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // webrtc-sdk's build of the same M150 base as stasel/WebRTC 150.0.0, taken from the
        // release that https://github.com/webrtc-sdk/Specs 150.7871.01 points at. It adds
        // RTCPeerConnectionFactory.audioDeviceModule (per-process input/output device selection),
        // which the stock binary lacks on macOS. Module name (WebRTC) and type prefix (RTC) are
        // unchanged. Declared as a binary target rather than depending on the Specs package
        // because that package's manifest declares tools-version 5.9 but uses `.visionOS(.v26)`
        // (PackageDescription 6.2), so it fails to compile on any SwiftPM, whatever tools-version
        // the dependent package declares: https://github.com/webrtc-sdk/Specs/issues/31 (open, no
        // fixed tag as of 2026-10-09). Specs' manifest is itself this one binary target with the
        // same URL and checksum, so the exact pin here is the intended form, not a workaround.
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip",
            checksum: "03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa"
        )
    ],
    swiftLanguageVersions: [.v5]
)
