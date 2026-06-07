// swift-tools-version:5.1
import PackageDescription

#if os(Linux)
    let cOpenSSLRepo = "https://github.com/PerfectlySoft/Perfect-COpenSSL-Linux.git"
#else
    let cOpenSSLRepo = "https://github.com/PerfectlySoft/Perfect-COpenSSL.git"
#endif

let package = Package(
    name: "OpenCloudKit",
    platforms: [.iOS(.v13), .macOS(.v10_12)],
    products: [
        .library(name: "OpenCloudKit", targets: ["OpenCloudKit"]),
    ],
    dependencies: [
        .package(url: cOpenSSLRepo, from: "4.0.1"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.1.3"),
        // NIO-based HTTP client used for the binary CKAsset upload to the
        // pre-signed cws.icloud-content.com URL. Foundation's URLSession on
        // Linux stalls HTTP/2 uploads past the ~64 KB initial flow-control
        // window; AsyncHTTPClient honors WINDOW_UPDATE correctly. Already a
        // transitive dependency of the app, so it resolves cleanly.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.18.0"),
    ],
    targets: [
        .target(name: "OpenCloudKit", dependencies: [
            "COpenSSL",
            "CryptoSwift",
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
        ])
    ]
)
