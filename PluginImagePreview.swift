import SwiftUI
import UIKit
import CoreGraphics
import ImageIO

// プラグインの「画像プレビュー」ダイアログ (Lua の Editor:ShowImagePreview)。
// img2hold のように「画像 → 256 (横) × 長さ×分割 (縦) に引き伸ばして白黒にする」プラグインが、
// 長さ / 分割数 / しきい値 / 反転 を、結果を見ながら決めるための画面。
//   ・プレビューは、Lua の DecodeImage と同じ関数 (PluginImageTools) で作る。プレビューと実際の結果はずれない
//   ・長さ・分割数を変えたときだけ画像を作り直し (背景スレッド)、しきい値・反転・表示の切り替えは、作った白黒を塗り直すだけ
//   ・スライダーを素早く動かしたときは、古い計算を飛ばして最後の値だけを描く (latest wins)

/// プレビュー画面に渡す / 返す設定
struct PluginImageParams {
    var length: Double        // 長さ (拍)
    var ticks: Int            // 1拍あたりの tick (分割数)
    var threshold: Int        // しきい値 (0〜255。これより暗い所がホールド)
    var invert: Bool          // 反転 (明るい所がホールド)
    var beatAspect: Double    // 現在のズームでの「1拍の高さ ÷ レーンの幅」(レーンの比率でプレビューを出すため)
}

// MARK: - 画像の処理 (DecodeImage と共通)

enum PluginImageTools {
    /// ホールドを並べる横の幅 (x = 0〜255)
    static let laneWidth = 256

