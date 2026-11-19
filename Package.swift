// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Headroom",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Headroom",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SystemConfiguration"),
                // Sparkle.framework: in Contents/Frameworks of the app, next to the binary in .build for dev runs.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
        .testTarget(
            name: "HeadroomTests",
            dependencies: ["Headroom"],
            path: "Tests/HeadroomTests"
        ),
    ]
)
