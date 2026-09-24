# spiketegaki Build & Run Makefile
# SNN (Spiking Neural Network) による日本語手書き 1 文字認識
#
# ビルド構成は Release 固定。-c release 無しと -c debug は禁止 (SIMD が効かず極端に遅い)。

CONFIG := release

# 各 script への引数 (例: make render ARGS="--scripts hiragana")
ARGS ?=

.PHONY: all build test xbuild xtest xtrain vocab render recognize clean help

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
	@echo "  make clean                    - ビルド成果物をクリーン"
	@echo ""
	@echo "MLX を使う学習とテストは x 付き (make xtrain / make xtest) だけです。swift run では動きません。"
	@echo "中間生成物 (フォント・データセット・重み) は .tmp/ 配下に置きます。"
