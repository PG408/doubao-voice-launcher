// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DoubaoVoiceLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DoubaoVoiceLauncher", targets: ["DoubaoVoiceLauncher"])
    ],
    targets: [
        .executableTarget(
            name: "DoubaoVoiceLauncher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
