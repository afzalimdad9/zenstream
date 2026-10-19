// swift-tools-version: 5.9
import Foundation
import PackageDescription

let infoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/ZenStream/Info.plist")
    .path

let package = Package(
    name: "ZenStream",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ZenStream", targets: ["ZenStream"])],
    targets: [
        .executableTarget(
            name: "ZenStream",
            resources: [.copy("Info.plist")],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", infoPlistPath,
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        )
    ]
)
