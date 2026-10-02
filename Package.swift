// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrollFix",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ScrollFix", targets: ["ScrollFix"])],
    targets: [
        .executableTarget(name: "ScrollFix"),
        .testTarget(name: "ScrollFixTests", dependencies: ["ScrollFix"])
    ]
)
