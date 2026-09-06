// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SentientContext",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SentientContext", targets: ["SentientContext"])],
    targets: [
        .target(name: "SentientContext", path: "Sentient OS macOS/Context", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "ContextTests", dependencies: ["SentientContext"], path: "Tests/ContextTests")
    ]
)
