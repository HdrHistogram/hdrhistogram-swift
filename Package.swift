// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "package-histogram",
    platforms: [
        // specify each minimum deployment requirement,
        //otherwise the platform default minimum is used.
       .macOS(.v10_15),
       .iOS(.v13),
       .tvOS(.v13),
       .watchOS(.v6)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "Histogram",
            targets: ["Histogram"]),
        .executable(
            name: "HistogramExample",
            targets: ["HistogramExample"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.1.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "Histogram",
            dependencies: [
                .product(name: "Numerics", package: "swift-numerics"),
            ]),
        .executableTarget(
            name: "HistogramExample",
            dependencies: ["Histogram"]),
        .testTarget(
            name: "HistogramTests",
            dependencies: [
                "Histogram",
                .product(name: "Numerics", package: "swift-numerics"),
            ]),
    ]
)
