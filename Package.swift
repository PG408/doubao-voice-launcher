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
        .target(name: "DoubaoVoiceLauncherCore"),
        .executableTarget(
            name: "DoubaoVoiceLauncher",
            dependencies: ["DoubaoVoiceLauncherCore"],
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .testTarget(
            name: "DoubaoVoiceLauncherCoreTests",
            dependencies: ["DoubaoVoiceLauncherCore"]
        )
    ]
)
