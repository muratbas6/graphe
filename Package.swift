// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Graphe",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Graphe", targets: ["Graphe"]),
        .library(name: "GrapheCore", targets: ["GrapheCore"])
    ],
    targets: [
        .target(
            name: "GrapheCore",
            path: "Sources/GrapheCore"
        ),
        .executableTarget(
            name: "Graphe",
            dependencies: ["GrapheCore"],
            path: "Sources/Graphe"
        ),
        .executableTarget(
            name: "GrapheSelfTest",
            dependencies: ["GrapheCore"],
            path: "Sources/GrapheSelfTest"
        )
    ]
)
