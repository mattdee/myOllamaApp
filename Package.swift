// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OllamaChat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "OllamaChat"),
        .testTarget(name: "OllamaChatTests", dependencies: ["OllamaChat"])
    ]
)
