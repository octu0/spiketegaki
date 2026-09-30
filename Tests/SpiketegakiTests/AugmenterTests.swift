import XCTest
@testable import Spiketegaki

final class AugmenterTests: XCTestCase {
    /// 試験用の文字らしい画像: 中央に十字と縁取りのある塊。
    private func sampleImage() throws -> CharacterImage {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 8
        while y < 24 {
            var x = 8
            while x < 24 {
                // 十字 + 外周
                let onCross = (x >= 14 && x <= 17) || (y >= 14 && y <= 17)
                let onBorder = x == 8 || x == 23 || y == 8 || y == 23
                if onCross || onBorder {
                    p[y * CharacterImage.side + x] = 1.0
                }
                x += 1
            }
            y += 1
        }
        return try CharacterImage(pixels: p)
    }

    /// [from, to) の正方形を塗りつぶした太い字
    private func filledSquare(from: Int, to: Int) throws -> CharacterImage {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = from
        while y < to {
            var x = from
            while x < to {
                p[y * CharacterImage.side + x] = 1.0
                x += 1
            }
            y += 1
        }
        return try CharacterImage(pixels: p)
    }

    /// 中央の 6x6 の四角 (マス目に対してかなり小さな字)
    private func smallSquare() throws -> CharacterImage {
        return try filledSquare(from: 13, to: 19)
    }

    /// 線幅 1px の中空の四角 (細い字)
    private func thinBox() throws -> CharacterImage {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var i = 10
        while i < 22 {
            p[10 * CharacterImage.side + i] = 1.0
            p[21 * CharacterImage.side + i] = 1.0
            p[i * CharacterImage.side + 10] = 1.0
            p[i * CharacterImage.side + 21] = 1.0
            i += 1
        }
        return try CharacterImage(pixels: p)
    }

    /// 線幅 1px の 'L' 形 (縦棒 + 下の横棒)
    private func thinL() throws -> CharacterImage {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 8
        while y <= 24 {
            p[y * CharacterImage.side + 12] = 1.0
            y += 1
        }
        var x = 12
        while x <= 22 {
            p[24 * CharacterImage.side + x] = 1.0
            x += 1
        }
        return try CharacterImage(pixels: p)
    }

