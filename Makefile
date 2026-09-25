# spiketegaki Build & Run Makefile
# SNN (Spiking Neural Network) による日本語手書き 1 文字認識
#
# ビルド構成は Release 固定。-c release 無しと -c debug は禁止 (SIMD が効かず極端に遅い)。

CONFIG := release

# wasm (SwiftWasm) ビルドの設定。既定の swift は Xcode 付属なので、
# SDK と同じバージョンのツールチェーンを swiftly 経由で呼ぶ
WASM_TOOLCHAIN := 6.2.3
WASM_SDK := swift-6.2.3-RELEASE_wasm
WASM_TRIPLE := wasm32-unknown-wasip1
# wasm の SIMD128 を有効にする target-cpu。
# 既定 (mvp) では Swift の SIMD8<Float> が 1 命令も v128 にならず全部スカラーに落ちる。
# 2026-09-25 実測 (kana_R7、node demo/check.mjs --limit 1000、同一負荷で交互に測定):
#   mvp 29.11 ms/件 -> bleeding-edge 14.31 ms/件 (2.03 倍)、予測は top-1/top-5 とも完全一致、
#   サイズは 7,642,510 -> 7,644,252 バイト (+1,742)。
# LLVM の WebAssembly バックエンドが持つ CPU は mvp / generic / bleeding-edge の 3 つだけで、
# simd128 だけを選ぶ手段が無い。bleeding-edge は simd128 のほかに atomics と tail-call も使うため、
# デモに必要なブラウザが Chrome 112+ / Firefox 121+ / Safari 18.2+ に上がる。
# 元に戻すときは mvp にする (wasm-opt の --enable-simd は付けたままで害はない)。
WASM_CPU := bleeding-edge
DEMO_DIR := .tmp/demo
DEMO_PORT := 8080

# 各 script への引数 (例: make render ARGS="--scripts hiragana")
ARGS ?=

.PHONY: all build test xbuild xtest xtrain vocab render recognize wasm demo clean help

all: build test

## パッケージ全体を Release ビルド
build:
	swift build -c $(CONFIG)

## 全ユニットテストを Release 構成で実行
test:
	swift test -c $(CONFIG)

## MLX を含むターゲットを xcodebuild で Release ビルド
## (mlx-swift の Metal シェーダは SwiftPM CLI では作れない。要 Metal Toolchain)
xbuild:
	xcodebuild build -scheme spiketegaki-Package -destination 'platform=macOS' -configuration $(CONFIG)

## MLX を含むテスト (SpiketegakiTrainingTests) を xcodebuild で実行
xtest:
	xcodebuild test -scheme spiketegaki-Package -destination 'platform=macOS' -configuration $(CONFIG) ENABLE_TESTABILITY=YES

## DatasetFile を用いた MLX 学習と held-out 評価 (引数: ARGS="...")。学習はこのターゲットだけ。
## swift run では mlx-swift の metallib が無く "Failed to load the default metallib" で落ちるため、
## xcodebuild が作ったバイナリを直接呼ぶ
xtrain: xbuild
	@BIN=$$(ls -1d $$HOME/Library/Developer/Xcode/DerivedData/spiketegaki-*/Build/Products/Release/train | head -n 1); \
		if [ -z "$$BIN" ]; then echo "train のバイナリが見つかりません (make xbuild を先に)"; exit 1; fi; \
		echo "$$BIN $(ARGS)"; "$$BIN" $(ARGS)

## CharacterTable.swift の生成 (引数: ARGS="...")
vocab:
	swift run -c $(CONFIG) vocab $(ARGS)

## フォント → 画像 → DatasetFile の生成 (引数: ARGS="...")
render:
	swift run -c $(CONFIG) render $(ARGS)

## PNG 1 枚の top-5 認識 (引数: ARGS="...")
recognize:
	swift run -c $(CONFIG) recognize $(ARGS)

## SwiftWasm SDK で wasm をビルドし、wasm-opt -Oz をかけて $(DEMO_DIR) に置く
wasm:
	swiftly run +$(WASM_TOOLCHAIN) swift build -c $(CONFIG) --swift-sdk $(WASM_SDK) --product SpiketegakiWASM -Xswiftc -target-cpu -Xswiftc $(WASM_CPU)
	@mkdir -p $(DEMO_DIR)
	wasm-opt -Oz --strip-debug --enable-simd -o $(DEMO_DIR)/spiketegaki.wasm .build/$(WASM_TRIPLE)/$(CONFIG)/SpiketegakiWASM.wasm
	@ls -l .build/$(WASM_TRIPLE)/$(CONFIG)/SpiketegakiWASM.wasm $(DEMO_DIR)/spiketegaki.wasm

## デモ一式を $(DEMO_DIR) に置いて http://localhost:$(DEMO_PORT)/ で配信する
## (先に make wasm と recognize --export-weights が要る)
demo:
	@mkdir -p $(DEMO_DIR)
	cp demo/index.html demo/main.js $(DEMO_DIR)/
	@test -f $(DEMO_DIR)/spiketegaki.wasm || echo "警告: $(DEMO_DIR)/spiketegaki.wasm がありません (make wasm)"
	@test -f $(DEMO_DIR)/kana.stgw || echo "警告: $(DEMO_DIR)/kana.stgw がありません (recognize --export-weights)"
	python3 -m http.server $(DEMO_PORT) --directory $(DEMO_DIR)

## ビルド成果物のクリーン
clean:
	swift package clean

## ヘルプ表示
help:
	@echo "spiketegaki Makefile Commands:"
	@echo "  make build                    - swift build -c release"
	@echo "  make test                     - swift test -c release"
	@echo "  make xbuild                   - xcodebuild build (MLX の Metal シェーダ込み)"
	@echo "  make xtest                    - xcodebuild test (MLX を含むテスト)"
	@echo "  make xtrain ARGS=\"...\"        - MLX 学習 (xcodebuild 産物を実行)"
	@echo "  make vocab ARGS=\"...\"         - swift run -c release vocab"
	@echo "  make render ARGS=\"...\"        - swift run -c release render"
	@echo "  make recognize ARGS=\"...\"     - swift run -c release recognize"
	@echo "  make wasm                     - SwiftWasm でビルドし $(DEMO_DIR)/spiketegaki.wasm を作る"
	@echo "  make demo                     - デモを $(DEMO_DIR) に置いて localhost:$(DEMO_PORT) で配信"
	@echo "  make clean                    - ビルド成果物をクリーン"
	@echo ""
	@echo "MLX を使う学習とテストは x 付き (make xtrain / make xtest) だけです。swift run では動きません。"
	@echo "中間生成物 (フォント・データセット・重み) は .tmp/ 配下に置きます。"
