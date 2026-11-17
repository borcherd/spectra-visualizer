// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spectra",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "Spectra", path: "Sources/Spectra")
    ]
)
