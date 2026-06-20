// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "DoubaoVoiceLauncher",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "DoubaoVoiceLauncher", targets: ["DoubaoVoiceLauncher"]),
    .library(name: "DoubaoVoiceLauncherCore", targets: ["DoubaoVoiceLauncherCore"]),
    .executable(
      name: "DoubaoVoiceLauncherCoreBehaviorTests",
      targets: ["DoubaoVoiceLauncherCoreBehaviorTests"]
    )
  ],
  targets: [
    .executableTarget(
      name: "DoubaoVoiceLauncher",
      dependencies: ["DoubaoVoiceLauncherCore"],
      resources: [.copy("Resources")]
    ),
    .target(name: "DoubaoVoiceLauncherCore"),
    .executableTarget(
      name: "DoubaoVoiceLauncherCoreBehaviorTests",
      dependencies: ["DoubaoVoiceLauncherCore"],
      path: "Tests/DoubaoVoiceLauncherCoreBehaviorTests"
    )
  ]
)