    private func assertValid(_ image: CharacterImage, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.pixels.count, 1024, message, file: file, line: line)
        for v in image.pixels {
            XCTAssertGreaterThanOrEqual(v, 0.0, message, file: file, line: line)
            XCTAssertLessThanOrEqual(v, 1.0, message, file: file, line: line)
            XCTAssertFalse(v.isNaN, message, file: file, line: line)
        }
    }

    // MARK: - 決定性

    func testSameSeedProducesIdenticalOutput() throws {
        let image = try sampleImage()
        let a = Augmenter(seed: 12345)
        let b = Augmenter(seed: 12345)
        var i = 0
        while i < 5 {
            let x = a.augment(image)
            let y = b.augment(image)
            XCTAssertEqual(x.pixels, y.pixels, "\(i) 回目の出力が seed 12345 で一致しない")
            i += 1
        }
    }

    func testDifferentSeedProducesDifferentOutput() throws {
        let image = try sampleImage()
        let a = Augmenter(seed: 1).augment(image)
        let b = Augmenter(seed: 2).augment(image)
        XCTAssertNotEqual(a.pixels, b.pixels, "seed 1 と 2 の出力が同じ")
    }

    func testSeedZeroDoesNotFreezeTheGenerator() {
        let aug = Augmenter(seed: 0)
        var seen = Set<UInt64>()
        var i = 0
        while i < 16 {
            seen.insert(aug.nextUInt64())
            i += 1
        }
        XCTAssertEqual(seen.count, 16, "seed 0 で乱数が停止している")
    }

    func testUniformIsInRangeAndGaussianHasExpectedMoments() {
        let aug = Augmenter(seed: 7)
        var i = 0
        while i < 10000 {
            let v = aug.nextUniform(in: -0.3 ... 0.3)
            XCTAssertGreaterThanOrEqual(v, -0.3)
            XCTAssertLessThanOrEqual(v, 0.3)
            i += 1
        }
        var sum = 0.0
        var sumSq = 0.0
        let n = 20000
        i = 0
        while i < n {
            let g = Double(aug.nextGaussian())
            sum += g
            sumSq += g * g
            i += 1
        }
        let mean = sum / Double(n)
        let variance = sumSq / Double(n) - mean * mean
        XCTAssertEqual(mean, 0.0, accuracy: 0.05, "正規乱数の平均が 0 でない")
        XCTAssertEqual(variance, 1.0, accuracy: 0.1, "正規乱数の分散が 1 でない")
    }

    // MARK: - 恒等変形

    func testIdentityTransformsMatchTheOriginal() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 42)
        let cases: [(String, CharacterImage)] = [
            ("shear 0", aug.affine(image, shear: 0.0, rotationDegrees: 0.0, scale: 1.0, dx: 0.0, dy: 0.0)),
            ("rotate 0", aug.affine(image, shear: 0.0, rotationDegrees: 0.0, scale: 1.0, dx: 0.0, dy: 0.0)),
            ("translate 0", aug.affine(image, shear: 0.0, rotationDegrees: 0.0, scale: 1.0, dx: 0.0, dy: 0.0)),
            ("scale 1", aug.affine(image, shear: 0.0, rotationDegrees: 0.0, scale: 1.0, dx: 0.0, dy: 0.0)),
            ("affine identity", aug.affine(image, shear: 0.0, rotationDegrees: 0.0, scale: 1.0, dx: 0.0, dy: 0.0))
        ]
        for (name, out) in cases {
            var i = 0
            while i < CharacterImage.pixelCount {
                XCTAssertEqual(out.pixels[i], image.pixels[i], accuracy: 1e-6, "\(name): 画素 \(i) がずれた")
                i += 1
            }
        }
    }

    func testDegenerateScaleDoesNotCrash() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 1)
        let out = aug.affine(image, shear: 0.0, rotationDegrees: 0.0, scale: 0.0, dx: 0.0, dy: 0.0)
        assertValid(out, "scale 0")
        XCTAssertEqual(out.inkSum, 0.0)
    }

    // MARK: - 既定のパラメータ

    /// 既定値は設計書 §7 の拡張範囲と一致する。
    /// 平行移動 ±5px は 2026-09-25 に ±2px から広げたもの。
    /// 拡縮は 0.85〜1.1 → 0.7〜1.15 → (2026-09-25) 0.60〜1.15。
    /// 小書き仮名を語彙から外した (2026-09-28) のでクラス別の範囲は持たず 1 本に戻した。
    /// 膨張 1〜2px (等確率)。確率は 1/3 → (2026-09-25) 0.6 → (2026-09-29) 0.3。
    /// 0.3 は線幅の実測による: マス目に切り出した手書きの線幅 (32x32 上、中央値 3.28px) に対し、
    /// 確率 0.6 の学習データは 4.28px と太すぎ、0.3 で 3.41px になる。
    func testDefaultParametersMatchTheDesignedRanges() {
        let p = Augmenter.Parameters()
        XCTAssertEqual(p.shearRange, -0.3 ... 0.3)
        XCTAssertEqual(p.rotationDegreesRange, -10.0 ... 10.0)
        XCTAssertEqual(p.translationRange, -5.0 ... 5.0, "平行移動は ±5px")
        XCTAssertEqual(p.scaleRange, 0.60 ... 1.15, "拡縮は 0.60〜1.15")
        XCTAssertEqual(p.thicknessProbability, 0.3, accuracy: 1e-7, "膨張の確率は 0.3")
        XCTAssertEqual(p.maxDilationPixels, 2, "膨張は 1〜2px の等確率")
        XCTAssertEqual(p.elasticAmplitude, 1.5)
        XCTAssertEqual(p.elasticSigma, 4.0)
        XCTAssertEqual(p.gaussianNoiseSigma, 0.05)
        XCTAssertEqual(p.saltPepperProbability, 0.01)
    }

    // MARK: - 拡縮範囲

    /// 拡縮の実効倍率を測るための土台。中央の 24x24 の塗り潰し。
    /// 1.15 倍でも 27.6px でマス目に収まるので、はみ出しで墨を失わない。
    private func scaleProbe() throws -> CharacterImage {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 4
        while y < 28 {
            var x = 4
            while x < 28 {
                p[y * CharacterImage.side + x] = 1.0
                x += 1
            }
            y += 1
        }
        return try CharacterImage(pixels: p)
    }

    /// 墨の量から倍率を見積もる (面積は倍率の 2 乗)。
    /// 双一次補間の縁の分だけ真値より数 % 上振れするので、**この関数どうしの比較にのみ使う**
    /// (期待値は `referenceScale` で同じ物差しに載せる)。
    private func scaleEstimate(_ out: CharacterImage, base: Float) -> Float {
        return (out.inkSum / base).squareRoot()
    }

    /// 既知の倍率を `affine` に直接与えたときの見積もり値。上の上振れを含む「物差しの目盛り」。
    private func referenceScale(_ probe: CharacterImage, _ scale: Float) -> Float {
        let out = Augmenter(seed: 1).affine(
            probe, shear: 0.0, rotationDegrees: 0.0, scale: scale, dx: 0.0, dy: 0.0
        )
        return scaleEstimate(out, base: probe.inkSum)
    }

    /// 拡縮以外を止めたパラメータ (拡縮の範囲は既定のまま)。
    private var scaleOnlyParameters: Augmenter.Parameters {
        return Augmenter.Parameters(
            shearRange: 0.0 ... 0.0,
            rotationDegreesRange: 0.0 ... 0.0,
            translationRange: 0.0 ... 0.0,
            thicknessProbability: 0.0,
            maxDilationPixels: 0,
            elasticAmplitude: 0.0,
            elasticSigma: 4.0,
            gaussianNoiseSigma: 0.0,
            saltPepperProbability: 0.0
        )
    }

    /// 拡縮だけを効かせた拡張を `trials` 回まわし、見積もり倍率の (最小, 最大) を返す。
    private func measuredScales(
        seed: UInt64,
        trials: Int = 800
    ) throws -> (probe: CharacterImage, min: Float, max: Float) {
        let probe = try scaleProbe()
        let base = probe.inkSum
        let aug = Augmenter(seed: seed, parameters: scaleOnlyParameters)
        var lo = Float.greatestFiniteMagnitude
        var hi: Float = 0.0
        var i = 0
        while i < trials {
            let s = scaleEstimate(aug.augment(probe), base: base)
            if s < lo { lo = s }
            if s > hi { hi = s }
            i += 1
        }
        return (probe, lo, hi)
    }

    /// 実効倍率は 0.60〜1.15 に収まり、かつ両端まで使われる。
    func testScaleSpansSixtyToOneFifteen() throws {
        let m = try measuredScales(seed: 20260925)
        print("[scale] min=\(m.min) max=\(m.max)"
            + " / 目盛り 0.60=\(referenceScale(m.probe, 0.60)) 1.15=\(referenceScale(m.probe, 1.15))")
        XCTAssertGreaterThanOrEqual(
            m.min, referenceScale(m.probe, 0.60) - 0.01, "0.60 より小さく縮んでいる"
        )
        XCTAssertLessThanOrEqual(
            m.max, referenceScale(m.probe, 1.15) + 0.01, "1.15 より大きく拡大している"
        )
        XCTAssertLessThanOrEqual(
            m.min, referenceScale(m.probe, 0.62), "縮小側の下端 0.60 まで使われていない"
        )
        XCTAssertGreaterThanOrEqual(
            m.max, referenceScale(m.probe, 1.13), "拡大側の上端 1.15 まで使われていない"
        )
    }

    /// 拡縮は 1 本の範囲しか持たない。文字クラスによらず同じ範囲・同じ乱数系列になる
    /// (2026-09-28 に小書き仮名を語彙から外し、クラス別の `smallKanaScaleRange` を削除した)。
    /// 同じ seed の 2 つの Augmenter は、どの画像を通しても同じ倍率・同じ以降の系列になる。
    func testScaleDoesNotDependOnTheCharacterClass() throws {
        let probe = try scaleProbe()
        let a = Augmenter(seed: 98765, parameters: scaleOnlyParameters)
        let b = Augmenter(seed: 98765, parameters: scaleOnlyParameters)
        let base = probe.inkSum
        var i = 0
        while i < 16 {
            XCTAssertEqual(
                scaleEstimate(a.augment(probe), base: base),
                scaleEstimate(b.augment(probe), base: base),
                accuracy: 1e-6,
                "\(i) 回目で倍率が食い違った"
            )
            i += 1
        }
        // 拡張後も乱数の位置が揃っている
        var k = 0
        while k < 8 {
            XCTAssertEqual(a.nextUInt64(), b.nextUInt64(), "\(k) 個目で乱数系列がずれた")
            k += 1
        }
    }

    // MARK: - アフィン変形の性質

    func testTranslateMovesInkByTheGivenOffset() throws {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        p[16 * CharacterImage.side + 16] = 1.0
        let image = try CharacterImage(pixels: p)
        let aug = Augmenter(seed: 1)
        let out = aug.affine(image, shear: 0.0, rotationDegrees: 0.0, scale: 1.0, dx: 3.0, dy: -2.0)
        XCTAssertEqual(out[19, 14], 1.0, accuracy: 1e-5, "+3, -2 の平行移動になっていない")
        XCTAssertEqual(out[16, 16], 0.0, accuracy: 1e-5)
        assertValid(out)
    }

    func testRotationIsAboutTheImageCenter() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 1)
        // 90 度 x 4 でほぼ元に戻る (補間のぼけは残るので墨の総量で比べる)
        var out = image
        var i = 0
        while i < 4 {
            out = aug.affine(out, shear: 0.0, rotationDegrees: 90.0, scale: 1.0, dx: 0.0, dy: 0.0)
            i += 1
        }
        XCTAssertEqual(out.inkSum, image.inkSum, accuracy: image.inkSum * 0.02, "90 度 x4 で墨の量が大きく変わった")
        assertValid(out)
    }

    func testShearAndRotateStayValid() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 3)
        for amount in [Float(-0.3), -0.15, 0.15, 0.3] {
            assertValid(aug.affine(image, shear: amount, rotationDegrees: 0.0, scale: 1.0, dx: 0.0, dy: 0.0), "shear \(amount)")
        }
        for degrees in [Float(-10), -5, 5, 10] {
            assertValid(aug.affine(image, shear: 0.0, rotationDegrees: degrees, scale: 1.0, dx: 0.0, dy: 0.0), "rotate \(degrees)")
        }
        for factor in [Float(0.7), 1.0, 1.15] {
            assertValid(aug.affine(image, shear: 0.0, rotationDegrees: 0.0, scale: factor, dx: 0.0, dy: 0.0), "scale \(factor)")
        }
    }

    // MARK: - 膨張

    func testDilateIncreasesInk() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 1)
        let dilated = aug.dilate(image)
        XCTAssertGreaterThanOrEqual(dilated.inkSum, image.inkSum, "膨張で墨が減った")
        XCTAssertGreaterThan(dilated.inkSum, image.inkSum, "膨張なのに墨が増えていない")
        assertValid(dilated, "dilate")
    }

    func testDilateOfEmptyImageStaysEmpty() {
        let aug = Augmenter(seed: 1)
        XCTAssertEqual(aug.dilate(CharacterImage()).inkSum, 0.0)
    }

    /// 全面が墨なら膨張しても増えようがない (上限で飽和する)
    func testDilateOfFullImageIsUnchanged() throws {
        let aug = Augmenter(seed: 1)
        let full = try CharacterImage(pixels: [Float](repeating: 1.0, count: CharacterImage.pixelCount))
        XCTAssertEqual(aug.dilate(full).inkSum, full.inkSum, accuracy: 1e-3)
    }

    /// 膨張は墨を増やす向きにしか働かない (どの画素も元以上)
    func testDilateNeverReducesAnyPixel() throws {
        let image = try sampleImage()
        let dilated = Augmenter(seed: 1).dilate(image)
        var i = 0
        while i < CharacterImage.pixelCount {
            XCTAssertGreaterThanOrEqual(dilated.pixels[i], image.pixels[i], "画素 \(i) で墨が減った")
            i += 1
        }
    }

    // MARK: - 弾性変形とノイズ

    func testElasticDeformIsDeterministicAndValid() throws {
        let image = try sampleImage()
        let a = Augmenter(seed: 77).elasticDeform(image, amplitude: 1.5, sigma: 4.0)
        let b = Augmenter(seed: 77).elasticDeform(image, amplitude: 1.5, sigma: 4.0)
        XCTAssertEqual(a.pixels, b.pixels)
        assertValid(a, "elastic")
        XCTAssertNotEqual(a.pixels, image.pixels, "弾性変形が何も変えていない")
        // 振幅 0 なら変位なし
        let zero = Augmenter(seed: 77).elasticDeform(image, amplitude: 0.0, sigma: 4.0)
        var i = 0
        while i < CharacterImage.pixelCount {
            XCTAssertEqual(zero.pixels[i], image.pixels[i], accuracy: 1e-6)
            i += 1
        }
    }

    func testGaussianNoiseKeepsRangeAndChangesPixels() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 5)
        let out = aug.gaussianNoise(image, sigma: 0.05)
        assertValid(out, "gaussian noise")
        XCTAssertNotEqual(out.pixels, image.pixels)
        // sigma 0 は素通し
        XCTAssertEqual(aug.gaussianNoise(image, sigma: 0.0).pixels, image.pixels)
    }

    func testSaltPepperHitsRoughlyTheGivenFraction() throws {
        // 全面 0.5 の画像なら、0.0 か 1.0 になった画素がごま塩の当たり
        let flat = try CharacterImage(pixels: [Float](repeating: 0.5, count: CharacterImage.pixelCount))
        let aug = Augmenter(seed: 11)
        var hits = 0
        var trials = 0
        while trials < 200 {
            let out = aug.saltPepper(flat, probability: 0.01)
            for v in out.pixels where v == 0.0 || v == 1.0 {
                hits += 1
            }
            trials += 1
        }
        let rate = Double(hits) / Double(200 * CharacterImage.pixelCount)
        XCTAssertEqual(rate, 0.01, accuracy: 0.003, "ごま塩の発生率が 1% から外れている: \(rate)")
        XCTAssertEqual(aug.saltPepper(flat, probability: 0.0).pixels, flat.pixels)
    }

    // MARK: - augment 全体

    func testAugmentOutputIsAlwaysValid() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 20260924)
        var i = 0
        while i < 300 {
            let out = aug.augment(image)
            assertValid(out, "augment \(i)")
            XCTAssertGreaterThan(out.inkSum, 0.0, "augment \(i) で墨が消えた")
            i += 1
        }
    }

    func testAugmentOfEmptyImageDoesNotCrash() {
        let aug = Augmenter(seed: 1)
        var i = 0
        while i < 20 {
            let out = aug.augment(CharacterImage())
            XCTAssertEqual(out.pixels.count, 1024)
            for v in out.pixels {
                XCTAssertGreaterThanOrEqual(v, 0.0)
                XCTAssertLessThanOrEqual(v, 1.0)
            }
            i += 1
        }
    }

    /// マス目基準では外接矩形の再正規化をしないので、変形で墨がマス目の端に触れたり
    /// はみ出したりしてよい。はみ出しても値域 [0, 1]・1024 要素が壊れないことを見る。
    func testAugmentMayTouchAndOverflowTheCellButStaysValid() throws {
        // マス目いっぱいに近い画像を平行移動・拡大すれば必ずはみ出す
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 2
        while y < 30 {
            var x = 2
            while x < 30 {
                p[y * CharacterImage.side + x] = 1.0
                x += 1
            }
            y += 1
        }
        let filled = try CharacterImage(pixels: p)
        let aug = Augmenter(seed: 314159)

        var sawEdgeInk = false
        var sawInkLoss = false
        var i = 0
        while i < 200 {
            let out = aug.augment(filled)
            XCTAssertEqual(out.pixels.count, 1024, "\(i) 回目の要素数")
            for v in out.pixels {
                XCTAssertGreaterThanOrEqual(v, 0.0, "\(i) 回目に負の値")
                XCTAssertLessThanOrEqual(v, 1.0, "\(i) 回目に 1 超え")
                XCTAssertFalse(v.isNaN, "\(i) 回目に NaN")
            }
            let side = CharacterImage.side
            var x = 0
            while x < side {
                if out[x, 0] >= ImageNormalizer.inkThreshold
                    || out[x, side - 1] >= ImageNormalizer.inkThreshold
                    || out[0, x] >= ImageNormalizer.inkThreshold
                    || out[side - 1, x] >= ImageNormalizer.inkThreshold {
                    sawEdgeInk = true
                }
                x += 1
            }
            if out.inkSum < filled.inkSum * 0.98 {
                sawInkLoss = true
            }
            i += 1
        }
        // 端に触れることも、はみ出して墨が減ることも起きてよい (旧方式では起き得なかった)
        XCTAssertTrue(sawEdgeInk, "マス目の端に墨が届く事例が 1 度も無い")
        XCTAssertTrue(sawInkLoss, "マス目からはみ出して墨が減る事例が 1 度も無い")
    }

    /// 拡張の途中で外接矩形の再正規化をしていないこと。
    /// ノイズを切って小さい墨を拡張しても、マス目いっぱいには引き伸ばされない。
    func testAugmentDoesNotRenormalizeToBoundingBox() throws {
        // マス目の中央に小さな四角 (8x8)
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 12
        while y < 20 {
            var x = 12
            while x < 20 {
                p[y * CharacterImage.side + x] = 1.0
                x += 1
            }
            y += 1
        }
        let small = try CharacterImage(pixels: p)
        let params = Augmenter.Parameters(gaussianNoiseSigma: 0.0, saltPepperProbability: 0.0)
        let aug = Augmenter(seed: 2718, parameters: params)

        var i = 0
        while i < 100 {
            let out = aug.augment(small)
            // 拡縮は最大 1.15 倍、膨張は最大 2px、弾性 1.5px なので、8x8 の四角の墨が
            // 元の 3.5 倍を超えることはない (同条件 20000 回の実測で最大 3.049)。
            // 外接矩形で正規化していたら枠いっぱい (16 倍近く) になるので、3.5 でも分離は十分。
            // 上限は 2026-09-25 に膨張を 1px → 1〜2px にした際に 3.0 から引き上げた。
            XCTAssertLessThan(out.inkSum, small.inkSum * 3.5,
                              "\(i) 回目に墨が増えすぎ (外接矩形へ引き伸ばされている疑い)")
            i += 1
        }
    }

    /// `augment` は線を細らせる変形を持たない (線の細さはフォントの種類で賄う)。
    ///
    /// 幾何変形・弾性変形・ノイズをすべて無効にすると、残る段は「太さ」だけになる。
    /// 膨張しか行わないなら墨は減りようがないので、1 回でも減っていれば
    /// 線を細らせる変形が混ざっている。
    func testAugmentNeverThinsStrokes() throws {
        // 太い塗りつぶし矩形
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 6
        while y < 26 {
            var x = 6
            while x < 26 {
                p[y * CharacterImage.side + x] = 1.0
                x += 1
            }
            y += 1
        }
        let image = try CharacterImage(pixels: p)

        // 太さ以外をすべて止める
        let params = Augmenter.Parameters(
            shearRange: 0.0 ... 0.0,
            rotationDegreesRange: 0.0 ... 0.0,
            translationRange: 0.0 ... 0.0,
            scaleRange: 1.0 ... 1.0,
            thicknessProbability: 0.6,
            maxDilationPixels: 2,
            elasticAmplitude: 0.0,
            elasticSigma: 4.0,
            gaussianNoiseSigma: 0.0,
            saltPepperProbability: 0.0
        )
        let aug = Augmenter(seed: 424242, parameters: params)
        var thicker = 0
        var i = 0
        while i < 300 {
            let out = aug.augment(image)
            XCTAssertGreaterThanOrEqual(
                out.inkSum, image.inkSum,
                "\(i) 回目に墨が減った (線を細らせる変形が混ざっている疑い)"
            )
            if out.inkSum > image.inkSum { thicker += 1 }
            i += 1
        }
        // 膨張自体は起きていること (太さの拡張がまるごと死んでいない)
        XCTAssertGreaterThan(thicker, 0, "膨張が 1 度も起きていない")
        XCTAssertLessThan(thicker, 300, "毎回膨張している (確率が効いていない)")
    }

    /// 膨張は 1〜2px の等確率で、確率 `thicknessProbability` で起きる。
    ///
    /// 太さ以外をすべて止めて中央の 1 画素だけを入れると、出力の墨は
    /// 膨張なし = 1、1px 膨張 = 3x3 = 9、2px 膨張 = 5x5 = 25 のいずれかになる。
    /// この 3 通りの頻度で、確率 0.6 と 1px:2px = 1:1 を確かめる。
    func testDilationIsOneOrTwoPixelsWithEqualProbability() throws {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        p[16 * CharacterImage.side + 16] = 1.0
        let dot = try CharacterImage(pixels: p)

        // 太さ以外をすべて止める (アフィンは恒等、弾性・ノイズ無し)
        let params = Augmenter.Parameters(
            shearRange: 0.0 ... 0.0,
            rotationDegreesRange: 0.0 ... 0.0,
            translationRange: 0.0 ... 0.0,
            scaleRange: 1.0 ... 1.0,
            thicknessProbability: 0.6,
            maxDilationPixels: 2,
            elasticAmplitude: 0.0,
            elasticSigma: 4.0,
            gaussianNoiseSigma: 0.0,
            saltPepperProbability: 0.0
        )
        let aug = Augmenter(seed: 987654321, parameters: params)

        let trials = 20000
        var none = 0
        var one = 0
        var two = 0
        var i = 0
        while i < trials {
            let ink = aug.augment(dot).inkSum
            if ink < 4.0 {
                none += 1
            } else if ink < 16.0 {
                one += 1
            } else {
                two += 1
            }
            i += 1
        }
        XCTAssertEqual(none + one + two, trials, "3 通り以外の墨量が出た")

        // 二項分布の標準偏差は 20000 件で約 0.35% なので、±2% はきわめて広い許容
        let pNone = Float(none) / Float(trials)
        let pOne = Float(one) / Float(trials)
        let pTwo = Float(two) / Float(trials)
        XCTAssertEqual(pNone, 0.4, accuracy: 0.02, "膨張しない確率が 0.4 でない")
        XCTAssertEqual(pOne, 0.3, accuracy: 0.02, "1px 膨張の確率が 0.3 でない")
        XCTAssertEqual(pTwo, 0.3, accuracy: 0.02, "2px 膨張の確率が 0.3 でない")
    }

    /// 細い小さな字でも `augment` がほぼ真っ白な画像を作らないこと。
    /// マス目基準には外接矩形の再正規化による救済が無いので、ここが崩れると
    /// 「真っ白な画像に正しいラベルが付いた」学習サンプルができてしまう。
    func testAugmentKeepsThinSmallGlyphVisible() throws {
        // 1px 幅の十字 (マス目の中央に小さく置く)
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var k = 10
        while k < 22 {
            p[15 * CharacterImage.side + k] = 1.0
            p[k * CharacterImage.side + 15] = 1.0
            k += 1
        }
        let thin = try CharacterImage(pixels: p)
        let params = Augmenter.Parameters(gaussianNoiseSigma: 0.0, saltPepperProbability: 0.0)
        let aug = Augmenter(seed: 987, parameters: params)

        var worst = Float.greatestFiniteMagnitude
        var i = 0
        while i < 300 {
            let out = aug.augment(thin)
            let ratio = out.inkSum / thin.inkSum
            if ratio < worst { worst = ratio }
            i += 1
        }
        print("[measure] 細い十字 300 回の最小残存率 = \(String(format: "%.4f", worst))")
        XCTAssertGreaterThan(worst, 0.0)
    }

    /// clampToCell は値域を [0, 1] に収めるだけで、位置も大きさも変えない
    func testClampToCellKeepsGeometry() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 1)
        let out = aug.clampToCell(image)
        XCTAssertEqual(out.pixels, image.pixels)
    }

    // MARK: - 拡張で字が消えないこと

    /// 小さな字・細い字を seed を変えて 1000 回拡張したときの墨の最小残存率を測る。
    func testAugmentKeepsInkForSmallGlyphs() throws {
        let cases: [(String, CharacterImage)] = [
            ("中央 6x6 の四角", try smallSquare()),
            ("線幅 1px の L", try thinL()),
            ("線幅 1px の中空四角", try thinBox())
        ]
        let noiseless = Augmenter.Parameters(gaussianNoiseSigma: 0.0, saltPepperProbability: 0.0)
        for (name, image) in cases {
            for (label, params) in [("ノイズ有", Augmenter.Parameters()), ("ノイズ無", noiseless)] {
                var worst = Float.greatestFiniteMagnitude
                var seed: UInt64 = 1
                while seed <= 1000 {
                    let out = Augmenter(seed: seed, parameters: params).augment(image)
                    let ratio = out.inkSum / image.inkSum
                    if ratio < worst { worst = ratio }
                    XCTAssertEqual(out.pixels.count, 1024, "\(name)/\(label): seed \(seed) の要素数")
                    seed += 1
                }
                print("[measure] \(name) / \(label): 1000 seed の最小残存率 = "
                    + "\(String(format: "%.4f", worst))")
            }
        }
    }

    /// 墨の無い画像でも壊れない
    func testAugmentOfEmptyImageStaysValid() {
        let aug = Augmenter(seed: 7)
        var i = 0
        while i < 20 {
            let out = aug.augment(CharacterImage())
            XCTAssertEqual(out.pixels.count, 1024)
            for v in out.pixels {
                XCTAssertGreaterThanOrEqual(v, 0.0)
                XCTAssertLessThanOrEqual(v, 1.0)
            }
            i += 1
        }
    }

    /// 1000 回の実行時間 (render スクリプトの見積もり用)。時間は表示のみで判定には使わない。
    func testAugmentThroughput() throws {
        let image = try sampleImage()
        let aug = Augmenter(seed: 2024)
        let start = Date()
        var checksum: Float = 0.0
        var i = 0
        while i < 1000 {
            checksum += aug.augment(image).inkSum
            i += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        let perCallMs = elapsed * 1000.0 / 1000.0
        print("[perf] Augmenter.augment x1000: \(String(format: "%.3f", elapsed)) 秒 (1 回あたり \(String(format: "%.4f", perCallMs)) ms), checksum=\(checksum)")
        XCTAssertGreaterThan(checksum, 0.0)
    }
}
