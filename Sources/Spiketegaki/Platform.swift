// 推論ライブラリが使う標準ライブラリの入口。**import をここ 1 点にまとめる。**
//
// macOS では Foundation、WASI では FoundationEssentials + WASILibc を使う。
// SwiftWasm の Foundation は FoundationInternationalization 経由で ICU のデータ
// (約 34 MB) を抱き込むため、そのままでは wasm が 44 MB になる。推論に要るのは
// Data / URL / JSON と libm の数学関数だけなので、WASI では国際化の要らない
// FoundationEssentials に寄せる (同条件で wasm-opt 後 7.6 MB)。
//
// `canImport(FoundationEssentials)` ではなく `os(WASI)` で分岐するのは、
// macOS 側では従来どおり Foundation をそのまま使い、挙動を変えないため。
#if os(WASI)
@_exported import FoundationEssentials
@_exported import WASILibc
#else
@_exported import Foundation
#endif
