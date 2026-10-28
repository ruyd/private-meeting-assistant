// swift-tools-version: 5.10
import PackageDescription

// SpeexDSP's MDF acoustic echo canceller, vendored from SpeexDSP 1.2.1. See README.md.
let package = Package(
    name: "SpeexDSP",
    products: [.library(name: "SpeexDSP", targets: ["SpeexDSP"])],
    targets: [
        .target(
            name: "SpeexDSP",
            path: "Sources/SpeexDSP",
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("include"),
            ]
        ),
    ]
)
