// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "VanishCam",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VanishCore", path: "Sources/VanishCore"),
        .executableTarget(name: "vanishcam", dependencies: ["VanishCore"], path: "Sources/vanishcam",
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/vanishcam/Info.plist"])]),
        .executableTarget(name: "VanishCamApp", dependencies: ["VanishCore"], path: "Sources/VanishCamApp",
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/VanishCamApp/Info.plist"])]),
        .testTarget(name: "VanishCoreTests", dependencies: ["VanishCore"], path: "Tests/VanishCoreTests"),
    ]
)
