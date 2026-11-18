import Foundation

// MARK: - 波形 / スペクトログラムの計算 (SETTING の「波形を表示」「スペクトログラムを表示」)
//
// Web 版 (audioVisualWorker.ts / LaneAudioVisuals.ts) と同じ計算を Swift に移したもの。
// このファイルは Foundation だけを使う (SwiftUI / CoreGraphics には触れない)。
// 画面に出す部分は AudioVisuals.swift が受け持つ。
//
// 軽さの考え方: 「重い計算は 1 回だけ、背景スレッドで」「描くときは、できあがった表を読むだけ」。
//   ・波形: 曲全体を 2000 個/秒の「山の高さ」(最大絶対値) の表にして、さらに 4 倍ずつ粗くした表を 3 段作る (mipmap)。
//           描くときは、画面の拡大率にちょうどよい段を選ぶので、何分の曲でも 1 フレームに読む数は数千個で済む
//   ・スペクトログラム: 曲全体を FFT (1024 点) して、512 行ずつのタイル (RGBA の画像) に切っておく。
//           描くときは、画面に掛かるタイルを貼るだけ (FFT はしない)
//   ・どちらも、オンにしたときに 1 回だけ計算する (読み込みには時間が掛かってよい)。計算が終わるまで、画面は止まらない

// MARK: データ

/// 波形の山の高さの表 1 段ぶん (rate = 1 秒あたりの個数)
struct WaveformLevel {
    let rate: Double
    let peaks: [UInt8]          // 0...255 = 絶対値 0...1
}

struct WaveformData {
    let duration: Double        // 曲の長さ (秒)
    let levels: [WaveformLevel] // [0] がいちばん細かい (2000/秒)。後ろほど 4 倍ずつ粗い
}

/// スペクトログラムのタイル 1 枚ぶんの画素 (RGBA 8bit・乗算済みアルファ)。
/// 画像の 1 行目 (上) = 後の時刻 (t1)、最後の行 (下) = 前の時刻 (t0)
struct SpectrogramTilePixels {
    let t0: Double
    let t1: Double
    let width: Int
    let rows: Int
    let pixels: [UInt8]         // width * rows * 4
}

struct SpectrogramPixels {
    let duration: Double
    let width: Int
    let rowsPerSec: Double
    let tiles: [SpectrogramTilePixels]
}

/// 計算の中止の目印 (EditorState が閉じられたときに立てる)。背景スレッドから読むので、ロックで守る
final class AudioVisualJob: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// 画面の 1 区間: 譜面の時刻 t0...t1 (秒) が、画面の高さ y0...y1 に一直線に並ぶ
/// (BPM が変わる所・FX 表示で scroll / jump が変わる所で区切る。区間の中は時刻と高さが比例する)
struct VisualSegment {
    var t0: Double
    var t1: Double
    var y0: Double
    var y1: Double
}

/// スペクトログラムのタイル 1 枚を、画面のどこにどう貼るか
struct SpectrogramPlacement {
    let tileIndex: Int
    /// 見せる範囲 (画面の高さ)。この範囲の外は、タイルを貼っても切り取る
    let clipTop: Double
    let clipBottom: Double
    /// タイルの画像ぜんぶを貼る矩形の上端 / 下端 (rectTop < rectBottom)。clip より外へ伸びてよい
    let rectTop: Double
    let rectBottom: Double
    /// true: 時刻が下へ進む向き (FX 表示の逆走) なので、上下を反転して貼る
    let flipped: Bool
}

/// 波形の横線 1 本 (y = 画面の高さ / frac = 山の高さ 0...1)
struct WaveformLine {
    let y: Double
    let frac: Double
}

// MARK: 計算本体

enum AudioVisualDSP {
    static let fftSize = 1024
    static let halfFFT = 512                // 周波数の本数
    static let specWidth = 256              // 画像の横の画素数 (周波数 2 本の最大値を 1 画素にする)
    static let tileRows = 512               // タイル 1 枚の行数
    static let waveBaseRate = 2000.0        // 波形のいちばん細かい表の、1 秒あたりの個数
    static let waveLevelCount = 4           // 波形の表の段数 (2000 → 500 → 125 → 31.25 個/秒)

    // MARK: 波形

