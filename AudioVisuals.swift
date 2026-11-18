import SwiftUI
import CoreGraphics

// MARK: - 波形 / スペクトログラムをレーンに重ねて見せる (SETTING の「波形を表示」「スペクトログラムを表示」)
//
// 計算 (FFT・波形の表・描く位置) は AudioVisualDSP.swift。このファイルは、
//   1) AudioVisualCache: オンにしたときに 1 回だけ、背景スレッドで計算して持っておく入れ物
//   2) LaneRenderer.drawAudioVisuals: できあがった表を、レーンの背景として貼る / 引く
// を受け持つ。LaneRenderer.draw / drawFX が、拍の線より下の層として呼ぶ (Renderers.swift / RenderersFX.swift)。
//
// 軽さ: 計算が終わるまでは何も出ない (画面は止まらない。スペクトログラムは終わったら知らせが出る)。終わったあとは、
//   ・波形: 画面の拡大率に合った粗さの表から、横線 (約 500 本) を 1 つの Path にして 1 回で引く
//   ・スペクトログラム: できあがったタイル (画像) のうち、画面に掛かる 2〜3 枚を貼る (1 フレームに FFT はしない)
//   だけなので、ノーツが少ない所と同じくらい軽い。オフのときは、何も計算しないし何も描かない。

// MARK: - 計算結果の入れ物

/// スペクトログラムのタイル 1 枚 (貼るだけの画像)
struct SpectrogramTile {
    let t0: Double
    let t1: Double
    let image: Image
}

struct SpectrogramData {
    let duration: Double
    let tiles: [SpectrogramTile]
    let tileSpans: [(t0: Double, t1: Double)]
}

/// 曲 (SongPCM) から作った波形・スペクトログラム。EditorState が 1 つ持つ (曲は開くときに決まって、途中では変わらない)。
/// メインスレッドから使う。計算は背景スレッド、結果の受け取りはメインスレッド。
final class AudioVisualCache {
    private let song: SongPCM?
    private let job = AudioVisualJob()

    private(set) var waveform: WaveformData?
    private(set) var spectrogram: SpectrogramData?
    private var waveformRequested = false
    private var spectrogramRequested = false

    /// 計算が終わったとき (画面を描き直してほしいとき) に、メインスレッドで呼ばれる
    var onReady: (() -> Void)?
    /// 画面に出す短い知らせ (「計算中...」など)。メインスレッドで呼ばれる
    var onStatus: ((String) -> Void)?

    private var noticeWork: DispatchWorkItem?
    private var noticeShown = false

    init(song: SongPCM?) {
        self.song = song
    }

    deinit {
        job.cancel()                    // 計算の途中なら止める
        noticeWork?.cancel()
    }

    /// 波形が要るのに、まだ無いとき、背景で計算を始める (何回呼んでも、計算は 1 回だけ)
    func ensureWaveform(_ need: Bool) {
        guard need, let song = song, song.frames > 0, waveform == nil, !waveformRequested else { return }
        waveformRequested = true
        let job = self.job
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let wf = AudioVisualDSP.computeWaveform(left: song.left, right: song.right,
                                                    frames: song.frames, sampleRate: song.sampleRate)
            DispatchQueue.main.async {
                guard let self = self, !job.isCancelled else { return }
                self.waveformRequested = false
                self.waveform = wf
                self.onReady?()
            }
        }
    }

    /// スペクトログラムが要るのに、まだ無いとき、背景で計算を始める (何回呼んでも、計算は 1 回だけ)
    func ensureSpectrogram(_ need: Bool) {
        guard need, let song = song, song.frames > 0, spectrogram == nil, !spectrogramRequested else { return }
        spectrogramRequested = true
        noticeShown = false
        // すぐ終わるときは何も出さず、少し掛かるときだけ「計算中」を出す
        let notice = DispatchWorkItem { [weak self] in
            guard let self = self, self.spectrogramRequested else { return }
            self.noticeShown = true
            self.onStatus?("スペクトログラムを計算中...")
        }
        noticeWork?.cancel()
        noticeWork = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: notice)

        let job = self.job
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let px = AudioVisualDSP.computeSpectrogram(left: song.left, right: song.right,
                                                       frames: song.frames, sampleRate: song.sampleRate, job: job)
            // 画像 (CGImage) にするところまで、背景でやっておく
            var images: [CGImage] = []
            if let px = px {
                for t in px.tiles {
                    guard let cg = makeSpectrogramImage(t) else { break }
                    images.append(cg)
                }
            }
            let madeImages = images
            DispatchQueue.main.async {
                guard let self = self, !job.isCancelled else { return }
                self.noticeWork?.cancel()
                self.noticeWork = nil
                self.spectrogramRequested = false
                // 失敗したとき (メモリ不足など) は何も出さない。もう一度オンにすると、やり直す
                guard let px = px, madeImages.count == px.tiles.count, !madeImages.isEmpty else { return }
                var tiles: [SpectrogramTile] = []
                var spans: [(t0: Double, t1: Double)] = []
                tiles.reserveCapacity(madeImages.count)
                for (i, t) in px.tiles.enumerated() {
                    tiles.append(SpectrogramTile(t0: t.t0, t1: t.t1,
                                                 image: Image(decorative: madeImages[i], scale: 1.0)))
                    spans.append((t0: t.t0, t1: t.t1))
                }
                self.spectrogram = SpectrogramData(duration: px.duration, tiles: tiles, tileSpans: spans)
                if self.noticeShown { self.onStatus?("スペクトログラムの準備ができました") }
                self.onReady?()
            }
        }
    }
}

