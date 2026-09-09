// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TimelineKit", platforms: [.macOS(.v15)], products: [.library(name: "TimelineKitCore", targets: ["TimelineKitCore"])], targets: [.target(name: "TimelineKitCore")])
