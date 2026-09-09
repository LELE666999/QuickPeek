// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "QuickPeekTimeline", platforms: [.macOS(.v15)], products: [.library(name: "QuickPeekTimeline", targets: ["QuickPeekTimeline"])], dependencies: [.package(path: "../TimelineKit")], targets: [.target(name: "QuickPeekTimeline", dependencies: [.product(name: "TimelineKitCore", package: "TimelineKit")]), .testTarget(name: "QuickPeekTimelineTests", dependencies: ["QuickPeekTimeline"])])
