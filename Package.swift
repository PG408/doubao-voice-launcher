// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "DoubaoVoiceSwitch",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "DoubaoVoiceSwitch", targets: ["DoubaoVoiceSwitch"]),
    .library(name: "DoubaoVoiceSwitchCore", targets: ["DoubaoVoiceSwitchCore"]),
    .executable(
      name: "DoubaoVoiceSwitchCoreBehaviorTests",
      targets: ["DoubaoVoiceSwitchCoreBehaviorTests"]
    )
  ],
  targets: [
    .executableTarget(
      name: "DoubaoVoiceSwitch",
      dependencies: ["DoubaoVoiceSwitchCore"],
      resources: [.copy("Resources")]
    ),
    .target(name: "DoubaoVoiceSwitchCore"),
    .executableTarget(
      name: "DoubaoVoiceSwitchCoreBehaviorTests",
      dependencies: ["DoubaoVoiceSwitchCore"],
      path: "Tests/DoubaoVoiceSwitchCoreBehaviorTests"
    )
  ]
)