    /// 曲全体の「山の高さ」の表 (mipmap) を作る。左右は平均 (モノラルの曲は left と right が同じ場所を指す)。
    /// 重いので背景スレッドから呼ぶ (曲の長さに比例。3 分の曲で数十 ms)
    static func computeWaveform(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                                frames: Int, sampleRate sr: Double) -> WaveformData {
        let duration = Double(frames) / sr
        let baseRate = waveBaseRate
        let baseCount = max(1, Int((duration * baseRate).rounded(.up)))
        var base = [UInt8](repeating: 0, count: baseCount)
        base.withUnsafeMutableBufferPointer { out in
            for i in 0..<baseCount {
                let s0 = Int((Double(i) * sr / baseRate).rounded(.down))
                let s1 = min(frames, Int((Double(i + 1) * sr / baseRate).rounded(.up)))
                var maxAbs: Float = 0
                var s = s0
                while s < s1 {
                    let v = 0.5 * (left[s] + right[s])
                    let av = v < 0 ? -v : v
                    if av > maxAbs { maxAbs = av }
                    s += 1
                }
                out[i] = UInt8((min(1, maxAbs) * 255).rounded())
            }
        }

        var levels: [WaveformLevel] = [WaveformLevel(rate: baseRate, peaks: base)]
        var prev = base
        var prevRate = baseRate
        for _ in 1..<waveLevelCount {
            let nextLen = max(1, (prev.count + 3) / 4)
            var next = [UInt8](repeating: 0, count: nextLen)
            for i in 0..<nextLen {
                let start = i * 4
                let end = min(prev.count, start + 4)
                var m: UInt8 = 0
                var j = start
                while j < end {
                    if prev[j] > m { m = prev[j] }
                    j += 1
                }
                next[i] = m
            }
            prevRate /= 4
            levels.append(WaveformLevel(rate: prevRate, peaks: next))
            prev = next
        }
        return WaveformData(duration: duration, levels: levels)
    }

    // MARK: スペクトログラム

