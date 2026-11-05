// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "terminal-mac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "terminal-mac", targets: ["TerminalMac"])],
    targets: [
        .target(name: "TerminalMacCore", resources: [.copy("Signing")]),
        .target(name: "CPhoneShim"),
        .target(name: "TerminalUI", dependencies: ["CPhoneShim", "TerminalMacCore"]),
        .executableTarget(name: "TerminalMac", dependencies: ["TerminalMacCore", "TerminalUI", "CPhoneShim"],
            linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("AppKit"),
                             .linkedFramework("ScreenCaptureKit"), .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement"), .linkedFramework("CoreMedia")]),
        .testTarget(name: "TerminalMacCoreTests", dependencies: ["TerminalMacCore", "TerminalUI"])
    ],
    swiftLanguageModes: [.v5]
)
