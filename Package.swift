// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "rm-key",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "Clibssh2",
            pkgConfig: "libssh2",
            providers: [
                .brew(["libssh2"]),
            ]
        ),
        .executableTarget(
            name: "RMKeyApp",
            dependencies: ["Clibssh2"],
            path: "Sources/RMKeyApp",
            resources: [.process("Resources")]
        ),
    ]
)