    /// 画像のデータを読む (長辺 4096px まで。写真の向き (EXIF) は直す)。読めなければ nil
    static func load(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var maxSide = 4096
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            maxSide = max(1, min(4096, max(pw, ph)))
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 画像を 幅 w x 高さ h に引き伸ばして、白黒 (0 = 黒 〜 255 = 白) の 1ピクセル 1バイトにする。
    /// 上の行から順に並ぶ。透明な所は白になる
    static func gray(_ img: CGImage, w: Int, h: Int) -> [UInt8]? {
        if w < 1 || h < 1 { return nil }
        var buf = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w,
                                      height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    /// 白黒の画像から、プレビュー用の画像とホールドの本数を作る。
    /// ・暗い (v < しきい値。反転なら逆) ピクセルがホールド。縦に続く暗いピクセルの塊 1つ = ホールド 1本 (img2hold と同じ数え方)
    /// ・showGray = true のときは、しきい値をかけずに白黒そのまま見せる (ホールドの本数は同じように数える)
    static func render(gray: [UInt8], w: Int, h: Int, threshold: Int, invert: Bool, showGray: Bool) -> (image: CGImage?, holds: Int) {
        var pix = [UInt8](repeating: 255, count: w * h * 4)
        var prev = [Bool](repeating: false, count: w)
        var holds = 0
        gray.withUnsafeBufferPointer { g in
            pix.withUnsafeMutableBufferPointer { p in
                for i in 0..<h {
                    let row = i * w
                    for x in 0..<w {
                        let v = g[row + x]
                        var dark = Int(v) < threshold
                        if invert { dark = !dark }
                        if dark && !prev[x] { holds += 1 }
                        prev[x] = dark
                        let o = (row + x) * 4
                        if showGray {
                            p[o] = v
                            p[o + 1] = v
                            p[o + 2] = v
                        } else if dark {
                            p[o] = 0x5B
                            p[o + 1] = 0xE0
                            p[o + 2] = 0xFF
                        } else {
                            p[o] = 0x12
                            p[o + 1] = 0x16
                            p[o + 2] = 0x1E
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pix) as CFData) else { return (nil, holds) }
        let cg = CGImage(width: w,
                         height: h,
                         bitsPerComponent: 8,
                         bitsPerPixel: 32,
                         bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider,
                         decode: nil,
                         shouldInterpolate: false,
                         intent: .defaultIntent)
        return (cg, holds)
    }
}

// MARK: - モデル (設定と、背景スレッドで作るプレビュー)

final class PluginImagePreviewModel: ObservableObject {
    /// 画面に出している (出来上がった) プレビュー。長さ・分割数は、この画像を作ったときの値
    struct Shown {
        let image: UIImage?
        let rows: Int
        let ticks: Int
        let length: Double
        let holds: Int
    }

    static let lengthRange: ClosedRange<Double> = 0.25...64
    static let ticksRange: ClosedRange<Int> = 1...192

    @Published private(set) var length: Double
    @Published private(set) var ticks: Int
    @Published private(set) var threshold: Int
    @Published private(set) var invert: Bool
    @Published private(set) var showGray = false       // false = しきい値をかけたホールドの見た目 / true = 白黒そのまま
    @Published var laneView = true                     // true = レーンの比率で表示 / false = 256 × N ピクセルの比率で表示 (描き直しは不要)
    @Published private(set) var result: Shown? = nil
    @Published private(set) var srcSize: CGSize = .zero
    @Published private(set) var failed = false
    let beatAspect: Double

    // 背景スレッド (queue) だけで触る
    private let queue = DispatchQueue(label: "msd.pluginImagePreview", qos: .userInitiated)
    private var data: Data?
    private var loaded = false
    private var source: CGImage? = nil
    private var cache: [UInt8] = []
    private var cacheH = 0

    // 古い計算を飛ばすための世代番号 (複数のスレッドから触る)
    private let lock = NSLock()
    private var latest = 0

    init(data: Data?, params: PluginImageParams?) {
        let p = params ?? PluginImageParams(length: 4, ticks: 32, threshold: 128, invert: false, beatAspect: 0.85)
        self.length = min(max(p.length, Self.lengthRange.lowerBound), Self.lengthRange.upperBound)
        self.ticks = min(max(p.ticks, Self.ticksRange.lowerBound), Self.ticksRange.upperBound)
        self.threshold = min(max(p.threshold, 0), 255)
        self.invert = p.invert
        self.beatAspect = p.beatAspect.isFinite && p.beatAspect > 0 ? p.beatAspect : 0.85
        self.data = data
        refresh()
    }

    // MARK: 設定を変える (範囲に収めて、プレビューを作り直す)

    func setLength(_ v: Double) {
        let n = min(max((v * 4).rounded() / 4, Self.lengthRange.lowerBound), Self.lengthRange.upperBound)
        if n == length { return }
        length = n
        refresh()
    }

    func setTicks(_ v: Int) {
        let n = min(max(v, Self.ticksRange.lowerBound), Self.ticksRange.upperBound)
        if n == ticks { return }
        ticks = n
        refresh()
    }

    func setThreshold(_ v: Int) {
        let n = min(max(v, 0), 255)
        if n == threshold { return }
        threshold = n
        refresh()
    }

    func setInvert(_ v: Bool) {
        if v == invert { return }
        invert = v
        refresh()
    }

    func setShowGray(_ v: Bool) {
        if v == showGray { return }
        showGray = v
        refresh()
    }

    /// Lua に返す答え: "長さ 分割数 しきい値 反転(0/1)"
    func answer() -> String {
        return "\(length) \(ticks) \(threshold) \(invert ? 1 : 0)"
    }

    // MARK: プレビューの作成

    private func isStale(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen != latest
    }

    private func refresh() {
        lock.lock()
        latest += 1
        let gen = latest
        lock.unlock()
        let len = length
        let tk = ticks
        let thr = threshold
        let inv = invert
        let gr = showGray
        let w = PluginImageTools.laneWidth
        let h = max(1, Int((len * Double(tk)).rounded()))      // img2hold と同じ丸め (math.floor(len * ompu + 0.5))
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isStale(gen) { return }
            if !self.loaded {
                self.loaded = true
                if let d = self.data, let img = PluginImageTools.load(d) {
                    self.source = img
                    let sz = CGSize(width: img.width, height: img.height)
                    DispatchQueue.main.async { self.srcSize = sz }
                }
                self.data = nil
            }
            guard let src = self.source else {
                DispatchQueue.main.async { self.failed = true }
                return
            }
            if self.cacheH != h || self.cache.isEmpty {
                guard let g = PluginImageTools.gray(src, w: w, h: h) else {
                    DispatchQueue.main.async { self.failed = true }
                    return
                }
                self.cache = g
                self.cacheH = h
            }
            if self.isStale(gen) { return }
            let r = PluginImageTools.render(gray: self.cache, w: w, h: h, threshold: thr, invert: inv, showGray: gr)
            var ui: UIImage? = nil
            if let cg = r.image { ui = UIImage(cgImage: cg) }
            let res = Shown(image: ui, rows: h, ticks: tk, length: len, holds: r.holds)
            DispatchQueue.main.async {
                if self.isStale(gen) { return }
                self.result = res
            }
        }
    }
}

// MARK: - 画面

struct PluginImagePreviewCard: View {
    @ObservedObject var state: EditorState
    let dialog: PluginDialog
    @StateObject private var model: PluginImagePreviewModel

    init(state: EditorState, dialog: PluginDialog) {
        _state = ObservedObject(wrappedValue: state)
        self.dialog = dialog
        _model = StateObject(wrappedValue: PluginImagePreviewModel(data: dialog.imageData, params: dialog.imageParams))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                card(height: min(max(geo.size.height - 24, 240), 620))
                    .frame(maxWidth: 800)
                    .padding(.horizontal, 12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: 全体

    private func card(height: CGFloat) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(dialog.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.laneCyan)
                if !dialog.message.isEmpty {
                    Text(dialog.message)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 12) {
                previewPane
                controlsPane
                    .frame(width: 288)
            }
            .frame(maxHeight: .infinity)
            buttons
        }
        .padding(14)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.35), lineWidth: 1))
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("キャンセル") { state.resolvePluginDialog(nil) }
                .buttonStyle(.bordered)
            Button("ホールドを作成") { state.resolvePluginDialog(model.answer()) }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
        }
    }