    /// 曲全体を FFT して、タイル (RGBA の画素) に切って返す。中止されたら nil。
    /// 重いので背景スレッドから呼ぶ。中ではコアの数だけ並べて動かす (行どうしは独立なので)。
    ///   ・窓 1024 (ハン窓) / 1 秒に 100 行 (10 分を超える曲は 60 行) / 横 256 画素 (低い音が左、高い音が右)
    ///   ・色の範囲は、曲全体の明るさの 99.85% 点を基準に自動で決める (小さい音の曲でも暗くなりすぎない)
    static func computeSpectrogram(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                                   frames: Int, sampleRate sr: Double,
                                   job: AudioVisualJob) -> SpectrogramPixels? {
        let tables = SpectrumTables.shared
        let n = fftSize
        let half = halfFFT
        let width = specWidth
        let duration = Double(frames) / sr
        let rowsPerSec: Double = duration > 600 ? 60 : 100
        let totalRows = max(1, Int((duration * rowsPerSec).rounded(.up)))

        // 1) 全部の行を FFT して、周波数ごとの大きさ (dB) の表を作る
        let dbGrid = UnsafeMutablePointer<Float>.allocate(capacity: totalRows * width)
        defer { dbGrid.deallocate() }

        let histBins = 256
        let histMin: Float = -120
        let histMax: Float = 12
        var globalHist = [UInt32](repeating: 0, count: histBins)
        let histLock = NSLock()
        let normFactor = 1.0 / (Double(n) * 0.25)       // ハン窓 (平均 0.5) と、実数 FFT の半分 (0.5) の分

        let rowsPerChunk = 64
        let chunkCount = (totalRows + rowsPerChunk - 1) / rowsPerChunk
        DispatchQueue.concurrentPerform(iterations: chunkCount) { ci in
            if job.isCancelled { return }
            let re = UnsafeMutablePointer<Float>.allocate(capacity: n)
            let im = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer {
                re.deallocate()
                im.deallocate()
            }
            var hist = [UInt32](repeating: 0, count: histBins)
            let rowEnd = min(totalRows, (ci + 1) * rowsPerChunk)
            var row = ci * rowsPerChunk
            while row < rowEnd {
                let center = Int((((Double(row) + 0.5) / rowsPerSec) * sr).rounded())
                let start = center - half
                im.initialize(repeating: 0, count: n)
                // 窓を掛けた音を、ビット反転した並びで入れる (FFT の最初の入れ替えを省くため)
                for i in 0..<n {
                    let idx = start + i
                    var s: Float = 0
                    if idx >= 0 && idx < frames { s = 0.5 * (left[idx] + right[idx]) }
                    re[Int(tables.bitRev[i])] = s * tables.hann[i]
                }
                fftFromBitReversed(re, im, tables)

                let rowOffset = row * width
                for x in 0..<width {
                    // 0 番 (直流) は、左端に縦線ができるので、最初の列だけ飛ばす
                    let b0 = x == 0 ? 1 : x * 2
                    let b1 = x * 2 + 1
                    let p0 = re[b0] * re[b0] + im[b0] * im[b0]
                    let p1 = re[b1] * re[b1] + im[b1] * im[b1]
                    let mag = Double((p0 > p1 ? p0 : p1).squareRoot()) * normFactor
                    var db = Float(20 * log10(mag + 1e-7))
                    if !db.isFinite { db = histMin }
                    dbGrid[rowOffset + x] = db
                    var h = Int(((db - histMin) / (histMax - histMin)) * Float(histBins))
                    if h < 0 { h = 0 } else if h > histBins - 1 { h = histBins - 1 }
                    hist[h] += 1
                }
                row += 1
            }
            histLock.lock()
            for h in 0..<histBins { globalHist[h] += hist[h] }
            histLock.unlock()
        }
        if job.isCancelled { return nil }

        // 2) 色の範囲を決める (99.85% 点の少し上を「いちばん明るい色」にして、そこから 74dB 下を「真っ暗」にする)
        let totalCells = totalRows * width
        let targetRank = Int(Double(totalCells) * 0.9985)
        var accum = 0
        var p998Db: Float = -12
        for h in 0..<histBins {
            accum += Int(globalHist[h])
            if accum >= targetRank {
                p998Db = histMin + ((Float(h) + 0.5) / Float(histBins)) * (histMax - histMin)
                break
            }
        }
        let refMaxDb = max(-28, min(6, p998Db + 2))
        let refMinDb = refMaxDb - 74
        let invRange = 1 / (refMaxDb - refMinDb)

        // 3) 512 行ずつのタイルにして、色を付ける
        let tileCount = (totalRows + tileRows - 1) / tileRows
        let results = TileResults(count: tileCount)
        let lut = tables.lut
        DispatchQueue.concurrentPerform(iterations: tileCount) { ti in
            if job.isCancelled { return }
            let rowStart = ti * tileRows
            let rows = min(tileRows, totalRows - rowStart)
            var pixels = [UInt8](repeating: 0, count: width * rows * 4)
            pixels.withUnsafeMutableBufferPointer { px in
                lut.withUnsafeBufferPointer { l in
                    for r in 0..<rows {
                        let src = (rowStart + r) * width
                        // 画像の 1 行目 (上) が後の時刻になるように、上下を逆にして入れる
                        let dst = (rows - 1 - r) * width * 4
                        for x in 0..<width {
                            var norm = (dbGrid[src + x] - refMinDb) * invRange
                            if norm < 0 { norm = 0 } else if norm > 1 { norm = 1 }
                            let li = Int((norm * 255).rounded()) * 4
                            let p = dst + x * 4
                            px[p] = l[li]
                            px[p + 1] = l[li + 1]
                            px[p + 2] = l[li + 2]
                            px[p + 3] = l[li + 3]
                        }
                    }
                }
            }
            results.set(ti, SpectrogramTilePixels(
                t0: Double(rowStart) / rowsPerSec,
                t1: Double(rowStart + rows) / rowsPerSec,
                width: width, rows: rows, pixels: pixels))
        }
        if job.isCancelled { return nil }
        var tiles: [SpectrogramTilePixels] = []
        tiles.reserveCapacity(tileCount)
        for i in 0..<tileCount {
            guard let t = results.get(i) else { return nil }
            tiles.append(t)
        }
        return SpectrogramPixels(duration: duration, width: width, rowsPerSec: rowsPerSec, tiles: tiles)
    }

    /// FFT 本体 (入力は、ビット反転した並びで re に入っている。im は 0)。Web 版の fftInPlace から最初の入れ替えを除いたもの
    @inline(__always)
    private static func fftFromBitReversed(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>,
                                           _ t: SpectrumTables) {
        let n = fftSize
        var len = 2
        while len <= n {
            let half = len >> 1
            let step = n / len
            var i = 0
            while i < n {
                var j = 0
                while j < half {
                    let k = j * step
                    let wr = t.twCos[k]
                    let wi = t.twSin[k]
                    let i1 = i + j
                    let i2 = i1 + half
                    let tre = re[i2] * wr - im[i2] * wi
                    let tim = re[i2] * wi + im[i2] * wr
                    re[i2] = re[i1] - tre
                    im[i2] = im[i1] - tim
                    re[i1] += tre
                    im[i1] += tim
                    j += 1
                }
                i += len
            }
            len <<= 1
        }
    }

