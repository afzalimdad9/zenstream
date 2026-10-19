// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenStream",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ZenStream", targets: ["ZenStream"])],
    targets: [.executableTarget(name: "ZenStream")]
)
