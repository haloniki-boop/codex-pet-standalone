// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexPetStandalone",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexPetStandalone", targets: ["CodexPetStandalone"])
    ],
    targets: [
        .executableTarget(
            name: "CodexPetStandalone"
        )
    ]
)
