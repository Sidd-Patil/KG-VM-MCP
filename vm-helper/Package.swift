// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VMHelper",
    platforms: [
        .macOS(.v13)   // Virtualization.framework requires macOS 13+
    ],
    targets: [
        .executableTarget(
            name: "VMHelper",
            path: "Sources/VMHelper"
            // Virtualization.framework is automatically linked on macOS 13+
            // No entitlements needed: we use VZNATNetworkDeviceAttachment only
        )
    ]
)
