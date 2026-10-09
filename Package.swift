// swift-tools-version: 5.8

// Swift Playgrounds の「App」形式パッケージです。
// 開けない場合は Playgrounds で新規 App を作成し、ContentView.swift 等を消して
// このフォルダ内の .swift ファイルをすべてコピーしてください。

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "MalodySlideEditor",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .iOSApplication(
            name: "MalodySlideEditor",
            targets: ["AppModule"],
            bundleIdentifier: "local.malody.slideeditor",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .map),
            accentColor: .presetColor(.cyan),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
