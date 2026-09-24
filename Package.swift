// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "spiketegaki",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Spiketegaki",
            targets: ["Spiketegaki"]
        ),
        .library(
            name: "SpiketegakiTraining",
            targets: ["SpiketegakiTraining"]
        ),
        .executable(
            name: "vocab",
            targets: ["vocab"]
        ),
        .executable(
            name: "render",
            targets: ["render"]
        ),
        .executable(
            name: "train",
            targets: ["train"]
        ),
        .executable(
            name: "recognize",
            targets: ["recognize"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.21.0")
    ],
    targets: [
        // 推論ライブラリ。Foundation のみに依存する (将来 wasm に載せる前提)
        .target(
            name: "Spiketegaki",
            path: "Sources/Spiketegaki"
        ),
        // 学習ライブラリ。MLX (Metal GPU) に依存する
        .target(
            name: "SpiketegakiTraining",
            dependencies: [
                "Spiketegaki",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift")
            ],
            path: "Sources/SpiketegakiTraining"
        ),
        // CharacterTable.swift の生成器
        .executableTarget(
            name: "vocab",
            dependencies: ["Spiketegaki"],
            path: "script/vocab"
        ),
        // フォント → 画像 → DatasetFile (CoreText / CoreGraphics はここだけ)
        .executableTarget(
            name: "render",
            dependencies: ["Spiketegaki"],
            path: "script/render"
        ),
        // DatasetFile → MLX 学習 → 重み JSON
        .executableTarget(
            name: "train",
            dependencies: [
                "Spiketegaki",
                "SpiketegakiTraining",
                .product(name: "MLX", package: "mlx-swift")
            ],
            path: "script/train"
        ),
        // PNG 1 枚 → top-5 表示 (ImageIO はここだけ)
        .executableTarget(
            name: "recognize",
            dependencies: ["Spiketegaki"],
            path: "script/recognize"
        ),
        // フォント非依存の単体テスト
        .testTarget(
            name: "SpiketegakiTests",
            dependencies: ["Spiketegaki"],
            path: "Tests/SpiketegakiTests"
        ),
        // MLX ↔ CPU 推論の一致テスト、合成データの過学習テスト
        .testTarget(
            name: "SpiketegakiTrainingTests",
            dependencies: [
                "Spiketegaki",
                "SpiketegakiTraining",
                .product(name: "MLX", package: "mlx-swift")
            ],
            path: "Tests/SpiketegakiTrainingTests"
        )
    ]
)