    private var canCreate: Bool {
        guard let r = model.result else { return false }
        return r.holds > 0
    }

    // MARK: プレビュー

    private var previewPane: some View {
        GeometryReader { geo in
            previewContent(box: geo.size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func previewContent(box: CGSize) -> some View {
        if model.failed {
            Text("画像を読み込めませんでした")
                .font(.system(size: 13))
                .foregroundColor(Color.red.opacity(0.9))
                .frame(width: box.width, height: box.height)
        } else if let r = model.result, let ui = r.image {
            let size = previewSize(r, box: box)
            ScrollView(.vertical, showsIndicators: true) {
                ZStack {
                    Image(uiImage: ui)
                        .resizable()
                        .interpolation(.none)
                    gridOverlay(r)
                }
                .frame(width: size.width, height: size.height)
                .overlay(Rectangle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                .frame(width: box.width)
                .padding(.vertical, 6)
            }
        } else {
            ProgressView()
                .frame(width: box.width, height: box.height)
        }
    }

    /// プレビューの大きさ。レーンの比率 = 幅に対する高さが (長さ × 1拍の高さ) / 幅、ピクセルの比率 = 行数 / 256
    private func previewSize(_ r: PluginImagePreviewModel.Shown, box: CGSize) -> CGSize {
        let aspectRaw: Double = model.laneView
            ? r.length * model.beatAspect
            : Double(r.rows) / Double(PluginImageTools.laneWidth)
        let a = CGFloat(max(0.02, min(aspectRaw, 60)))
        let bw = max(box.width - 14, 40)
        let bh = max(box.height - 14, 40)
        let fitW = min(bw, bh / a)
        let pw = max(fitW, min(bw, 150))          // 縦に長いときは、細くなりすぎないよう下限を置いて、縦にスクロールさせる
        return CGSize(width: pw, height: pw * a)
    }

    /// 拍の線 (下 = カーソルの拍 = 0)。ホールドは、この線の上へ向かって並ぶ
    private func gridOverlay(_ r: PluginImagePreviewModel.Shown) -> some View {
        Canvas { ctx, size in
            let beats = r.length
            if beats <= 0 { return }
            let perBeat = size.height / CGFloat(beats)
            let n = Int(beats + 1e-9)
            for b in 0...n {
                let y = size.height - CGFloat(b) * perBeat
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(Color.white.opacity(0.4)), lineWidth: 1)
                if perBeat >= 14 {
                    let label = Text("\(b)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.85))
                    if y < 12 {
                        ctx.draw(label, at: CGPoint(x: 3, y: y + 1), anchor: .topLeading)
                    } else {
                        ctx.draw(label, at: CGPoint(x: 3, y: y - 1), anchor: .bottomLeading)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: 設定

    private var controlsPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                lengthSection
                ticksSection
                thresholdSection
                optionSection
                infoSection
            }
            .padding(.vertical, 2)
        }
    }

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            header("長さ", value: String(format: "%g", model.length) + " 拍")
            HStack(spacing: 8) {
                stepButton("−") { model.setLength(model.length - 0.25) }
                Slider(value: Binding(get: { model.length }, set: { model.setLength($0) }),
                       in: PluginImagePreviewModel.lengthRange,
                       step: 0.25)
                    .tint(Color.laneCyan)
                stepButton("+") { model.setLength(model.length + 0.25) }
            }
            chips([1, 2, 4, 8, 16], isOn: { Double($0) == model.length }) { model.setLength(Double($0)) }
        }
    }

    private var ticksSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            header("分割数 (1拍あたりの tick)", value: "1/\(model.ticks)")
            HStack(spacing: 8) {
                stepButton("−") { model.setTicks(model.ticks - 1) }
                Slider(value: Binding(get: { Double(model.ticks) }, set: { model.setTicks(Int($0.rounded())) }),
                       in: 1...192,
                       step: 1)
                    .tint(Color.laneCyan)
                stepButton("+") { model.setTicks(model.ticks + 1) }
            }
            chips([8, 12, 16, 24, 32, 48, 64, 96, 192], isOn: { $0 == model.ticks }) { model.setTicks($0) }
        }
    }

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            header("しきい値 (これより暗い所がホールド)", value: "\(model.threshold)")
            HStack(spacing: 8) {
                stepButton("−") { model.setThreshold(model.threshold - 1) }
                Slider(value: Binding(get: { Double(model.threshold) }, set: { model.setThreshold(Int($0.rounded())) }),
                       in: 0...255,
                       step: 1)
                    .tint(Color.laneCyan)
                stepButton("+") { model.setThreshold(model.threshold + 1) }
            }
        }
    }

