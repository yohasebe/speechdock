// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypeTalk",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1")
    ],
    targets: [
        .executableTarget(
            name: "TypeTalk",
            dependencies: ["HotKey"],
            path: ".",
            exclude: ["Package.swift", "project.yml", "Resources"],
            sources: ["App", "Models", "Services", "Views", "Utilities"]
        )
    ]
)
