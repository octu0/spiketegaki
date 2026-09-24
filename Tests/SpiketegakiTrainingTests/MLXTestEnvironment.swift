import Foundation
import XCTest

/// MLX を実際に呼ぶ前に、Metal カーネル (metallib) が使えるかを判定する。
///
/// mlx-swift の Metal シェーダは Xcode のビルドルールでしか作られない
/// (mlx-swift の README: "SwiftPM (command line) cannot build the Metal shaders")。
/// SwiftPM だけでビルドした `swift test -c release` の実行ファイルには metallib が同梱されず、
/// MLX に触れた瞬間に "Failed to load the default metallib" で落ちる。MLX の Scheduler は
/// 既定 GPU ストリームを無条件に作るため、CPU デバイスを選んでも回避できない。
///
/// そこで **MLX を 1 度も呼ばずに** metallib の有無を調べ、無ければ XCTSkip する。
/// MLX を含むテストは `make xtest` (xcodebuild) で実行する。
///
/// 判定の限界:
/// - mlx の `load_default_library` が探すパス (実行ファイルと同じ階層の `mlx.metallib` /
///   `Resources/mlx.metallib`、SwiftPM バンドル `mlx-swift_Cmlx` の `default.metallib`) を
///   模倣しているだけで、mlx 本体と同じ実装ではない。将来 mlx が探索順を変えると食い違う。
/// - `Bundle.allFrameworks` の総なめはしない。OS 付属フレームワークの `default.metallib` を
///   拾って「ある」と誤判定し、結局クラッシュしたため。
/// - metallib が「存在するが読めない / 版が合わない」場合は検出できず、従来どおり落ちる。
/// - 誤判定の向きは安全側 (見つからなければ skip) に倒してある。実行されずに PASS することはない。
enum MLXTestEnvironment {
    /// 強制スキップの環境変数。CI などで MLX テストを外したいとき用
    static let skipEnvironmentKey = "SPIKETEGAKI_SKIP_MLX_TESTS"

    /// metallib が見つからなければ XCTSkip を投げる
    static func skipIfMetallibUnavailable(file: StaticString = #filePath, line: UInt = #line) throws {
        if let flag = ProcessInfo.processInfo.environment[skipEnvironmentKey], flag.isEmpty != true, flag != "0" {
            throw XCTSkip(
                "\(skipEnvironmentKey)=\(flag) が設定されているため MLX テストをスキップする",
                file: file,
                line: line
            )
        }
        if metallibURL() == nil {
            throw XCTSkip(
                "MLX metallib not available under SwiftPM; run make xtest "
                    + "(xcodebuild が Metal シェーダをビルドする。Metal Toolchain の導入が必要: "
                    + "xcodebuild -downloadComponent MetalToolchain)",
                file: file,
                line: line
            )
        }
    }

    /// 見つかった metallib のパス (テスト・報告用)。
    ///
    /// mlx の `load_default_library` と同じ 2 経路だけを見る。
    /// `Bundle.allFrameworks` を総なめすると OS 付属フレームワークの `default.metallib` に
    /// 当たって誤検出するので、探索範囲は意図的に狭めている。
    static func metallibURL() -> URL? {
        let manager = FileManager.default

        // 1. 実行ファイルと同じ階層の mlx.metallib / Resources/mlx.metallib
        var colocatedDirectories: [URL] = []
        let testBundle = Bundle(for: MLXTestEnvironmentMarker.self)
        if let executableURL = testBundle.executableURL {
            colocatedDirectories.append(executableURL.deletingLastPathComponent())
        }
        colocatedDirectories.append(testBundle.bundleURL.deletingLastPathComponent())
        if let mainExecutable = Bundle.main.executableURL {
            colocatedDirectories.append(mainExecutable.deletingLastPathComponent())
        }
        for directory in colocatedDirectories {
            for relative in ["mlx.metallib", "Resources/mlx.metallib"] {
                let candidate = directory.appendingPathComponent(relative)
                if manager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // 2. SwiftPM のリソースバンドル mlx-swift_Cmlx の default.metallib
        let bundleName = "mlx-swift_Cmlx.bundle"
        var searchRoots = colocatedDirectories
        searchRoots.append(testBundle.bundleURL)
        if let resourceURL = testBundle.resourceURL {
            searchRoots.append(resourceURL)
        }
        for root in searchRoots {
            let packageBundleURL = root.appendingPathComponent(bundleName)
            guard let packageBundle = Bundle(url: packageBundleURL) else {
                continue
            }
            if let resourceURL = packageBundle.resourceURL {
                let candidate = resourceURL.appendingPathComponent("default.metallib")
                if manager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

/// `Bundle(for:)` でテストバンドルを取るためだけのクラス
private final class MLXTestEnvironmentMarker {}
