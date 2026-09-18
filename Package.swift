// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IINACompanionMenu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "IINACompanionMenu", targets: ["IINACompanionMenu"]),
    ],
    targets: [
        .executableTarget(name: "IINACompanionMenu"),
    ]
)