/// タイルの画素 (RGBA・乗算済みアルファ) から CGImage を作る
private func makeSpectrogramImage(_ t: SpectrogramTilePixels) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(t.pixels) as CFData) else { return nil }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    return CGImage(width: t.width, height: t.rows,
                   bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: t.width * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// MARK: - レーンへの描画

extension LaneRenderer {
    /// 波形・スペクトログラムをレーンの背景として描く (拍の線・ノーツより下)。
    /// どちらもオフ / まだ計算中なら、何もしない (すぐ戻る)。
    /// 通常の表示でも FX 表示でも、「譜面の時刻 t が画面のどの高さか」を区間ごとの直線 (VisualSegment) にして、
    /// その直線の上に、曲の位置 (t − オフセット) の波形・スペクトログラムを並べる。
    /// BPM が変わる所・scroll / jump が変わる所で区間が分かれるので、どこでも拍の線とずれない
    static func drawAudioVisuals(_ c: inout GraphicsContext, _ g: LaneGeo, _ state: EditorState) {
        let spec = state.showSpectrogram ? state.audioVisuals.spectrogram : nil
        let wave = state.showWaveform ? state.audioVisuals.waveform : nil
        if spec == nil && wave == nil { return }
        let segs = visualSegments(g, state)
        if segs.isEmpty { return }
        let offSec = Double(state.chart.offsetMs) / 1000.0

        var lane = c
        lane.clip(to: Path(CGRect(x: g.trackL, y: 0, width: g.trackW, height: g.H)))
        if let spec = spec { drawSpectrogramTiles(&lane, g, spec, segs, offSec) }
        if let wave = wave { drawWaveformLines(&lane, g, wave, segs, offSec) }
    }

    /// スペクトログラム: 画面に掛かるタイルを貼る。区間ごとに、タイルの画像ぜんぶを直線の上に伸ばして貼り、
    /// 区間の範囲だけを見せる (clip)。時刻が下へ進む区間 (FX 表示の逆走) は、上下を反転して貼る
    private static func drawSpectrogramTiles(_ c: inout GraphicsContext, _ g: LaneGeo, _ spec: SpectrogramData,
                                             _ segs: [VisualSegment], _ offSec: Double) {
        let placements = AudioVisualDSP.spectrogramPlacements(segs: segs, offSec: offSec, duration: spec.duration,
                                                              tileSpans: spec.tileSpans)
        if placements.isEmpty { return }
        var base = c
        base.opacity = 0.9
        let x = g.trackL
        let w = g.trackW
        for p in placements {
            var t = base
            t.clip(to: Path(CGRect(x: x, y: CGFloat(p.clipTop), width: w, height: CGFloat(p.clipBottom - p.clipTop))))
            let rect = CGRect(x: x, y: CGFloat(p.rectTop), width: w, height: CGFloat(p.rectBottom - p.rectTop))
            if p.flipped {
                t.translateBy(x: 0, y: CGFloat(p.rectTop + p.rectBottom))
                t.scaleBy(x: 1, y: -1)
            }
            t.draw(spec.tiles[p.tileIndex].image, in: rect)
        }
    }

    /// 波形: 中心線 (x = 127.5) を軸に、左右対称の横線を 1.5 ピクセルおきに引く (1 つの Path にして 1 回で stroke)
    private static func drawWaveformLines(_ c: inout GraphicsContext, _ g: LaneGeo, _ wf: WaveformData,
                                          _ segs: [VisualSegment], _ offSec: Double) {
        let lines = AudioVisualDSP.waveformLines(segs: segs, offSec: offSec, wf: wf, height: Double(g.H))
        if lines.isEmpty { return }
        let cx = g.px(127.5)
        let maxHalfW = g.trackW * 0.48
        var path = Path()
        for l in lines {
            let hw = CGFloat(l.frac) * maxHalfW
            let y = CGFloat(l.y)
            path.move(to: CGPoint(x: cx - hw, y: y))
            path.addLine(to: CGPoint(x: cx + hw, y: y))
        }
        c.stroke(path, with: .color(Color(red: 72.0 / 255.0, green: 170.0 / 255.0, blue: 214.0 / 255.0).opacity(0.36)),
                 lineWidth: 1)
    }

    /// 画面に見えている範囲を、「時刻 → 高さ」が一直線の区間に分ける
    private static func visualSegments(_ g: LaneGeo, _ state: EditorState) -> [VisualSegment] {
        let H = Double(g.H)
        guard let f = g.fx else {
            // 通常の表示: 見える拍の範囲を、BPM の変わる拍で区切る (区間の中は、拍と時刻が比例する)
            let bLo = g.beatOf(g.H)
            let bHi = g.beatOf(0)
            guard bHi > bLo else { return [] }
            var bounds: [Double] = [bLo]
            for pt in state.chart.times {
                let b = pt.beat.value
                if b > bLo + 1e-9 && b < bHi - 1e-9 { bounds.append(b) }
            }
            bounds.append(bHi)
            bounds.sort()
            var segs: [VisualSegment] = []
            segs.reserveCapacity(bounds.count)
            for i in 0..<(bounds.count - 1) {
                let ba = bounds[i]
                let bb = bounds[i + 1]
                if !(bb > ba) { continue }
                segs.append(VisualSegment(t0: state.timeMap.sec(atBeat: ba), t1: state.timeMap.sec(atBeat: bb),
                                          y0: Double(g.py(ba)), y1: Double(g.py(bb))))
            }
            return segs
        }

        // FX 表示: 見える表示位置に入る時刻の範囲 (fxRanges) を、BPM の変わる時刻と scroll / jump の変わる時刻で区切る。
        // 区間の中は、scroll が一定なので、時刻と高さが比例する。scroll 0 の区間 (全部が 1 か所に重なる) は描かない
        let ranges = fxRanges(g, f, totalSec: state.totalSec, margin: 4)
        if ranges.isEmpty { return [] }
        let pps = g.fxPxPerSec(f)
        let playY = Double(g.playY)
        func yOfP(_ p: Double) -> Double { playY - (p - f.pNow) * pps }

        var segs: [VisualSegment] = []
        for r in ranges {
            let tLo = f.time.sec(atBeat: r.lo)
            let tHi = f.time.sec(atBeat: r.hi)
            if !(tHi > tLo) { continue }
            var splitT: [Double] = [tLo]
            for pt in state.chart.times {
                let t = f.time.sec(atBeat: pt.beat.value)
                if t > tLo + 1e-7 && t < tHi - 1e-7 { splitT.append(t) }
            }
            for t in f.map.starts where t > tLo + 1e-7 && t < tHi - 1e-7 {
                splitT.append(t)
            }
            splitT.append(tHi)
            splitT.sort()
            for i in 0..<(splitT.count - 1) {
                let ta = splitT[i]
                let tb = splitT[i + 1]
                if !(tb - ta > 1e-7) { continue }
                if abs(f.map.scroll(at: 0.5 * (ta + tb))) < 1e-6 { continue }
                // 区間の端の、ちょうど境目の値 (jump で飛ぶ所) を避けて、区間の内側の表示位置を使う
                let ya = yOfP(f.map.p(ta + 1e-7))
                let yb = yOfP(f.map.p(tb - 1e-7))
                if max(ya, yb) < 0 || min(ya, yb) > H { continue }
                segs.append(VisualSegment(t0: ta, t1: tb, y0: ya, y1: yb))
            }
        }
        return segs
    }
}