    // MARK: 描く位置の計算 (画面に出す AudioVisuals.swift が使う。毎フレーム呼ばれるので軽くしてある)

    /// スペクトログラム: 画面の各区間に掛かるタイルと、その貼り方。
    /// offSec = 譜面のオフセット (秒)。譜面の時刻 t の曲の位置は t − offSec
    static func spectrogramPlacements(segs: [VisualSegment], offSec: Double, duration: Double,
                                      tileSpans: [(t0: Double, t1: Double)]) -> [SpectrogramPlacement] {
        var out: [SpectrogramPlacement] = []
        guard !tileSpans.isEmpty, !segs.isEmpty else { return out }
        let tileDur = tileSpans[0].t1 - tileSpans[0].t0        // 最後の 1 枚以外は、みんな同じ長さ
        guard tileDur > 1e-9 else { return out }
        for seg in segs {
            let s0 = seg.t0 - offSec
            let s1 = seg.t1 - offSec
            let ds = s1 - s0
            if !(ds > 1e-9) { continue }
            if s1 <= 0 || s0 >= duration { continue }
            let c0 = max(0, s0)
            let c1 = min(duration, s1)
            if !(c1 > c0) { continue }
            let dy = seg.y1 - seg.y0
            let first = max(0, Int((c0 / tileDur).rounded(.down)))
            let last = min(tileSpans.count - 1, Int(((c1 - 1e-7) / tileDur).rounded(.down)))
            if first > last { continue }
            for ti in first...last {
                let span = tileSpans[ti]
                let u0 = max(c0, span.t0)
                let u1 = min(c1, span.t1)
                if !(u1 > u0) { continue }
                let yU0 = seg.y0 + (u0 - s0) / ds * dy
                let yU1 = seg.y0 + (u1 - s0) / ds * dy
                let clipTop = min(yU0, yU1)
                let clipBottom = max(yU0, yU1)
                if !(clipBottom - clipTop > 0.1) { continue }
                // タイルの画像ぜんぶが、この区間の直線の上でどこに来るか (上端 = タイルの終わりの時刻、下端 = はじめの時刻)
                let yTop = seg.y0 + (span.t1 - s0) / ds * dy
                let yBot = seg.y0 + (span.t0 - s0) / ds * dy
                if !yTop.isFinite || !yBot.isFinite { continue }
                if yTop < yBot {
                    out.append(SpectrogramPlacement(tileIndex: ti, clipTop: clipTop, clipBottom: clipBottom,
                                                    rectTop: yTop, rectBottom: yBot, flipped: false))
                } else if yTop > yBot {
                    out.append(SpectrogramPlacement(tileIndex: ti, clipTop: clipTop, clipBottom: clipBottom,
                                                    rectTop: yBot, rectBottom: yTop, flipped: true))
                }
            }
        }
        return out
    }

    /// 波形: 画面に引く横線 (1.5 ピクセルおき)。画面の拡大率にちょうどよい粗さの表を選んで、1 本ぶんの山を最大値で取る。
    /// height = レーンの高さ (これより下は引かない)
    static func waveformLines(segs: [VisualSegment], offSec: Double, wf: WaveformData, height H: Double,
                              rowStep: Double = 1.5) -> [WaveformLine] {
        var out: [WaveformLine] = []
        guard !wf.levels.isEmpty else { return out }
        for seg in segs {
            let s0 = seg.t0 - offSec
            let s1 = seg.t1 - offSec
            let ds = s1 - s0
            if !(ds > 1e-9) { continue }
            if s1 <= 0 || s0 >= wf.duration { continue }
            let dy = seg.y1 - seg.y0
            let absDy = abs(dy)
            if absDy < 0.5 { continue }

            // 横線 1 本が受け持つ秒数。表の 1 個がその半分以下になる、いちばん粗い段を使う
            let secPerStep = (ds / absDy) * rowStep
            var level = wf.levels[0]
            var l = wf.levels.count - 1
            while l >= 0 {
                let lv = wf.levels[l]
                if 1.0 / lv.rate <= secPerStep * 0.5 {
                    level = lv
                    break
                }
                l -= 1
            }
            let rate = level.rate
            let nPeaks = level.peaks.count
            let halfWin = secPerStep * 0.5

            let yMin = max(0, min(seg.y0, seg.y1))
            let yMax = min(H, max(seg.y0, seg.y1))
            var y = (yMin / rowStep).rounded(.up) * rowStep
            level.peaks.withUnsafeBufferPointer { peaks in
                while y <= yMax {
                    let sCenter = s0 + (y - seg.y0) / dy * ds
                    let sa = sCenter - halfWin
                    let sb = sCenter + halfWin
                    if sb > 0 && sa < wf.duration {
                        let i0 = max(0, Int((sa * rate).rounded(.down)))
                        let i1 = min(nPeaks - 1, Int((sb * rate).rounded(.down)))
                        if i1 >= i0 {
                            var maxPeak: UInt8 = 0
                            var idx = i0
                            while idx <= i1 {
                                if peaks[idx] > maxPeak { maxPeak = peaks[idx] }
                                idx += 1
                            }
                            if maxPeak > 1 {
                                out.append(WaveformLine(y: y, frac: Double(maxPeak) / 255.0))
                            }
                        }
                    }
                    y += rowStep
                }
            }
        }
        return out
    }
}