    private var optionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.invert }, set: { model.setInvert($0) })) {
                Text("反転 (明るい所をホールドに)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .tint(Color.laneCyan)
            VStack(alignment: .leading, spacing: 4) {
                Text("表示")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.6))
                Picker("", selection: Binding(get: { model.showGray ? 1 : 0 }, set: { model.setShowGray($0 == 1) })) {
                    Text("ホールド").tag(0)
                    Text("白黒").tag(1)
                }
                .pickerStyle(.segmented)
                Picker("", selection: Binding(get: { model.laneView ? 0 : 1 }, set: { model.laneView = ($0 == 0) })) {
                    Text("レーンの比率").tag(0)
                    Text("256×N px").tag(1)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let r = model.result {
                Text("元画像 \(Int(model.srcSize.width))×\(Int(model.srcSize.height)) px")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.6))
                Text("→ 256×\(r.rows) px (\(String(format: "%g", r.length)) 拍 × \(r.ticks))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.6))
                Text("ホールド \(r.holds) 本")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(holdColor(r.holds))
                if r.holds == 0 {
                    Text("ホールドがありません。しきい値や反転を変えてください")
                        .font(.system(size: 11))
                        .foregroundColor(Color.red.opacity(0.9))
                } else if r.holds > 5000 {
                    Text("本数が多いと、作るのに時間がかかります (目安)")
                        .font(.system(size: 11))
                        .foregroundColor(Color.orange)
                }
            } else {
                Text("計算中…")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.6))
            }
        }
    }

    private func holdColor(_ n: Int) -> Color {
        if n == 0 { return Color.red.opacity(0.9) }
        if n > 50000 { return Color.red.opacity(0.9) }
        if n > 5000 { return Color.orange }
        return Color.white
    }

    // MARK: 部品

    private func header(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.6))
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    private func stepButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func chips(_ values: [Int], isOn: @escaping (Int) -> Bool, action: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 6)], spacing: 6) {
            ForEach(values, id: \.self) { v in
                Button {
                    action(v)
                } label: {
                    Text("\(v)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(isOn(v) ? Color.black : Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isOn(v) ? Color.laneCyan : Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