// MARK: - FFT の表 (どのスレッドからも読むだけ)

private final class SpectrumTables: @unchecked Sendable {
    static let shared = SpectrumTables()

    let hann: UnsafeMutablePointer<Float>
    let bitRev: UnsafeMutablePointer<Int32>
    let twCos: UnsafeMutablePointer<Float>
    let twSin: UnsafeMutablePointer<Float>
    /// 値 (0...255) → 色 (RGBA 8bit・乗算済みアルファ) の表。黒 → 濃い藍 → 赤 → だいだい → 金色 (Web 版と同じ色)
    let lut: [UInt8]

    private init() {
        let n = AudioVisualDSP.fftSize
        let h = UnsafeMutablePointer<Float>.allocate(capacity: n)
        for i in 0..<n {
            h[i] = Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n - 1))))
        }
        let br = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        let bits = Int(log2(Double(n)).rounded())
        for i in 0..<n {
            var x = i
            var r = 0
            for _ in 0..<bits {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            br[i] = Int32(r)
        }
        let halfN = n / 2
        let tc = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let ts = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        for i in 0..<halfN {
            let ang = -2 * Double.pi * Double(i) / Double(n)
            tc[i] = Float(cos(ang))
            ts[i] = Float(sin(ang))
        }
        hann = h
        bitRev = br
        twCos = tc
        twSin = ts
        lut = SpectrumTables.makeLUT()
    }

    private static func makeLUT() -> [UInt8] {
        // [位置, R, G, B, A]
        let stops: [[Double]] = [
            [0.0, 0, 0, 0, 0],
            [0.08, 18, 0, 72, 165],
            [0.2, 58, 0, 128, 225],
            [0.36, 148, 8, 52, 245],
            [0.54, 210, 32, 0, 252],
            [0.72, 238, 114, 0, 255],
            [0.88, 252, 186, 48, 255],
            [1.0, 255, 242, 175, 255]
        ]
        var lut = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let t = Double(i) / 255.0
            var s0 = stops[0]
            var s1 = stops[stops.count - 1]
            for k in 0..<(stops.count - 1) where t >= stops[k][0] && t <= stops[k + 1][0] {
                s0 = stops[k]
                s1 = stops[k + 1]
                break
            }
            let span = s1[0] - s0[0]
            let f = span > 1e-6 ? (t - s0[0]) / span : 0
            func ch(_ c: Int) -> Int { Int((s0[c] + (s1[c] - s0[c]) * f).rounded()) }
            let a = ch(4)
            // 描画側 (CGImage) は乗算済みアルファなので、色にアルファを掛けておく
            lut[i * 4] = UInt8((ch(1) * a + 127) / 255)
            lut[i * 4 + 1] = UInt8((ch(2) * a + 127) / 255)
            lut[i * 4 + 2] = UInt8((ch(3) * a + 127) / 255)
            lut[i * 4 + 3] = UInt8(a)
        }
        return lut
    }
}

/// タイルの計算結果の入れ物 (複数のスレッドが、別々の番号に書き込む)
private final class TileResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SpectrogramTilePixels?]

    init(count: Int) {
        items = [SpectrogramTilePixels?](repeating: nil, count: count)
    }

    func set(_ i: Int, _ v: SpectrogramTilePixels) {
        lock.lock()
        items[i] = v
        lock.unlock()
    }

    func get(_ i: Int) -> SpectrogramTilePixels? {
        lock.lock()
        defer { lock.unlock() }
        return items[i]
    }
}
