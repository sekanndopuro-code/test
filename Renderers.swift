import SwiftUI

extension Color {
    static let laneCyan = Color(red: 0.0, green: 0.9, blue: 0.9)

    // ── ノーツの色: 本家 Malody のスクリーンショット (iPad Air 4) から実測した値 ──
    // タップ: 外側の明るい水色の縁 → 濃い青緑の帯 → 中心の白に近い水色 (外へ、ごく弱い水色のにじみ)
    static let tapOuter = Color(red: 0.643, green: 0.910, blue: 1.000)
    static let tapMid = Color(red: 0.016, green: 0.443, blue: 0.635)
    static let tapCore = Color(red: 0.816, green: 0.996, blue: 1.000)
    static let tapGlow = Color(red: 0.250, green: 0.800, blue: 1.000)
    // ウィップ: 黄色の縁 → オリーブ色の帯 → 中心の淡い黄色
    static let wipeOuter = Color(red: 0.969, green: 0.992, blue: 0.290)
    static let wipeMid = Color(red: 0.580, green: 0.588, blue: 0.290)
    static let wipeCore = Color(red: 1.000, green: 0.988, blue: 0.773)
    static let wipeGlow = Color(red: 0.950, green: 0.950, blue: 0.250)
    static let wipeFill = Color.wipeOuter                                          // シークバーの密度表示などで使う黄色
    // スライドの点 (白 → 水色の輪 → 白)。本家は、輪ごとに少しずつ透けている (23個の点を背景との回帰で実測):
    //   外側の白い輪 α=0.86 / 水色の輪 α=0.60 / 中心 α=0.94。色は透けていない場合の色 (背景が透ける分、明るめ)
    static let dotOuter = Color(red: 234.0 / 255.0, green: 251.0 / 255.0, blue: 1.000).opacity(0.86)
    static let dotRing = Color(red: 182.0 / 255.0, green: 242.0 / 255.0, blue: 1.000).opacity(0.60)
    static let dotCenter = Color(red: 243.0 / 255.0, green: 252.0 / 255.0, blue: 254.0 / 255.0).opacity(0.94)
    // スライドのリボン: 白に近い水色を、約 40% の濃さで重ねる (本家の単スライドを実測: R/G/B とも α=0.40)
    // 以前の 55% は、スライドが二重に重なった所を測ってしまった値だった
    static let ribbonFill = Color(red: 0.83, green: 1.0, blue: 1.0).opacity(0.40)

    // 選択中のノーツ: 通常色の「青い成分」を赤にした色 (明るさ・形は通常と同じ)
    static let selTapOuter = Color(red: 1.000, green: 0.660, blue: 0.660)
    static let selTapMid = Color(red: 0.620, green: 0.100, blue: 0.120)
    static let selTapCore = Color(red: 1.000, green: 0.820, blue: 0.820)
    static let selTapGlow = Color(red: 1.000, green: 0.300, blue: 0.300)
    static let selWipeOuter = Color(red: 1.000, green: 0.360, blue: 0.360)
    static let selWipeMid = Color(red: 0.580, green: 0.250, blue: 0.250)
    static let selWipeCore = Color(red: 1.000, green: 0.800, blue: 0.800)
    static let selWipeGlow = Color(red: 1.000, green: 0.300, blue: 0.300)
    static let selDotOuter = Color(red: 1.000, green: 0.940, blue: 0.940).opacity(0.86)
    static let selDotRing = Color(red: 1.000, green: 0.500, blue: 0.500).opacity(0.60)
    static let selDotCenter = Color(red: 1.000, green: 0.900, blue: 0.900).opacity(0.94)
    static let selRibbon = Color(red: 1.0, green: 0.78, blue: 0.78).opacity(0.40)

    // 時刻表示の背後の、明るい半透明パネル (本家の実測: 約 (88, 88, 66) を 55%)。レーン左の番号欄まで続く
    static let timePanel = Color(red: 88.0 / 255.0, green: 88.0 / 255.0, blue: 66.0 / 255.0).opacity(0.55)
}

private func smallestPrime(_ d: Int) -> Int {
    if d < 4 { return max(d, 1) }
    var p = 2
    while p * p <= d {
        if d % p == 0 { return p }
        p += 1
    }
    return d
}

/// 拍の分割線の色 (reduced分母で色分け: 1=拍 / 2=シアン / 4=マゼンタ ...)。濃さは本家のスクリーンショットの実測に合わせている
private func lineStyle(rem: Int, den: Int) -> (Color, CGFloat) {
    if rem == 0 { return (Color.white.opacity(0.80), 1.4) }
    let g = gcdInt(rem, den)
    let rd = den / g
    switch rd {
    case 2: return (Color.laneCyan.opacity(0.70), 1.1)
    case 4: return (Color(red: 0.85, green: 0.3, blue: 0.85).opacity(0.60), 1.0)
    case 3, 6, 12: return (Color(red: 0.4, green: 0.85, blue: 0.5).opacity(0.50), 1.0)
    case 8: return (Color.white.opacity(0.30), 0.8)
    default: return (Color.white.opacity(0.18), 0.7)
    }
}

enum LaneRenderer {
    static func draw(ctx: GraphicsContext, size: CGSize, state: EditorState) {
        let g = state.geo(size)
        // FX 表示 (擬似テストプレイ): scroll / jump を反映して、seg の丸なしで描く (drawFX)
        if g.fx != nil {
            drawFX(ctx: ctx, g: g, state: state)
            return
        }
        var c = ctx
        // 背景は塗らない (EditorBackground の背景画像を透かす)
        // 左の番号欄だけは、時刻表示から続く明るいパネルを敷く (本家と同じ)
        c.fill(Path(CGRect(x: 0, y: 0, width: g.trackL, height: g.H)), with: .color(Color.timePanel))
        drawVLines(&c, g, lines: state.gridLines)
        drawHLines(&c, g, den: state.snapDen)
        drawBPM(&c, g, state)
        drawEffects(&c, g, state)
        drawRange(&c, g, state)
        // 全ノーツを毎フレーム調べるのをやめて、いま画面に掛かっているノーツだけを (元の並びのまま) 描く。
        // (描き方は同じ。画面の外のノーツは、もともと何も描かれていなかった)
        let allNotes = state.chart.notes
        let visible = state.visibleNoteIndices(g)
        drawNotes(&c, g, visible.count == allNotes.count ? allNotes : visible.map { allNotes[$0] },
                  selected: state.selectedIDs)
        drawOrder(&c, g, state)
        drawSprites(&c, g, state)
        drawSlideModify(&c, g, state)
        drawSlideDraft(&c, g, state)
        if let gh = state.ghost { drawGhost(&c, g, gh) }
        drawLasso(&c, state)
        drawPlayline(&c, g)
        drawLabels(&c, g)
    }

    static func drawVLines(_ c: inout GraphicsContext, _ g: LaneGeo, lines: Int) {
        let n = max(1, lines)
        for k in 0...n {
            let x = g.px(255.0 * Double(k) / Double(n))
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: g.H))
            let edge = (k == 0 || k == n)
            // 本家の縦線は、細くてもはっきり白い (実測: 背景に対して約 60% の白)
            c.stroke(p, with: .color(Color.white.opacity(edge ? 0.80 : 0.62)), lineWidth: edge ? 1.2 : 0.8)
        }
        // x=127 の中心線 (薄い赤)
        let cx = g.px(127.5)
        var p = Path()
        p.move(to: CGPoint(x: cx, y: 0))
        p.addLine(to: CGPoint(x: cx, y: g.H))
        c.stroke(p, with: .color(Color.red.opacity(0.28)), lineWidth: 1)
    }

    static func drawHLines(_ c: inout GraphicsContext, _ g: LaneGeo, den: Int) {
        drawHLines(&c, g, den: den, from: g.beatOf(g.H), to: g.beatOf(0), pxPerBeat: g.ppb)
    }

    /// 拍 b0...b1 の分割線。pxPerBeat = その範囲の 1 拍の画面の高さ (線の細かさを決める。FX 表示では範囲ごとに違う)
    /// within = true のときは、b0...b1 の中にある線だけを描く (FX 表示で、隣り合う範囲が同じ線を二重に描かないため)
    static func drawHLines(_ c: inout GraphicsContext, _ g: LaneGeo, den: Int, from b0: Double, to b1: Double, pxPerBeat: Double,
                           within: Bool = false) {
        var d = max(1, den)
        while d > 1 && pxPerBeat / Double(d) < 6 { d = d / smallestPrime(d) }
        let t0 = Int(floor(b0 * Double(d)))
        let t1 = Int(ceil(b1 * Double(d)))
        if t1 < t0 || t1 - t0 > 800 { return }
        for t in t0...t1 {
            if t < 0 { continue }
            let b = Double(t) / Double(d)
            if within && (b < b0 || b > b1) { continue }
            let y = g.py(b)
            let rem = ((t % d) + d) % d
            let st = lineStyle(rem: rem, den: d)
            var p = Path()
            p.move(to: CGPoint(x: g.trackL, y: y))
            p.addLine(to: CGPoint(x: g.trackL + g.trackW, y: y))
            c.stroke(p, with: .color(st.0), lineWidth: st.1)
        }
    }

    static func drawLabels(_ c: inout GraphicsContext, _ g: LaneGeo) {
        drawLabels(&c, g, from: g.beatOf(g.H), to: g.beatOf(0), pxPerBeat: g.ppb)
    }

    /// 拍 lo...hi の番号。pxPerBeat = その範囲の 1 拍の画面の高さ。
    /// mid を渡すと、番号の位置 (N 拍目と N+1 拍目の真ん中) がその範囲に入るものだけを描く
    /// (FX 表示で、隣り合う範囲が同じ番号を二重に描かないため)
    static func drawLabels(_ c: inout GraphicsContext, _ g: LaneGeo, from lo: Double, to hi: Double, pxPerBeat: Double,
                           mid: ClosedRange<Double>? = nil) {
        // 0拍始まり (mcファイルの値と同じ)
        // 番号 N は、N 拍目と N+1 拍目の線の真ん中に置く (本家と同じ)。下の端に半分見えている番号も出すため、1つ手前から数える
        let b0 = max(0, Int(floor(lo)) - 1)
        let b1 = Int(ceil(hi))
        if b1 < b0 || b1 - b0 > 200 { return }
        var step = 1
        while pxPerBeat * Double(step) < 18 { step *= 2 }
        for b in b0...b1 where b % step == 0 {
            let m = Double(b) + Double(step) / 2.0
            if let r = mid, !r.contains(m) { continue }
            let y = g.py(m)
            if y < -12 || y > g.H + 12 { continue }
            // 本家の番号は細くて縦長 (数字の高さ 約14.5pt、3桁で幅 約24pt)。レーンの左端の線に少し掛かる
            drawNumber(c, "\(b)", at: CGPoint(x: 6.5, y: y), anchor: .leading, size: 20.5, scaleX: 0.77, alpha: 0.75)
        }
    }

    static func drawBPM(_ c: inout GraphicsContext, _ g: LaneGeo, _ s: EditorState) {
        for tp in s.chart.times where tp.beat.value > 0 {
            let y = g.py(tp.beat.value)
            if y < -20 || y > g.H + 20 { continue }
            var p = Path()
            p.move(to: CGPoint(x: g.trackL, y: y))
            p.addLine(to: CGPoint(x: g.trackL + g.trackW, y: y))
            c.stroke(p, with: .color(Color.yellow.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            let t = Text(String(format: "BPM %.2f", tp.bpm)).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.yellow.opacity(0.8))
            c.draw(t, at: CGPoint(x: g.trackL + g.trackW - 4, y: y - 9), anchor: .trailing)
        }
    }

    /// effect (scroll / jump) がある拍に、青い点線と値を出す。
    /// BPM (黄色の点線、値はレーンの右側) と同じ拍に重なっても読めるように、値はレーンの左側に出す。
    /// 同じ拍に scroll と jump があるときは、線は 1 本、値は「scroll 2  jump 1000」のように 1 行に並べる
    static func drawEffects(_ c: inout GraphicsContext, _ g: LaneGeo, _ s: EditorState) {
        if s.chart.effects.isEmpty { return }
        // 画面に見えている effect だけを拾う (effect が多い譜面でも、毎フレームの負担を小さくする)
        var rows: [(beat: Double, items: [EffectPoint])] = []
        for e in s.chart.effects {
            let b = e.beat.value
            let y = g.py(b)
            if y < -20 || y > g.H + 20 { continue }
            if let k = rows.firstIndex(where: { abs($0.beat - b) < 1e-9 }) {
                rows[k].items.append(e)
            } else {
                rows.append((beat: b, items: [e]))
            }
        }
        let blue = Color(red: 0.35, green: 0.65, blue: 1.0)
        for row in rows {
            let y = g.py(row.beat)
            var p = Path()
            p.move(to: CGPoint(x: g.trackL, y: y))
            p.addLine(to: CGPoint(x: g.trackL + g.trackW, y: y))
            // 点線の位相を BPM の黄色の点線とずらして、同じ拍に重なっても両方の色が見えるようにする
            c.stroke(p, with: .color(blue.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [6, 4], dashPhase: 5))
            // scroll を先に、jump を後に並べる (同じ時刻では scroll を変えてから、その値で jump するため)
            let items = row.items.sorted { $0.kind == .scroll && $1.kind != .scroll }
            let text = items.map { "\($0.kind.label) \($0.valueText)" }.joined(separator: "  ")
            let t = Text(text).font(.system(size: 11, design: .monospaced)).foregroundColor(blue.opacity(0.95))
            c.draw(t, at: CGPoint(x: g.trackL + 4, y: y - 9), anchor: .leading)
        }
    }

    static func drawRange(_ c: inout GraphicsContext, _ g: LaneGeo, _ s: EditorState) {
        guard let lo = s.rangeStart else { return }
        let hiB = s.rangeEnd ?? lo
        let yLo = g.py(lo.value)
        let yHi = g.py(hiB.value)
        let rect = CGRect(x: g.trackL, y: min(yLo, yHi), width: g.trackW, height: max(2, abs(yLo - yHi)))
        c.fill(Path(rect), with: .color(Color.orange.opacity(0.14)))
        for y in [yLo, yHi] {
            var p = Path()
            p.move(to: CGPoint(x: g.trackL, y: y))
            p.addLine(to: CGPoint(x: g.trackL + g.trackW, y: y))
            c.stroke(p, with: .color(Color.orange.opacity(0.9)), lineWidth: 2)
        }
    }

    /// LASSO でなぞっている途中の線。お絵描きソフトの投げ縄のように、点線 + うす白の塗りで「囲む範囲」を見せる。
    /// 終点から始点へは細い点線で結ぶ (指を離すとその直線で閉じて、中のノーツを選択する)
    /// 「順番に選択」で選んだスライドに、色 (1番目 = 赤 / 以降 = 水色) と、始点の番号を重ねる
    static func drawOrder(_ c: inout GraphicsContext, _ g: LaneGeo, _ state: EditorState) {
        guard state.editing, !state.orderIDs.isEmpty else { return }
        var rank: [NoteID: Int] = [:]
        for (k, id) in state.orderIDs.enumerated() { rank[id] = k }
        let lo = g.beatOf(g.H) - 0.05
        let hi = g.beatOf(0) + 0.05
        let allNotes = state.chart.notes
        for ni in state.visibleNoteIndices(g) {
            let n = allNotes[ni]
            guard n.isSlide, let k = rank[n.id] else { continue }
            let fill = k == 0 ? Color(red: 1.0, green: 0.24, blue: 0.24) : Color(red: 0.35, green: 0.78, blue: 1.0)
            let hw = CGFloat(n.w) / 255.0 * g.trackW / 2.0
            let sb = n.beat.value
            var prevB = sb
            var prevX = Double(n.x)
            // 表示範囲に掛かっている区間だけを塗る (drawNotes のリボンと同じ切り詰め)
            for s in n.segs {
                let curB = sb + s.beat.value
                let curX = Double(n.x + s.x)
                if max(prevB, curB) >= lo && min(prevB, curB) <= hi {
                    var ta = 0.0
                    var tb = 1.0
                    let db = curB - prevB
                    if db != 0 {
                        let t1 = (lo - prevB) / db
                        let t2 = (hi - prevB) / db
                        ta = max(0.0, min(t1, t2))
                        tb = min(1.0, max(t1, t2))
                    }
                    if tb >= ta {
                        let pa = CGPoint(x: g.px(prevX + (curX - prevX) * ta), y: g.py(prevB + db * ta))
                        let pb = CGPoint(x: g.px(prevX + (curX - prevX) * tb), y: g.py(prevB + db * tb))
                        var q = Path()
                        q.move(to: CGPoint(x: pa.x - hw, y: pa.y))
                        q.addLine(to: CGPoint(x: pa.x + hw, y: pa.y))
                        q.addLine(to: CGPoint(x: pb.x + hw, y: pb.y))
                        q.addLine(to: CGPoint(x: pb.x - hw, y: pb.y))
                        q.closeSubpath()
                        c.fill(q, with: .color(fill.opacity(0.42)))
                    }
                }
                prevB = curB
                prevX = curX
            }
            let y0 = g.py(sb)
            if y0 > -20 && y0 < g.H + 20 {
                let cx = g.px(Double(n.x))
                let bar = CGRect(x: cx - hw, y: y0 - 4, width: hw * 2, height: 8)
                c.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(fill.opacity(0.9)))
                let badge = Path(ellipseIn: CGRect(x: cx - 12, y: y0 - 12, width: 24, height: 24))
                c.fill(badge, with: .color(Color.black.opacity(0.75)))
                c.stroke(badge, with: .color(fill), lineWidth: 2)
                let label = Text("\(k + 1)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                c.draw(label, at: CGPoint(x: cx, y: y0), anchor: .center)
            }
        }
    }

    /// プラグインが AddSprite で出した画像 (操作型プラグインのつまみなど) を、レーンの上に描く。
    /// 横の位置 X と幅 Width は、レーン幅 (ノーツが並ぶ幅) に対する %。縦の位置は Beat。高さは画像の縦横比のまま
    static func drawSprites(_ c: inout GraphicsContext, _ g: LaneGeo, _ state: EditorState) {
        guard state.editing, !state.pluginSprites.isEmpty else { return }
        for sp in state.pluginSprites where sp.visible {
            guard let ui = PluginImageCache.shared.image(dir: sp.dir, name: sp.image) else { continue }
            let w = g.trackW * CGFloat(sp.width / 100.0)
            let aspect: CGFloat = ui.size.width > 0 ? ui.size.height / ui.size.width : 1.0
            let h = w * aspect
            let cx = g.trackL + g.trackW * CGFloat(sp.x / 100.0)
            let cy = g.py(sp.beat)
            if cy < -h || cy > g.H + h { continue }
            let rect = CGRect(x: cx - w / 2.0, y: cy - h / 2.0, width: w, height: h)
            c.draw(Image(uiImage: ui), in: rect)
        }
    }

    static func drawLasso(_ c: inout GraphicsContext, _ state: EditorState) {
        let pts = state.lassoPoints
        guard state.tool == .lasso, pts.count >= 2 else { return }
        var line = Path()
        line.move(to: pts[0])
        for q in pts.dropFirst() { line.addLine(to: q) }
        var area = line
        area.closeSubpath()
        c.fill(area, with: .color(Color.white.opacity(0.10)))

        var closing = Path()
        closing.move(to: pts[pts.count - 1])
        closing.addLine(to: pts[0])
        c.stroke(closing, with: .color(Color.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))

        // 暗い下線を敷いてから白の点線を重ねる (明るい背景でも暗いノーツの上でも見えるように)
        c.stroke(line, with: .color(Color.black.opacity(0.55)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        c.stroke(line, with: .color(Color.white), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [7, 5]))
    }

    static func drawPlayline(_ c: inout GraphicsContext, _ g: LaneGeo) {
        var p = Path()
        p.move(to: CGPoint(x: g.trackL, y: g.playY))
        p.addLine(to: CGPoint(x: g.trackL + g.trackW, y: g.playY))
        c.stroke(p, with: .color(Color.laneCyan), lineWidth: 2.5)
    }

    /// Slide modify で選択中のスライド: 動かせる点 (seg) にシアンの輪を付ける (drawSegRings が false なら付けない)。
    /// 掴んでいる点 (ドラッグ中) は白い太い輪にする
    static func drawSlideModify(_ c: inout GraphicsContext, _ g: LaneGeo, _ state: EditorState) {
        guard state.tool == .slideModify, let id = state.modifySlideID,
              let ni = state.indexOfNote(id: id) else { return }
        let n = state.chart.notes[ni]
        for j in n.segs.indices {
            let grabbed = (j == state.modifySegIndex)
            if !grabbed && !drawSegRings { continue }
            let s = n.segs[j]
            let pt = CGPoint(x: g.px(Double(n.x + s.x)), y: g.py(n.beat.value + s.beat.value))
            if pt.y < -20 || pt.y > g.H + 20 { continue }
            let ring = Path(ellipseIn: CGRect(x: pt.x - 15, y: pt.y - 15, width: 30, height: 30))
            if grabbed {
                c.stroke(ring, with: .color(Color.white), lineWidth: 3)
            } else {
                c.stroke(ring, with: .color(Color.laneCyan), lineWidth: 2)
            }
        }
    }

    /// 作成中のスライド: まだ譜面に入っていない始点を描き、「いちばん最後に置いた点」に目印 (シアンの輪) をつける
    static func drawSlideDraft(_ c: inout GraphicsContext, _ g: LaneGeo, _ state: EditorState) {
        guard let d = state.slideDraft, let last = state.slideDraftLastPoint() else { return }
        if state.indexOfNote(id: d.noteID) == nil {
            var c2 = c
            c2.opacity = 0.8
            drawNotes(&c2, g, [Note(beat: d.beat, x: d.x, w: d.w)])
        }
        let pt = CGPoint(x: g.px(Double(last.x)), y: g.py(last.beat.value))
        let ring = Path(ellipseIn: CGRect(x: pt.x - 14, y: pt.y - 14, width: 28, height: 28))
        c.stroke(ring, with: .color(Color.laneCyan), lineWidth: 2)
    }

    static func drawGhost(_ c: inout GraphicsContext, _ g: LaneGeo, _ gh: Ghost) {
        var segs: [Seg] = []
        if let eb = gh.endBeat, let ex = gh.endX {
            segs = [Seg(beat: eb - gh.beat, x: ex - gh.x)]
        }
        let n = Note(beat: gh.beat, x: gh.x, w: gh.w, type: gh.tool == .wipe ? 4 : nil, segs: segs)
        var c2 = c
        c2.opacity = 0.55
        drawNotes(&c2, g, [n])
    }

    // ── ノーツの描き方 (本家 Malody に合わせた値。変えたいときはここを触る) ──
    /// タップ / ウィップの棒を、拍の線より上へ持ち上げる量 (pt)。本家は棒の下端が拍の線のすぐ上に乗る (実測: 8pt)。
    /// 0 にすると、棒の真ん中が拍の線に重なる (これまでの描き方)
    static let barLift: CGFloat = 8
    /// スライドの始点にも棒を描くか。本家はリボンと点だけで、棒は描かない
    static let drawSlideHeadBar = false
    /// Slide modify で選択中のスライドの seg に、動かせる目印のシアンの輪を付けるか。本家には無いので、false にすると輪は出ない (掴んでいる点の白い輪だけ残る)
    static let drawSegRings = true

    static func drawNotes(_ c: inout GraphicsContext, _ g: LaneGeo, _ notes: [Note], selected: Set<NoteID> = []) {
        let lo = g.beatOf(g.H) - 0.05
        let hi = g.beatOf(0) + 0.05
        // 画面に出る点 (スライドの始点と seg)。リボンを全部描いてから最後に重ねる (本家と同じく、点はいつもリボンの手前に見える)
        var dots: [CGPoint] = []
        var selDots: [CGPoint] = []
        // 1) スライドのリボン
        //    seg が何万個ある譜面でも、画面に掛かっている区間だけを描く。
        //    (以前は見えている slide の全 seg ぶんの図形を毎フレーム作っていたため、大量 seg の譜面で再生が重くなった)
        //    さらに各区間は表示範囲に切り詰めるので、壊れた値(何億拍も先)の seg があっても描画は画面内だけで済む。
        for n in notes where n.isSlide {
            let isSel = !selected.isEmpty && selected.contains(n.id)
            let hw = CGFloat(n.w) / 255.0 * g.trackW / 2.0
            let sb = n.beat.value
            var prevB = sb
            var prevX = Double(n.x)
            let y0 = g.py(sb)
            if y0 > -24 && y0 < g.H + 24 {
                let p0 = CGPoint(x: g.px(prevX), y: y0)
                if isSel { selDots.append(p0) } else { dots.append(p0) }
            }
            for s in n.segs {
                let curB = sb + s.beat.value
                let curX = Double(n.x + s.x)
                if max(prevB, curB) >= lo && min(prevB, curB) <= hi {
                    var ta = 0.0
                    var tb = 1.0
                    let db = curB - prevB
                    if db != 0 {
                        let t1 = (lo - prevB) / db
                        let t2 = (hi - prevB) / db
                        ta = max(0.0, min(t1, t2))
                        tb = min(1.0, max(t1, t2))
                    }
                    if tb >= ta {
                        let pa = CGPoint(x: g.px(prevX + (curX - prevX) * ta), y: g.py(prevB + db * ta))
                        let pb = CGPoint(x: g.px(prevX + (curX - prevX) * tb), y: g.py(prevB + db * tb))
                        var q = Path()
                        q.move(to: CGPoint(x: pa.x - hw, y: pa.y))
                        q.addLine(to: CGPoint(x: pa.x + hw, y: pa.y))
                        q.addLine(to: CGPoint(x: pb.x + hw, y: pb.y))
                        q.addLine(to: CGPoint(x: pb.x - hw, y: pb.y))
                        q.closeSubpath()
                        c.fill(q, with: .color(isSel ? Color.selRibbon : Color.ribbonFill))
                    }
                }
                let cy = g.py(curB)
                if cy > -24 && cy < g.H + 24 {
                    let pt = CGPoint(x: g.px(curX), y: cy)
                    dots.append(pt)                         // seg の点は、選択中でも通常の色のまま (本家は、赤くなるのは始点とリボンだけ)
                }
                prevB = curB
                prevX = curX
            }
        }
        // 2) タップ / ウィップの棒 (スライドの始点は、drawSlideHeadBar が true のときだけ)
        for n in notes {
            if n.isSlide && !drawSlideHeadBar { continue }
            let y = g.py(n.beat.value) - barLift
            if y < -24 || y > g.H + 24 { continue }
            let hw = CGFloat(n.w) / 255.0 * g.trackW / 2.0
            let cx = g.px(Double(n.x))
            let isSel = !selected.isEmpty && selected.contains(n.id)
            if n.isWipe {
                drawWipe(&c, xL: cx - hw, xR: cx + hw, yMid: y, selected: isSel)
            } else {
                let rect = CGRect(x: cx - hw, y: y - tapH / 2, width: hw * 2, height: tapH)
                drawTap(&c, rect: rect, selected: isSel)
            }
        }
        // 3) スライドの点 (白 → 水色の輪 → 白)。選択中のスライドで赤くなるのは、始点の点だけ (seg の点は通常の色)
        for pt in dots { drawDot(&c, pt, selected: false) }
        for pt in selDots { drawDot(&c, pt, selected: true) }
    }

    /// タップの棒の高さ (pt)。本家の実測 約 12pt (縁 1.5 + 帯 1.5 + 芯 5 + 帯 1.5 + 縁 1.5 のぶん)
    static let tapH: CGFloat = 11.5

    /// タップ: 明るい水色の縁 → 濃い青緑の帯 → 白に近い水色の芯 (角は丸い)。外側に弱い水色のにじみ
    static func drawTap(_ c: inout GraphicsContext, rect: CGRect, selected: Bool) {
        let outer = selected ? Color.selTapOuter : Color.tapOuter
        let mid = selected ? Color.selTapMid : Color.tapMid
        let core = selected ? Color.selTapCore : Color.tapCore
        let glow = selected ? Color.selTapGlow : Color.tapGlow
        let body = Path(roundedRect: rect, cornerRadius: 3.2)
        c.stroke(body, with: .color(glow.opacity(0.22)), lineWidth: 4)
        c.fill(body, with: .color(outer))
        if rect.width > 8 {
            c.fill(Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 1.8), with: .color(mid))
            c.fill(Path(roundedRect: rect.insetBy(dx: 3.0, dy: 3.0), cornerRadius: 0.8), with: .color(core))
        }
    }

    /// ウィップ: 左右の端がとがった六角形の棒 (黄色の縁 → オリーブ色の帯 → 淡い黄色の芯) の、さらに外側に「<」「>」の矢印
    static func drawWipe(_ c: inout GraphicsContext, xL: CGFloat, xR: CGFloat, yMid: CGFloat, selected: Bool) {
        let outer = selected ? Color.selWipeOuter : Color.wipeOuter
        let mid = selected ? Color.selWipeMid : Color.wipeMid
        let core = selected ? Color.selWipeCore : Color.wipeCore
        let glow = selected ? Color.selWipeGlow : Color.wipeGlow
        let h: CGFloat = 6.0            // 棒の高さ 12pt の半分
        let cap: CGFloat = 4.0          // 外側の矢印ぶん (ノーツの端 = 矢印の先)
        let bx0 = xL + cap
        let bx1 = xR - cap
        let width = bx1 - bx0
        if width < 6 {
            // ごく細いときは、ただの角丸の棒で描く
            let r = CGRect(x: xL, y: yMid - h, width: max(2, xR - xL), height: h * 2)
            c.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(outer))
            return
        }
        let t = min(CGFloat(3.4), width / 2 - 1.5)      // 端のとがりの深さ
        let shape = wipePath(xL: bx0, xR: bx1, yMid: yMid, h: h, t: t, delta: 0)
        c.stroke(shape, with: .color(glow.opacity(0.22)), lineWidth: 4)
        c.fill(shape, with: .color(outer))
        c.fill(wipePath(xL: bx0, xR: bx1, yMid: yMid, h: h, t: t, delta: 2.0), with: .color(mid))
        c.fill(wipePath(xL: bx0, xR: bx1, yMid: yMid, h: h, t: t, delta: 3.5), with: .color(core))
        var left = Path()
        left.move(to: CGPoint(x: xL + 3.2, y: yMid - 4.5))
        left.addLine(to: CGPoint(x: xL + 0.8, y: yMid))
        left.addLine(to: CGPoint(x: xL + 3.2, y: yMid + 4.5))
        var right = Path()
        right.move(to: CGPoint(x: xR - 3.2, y: yMid - 4.5))
        right.addLine(to: CGPoint(x: xR - 0.8, y: yMid))
        right.addLine(to: CGPoint(x: xR - 3.2, y: yMid + 4.5))
        let style = StrokeStyle(lineWidth: 1.6, lineCap: .butt, lineJoin: .miter)
        c.stroke(left, with: .color(outer), style: style)
        c.stroke(right, with: .color(outer), style: style)
    }

    /// ウィップ本体の六角形。delta だけ内側へ縮めた相似でない縁取り (縁・帯・芯の重ね描き用) も作れる。
    /// h = 高さの半分、t = 端のとがりの深さ (先端から角までの横幅)
    private static func wipePath(xL: CGFloat, xR: CGFloat, yMid: CGFloat, h: CGFloat, t: CGFloat, delta: CGFloat) -> Path {
        let len = (h * h + t * t).squareRoot()
        let tipDX = delta * len / h
        let cornerDX = t + delta * (len - t) / h
        let top = yMid - h + delta
        let bottom = yMid + h - delta
        var p = Path()
        p.move(to: CGPoint(x: xL + tipDX, y: yMid))
        p.addLine(to: CGPoint(x: xL + cornerDX, y: top))
        p.addLine(to: CGPoint(x: xR - cornerDX, y: top))
        p.addLine(to: CGPoint(x: xR - tipDX, y: yMid))
        p.addLine(to: CGPoint(x: xR - cornerDX, y: bottom))
        p.addLine(to: CGPoint(x: xL + cornerDX, y: bottom))
        p.closeSubpath()
        return p
    }

    /// スライドの点: 外側の白い輪 (半径 11.25pt) → 水色の輪 → 中心の白 (本家の実測)
    private static func drawDot(_ c: inout GraphicsContext, _ p: CGPoint, selected: Bool) {
        let outer = selected ? Color.selDotOuter : Color.dotOuter
        let ring = selected ? Color.selDotRing : Color.dotRing
        let center = selected ? Color.selDotCenter : Color.dotCenter
        // 3つの層は半透明なので、重ねずに、輪の形 (外側の円 − 内側の円) で塗り分ける。
        // 半径は本家の実測 (輪の境目): 中心 4.5pt / 水色の輪 〜 7.8pt / 外側の白い輪 〜 11.4pt
        func disc(_ r: CGFloat) -> CGRect { CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2) }
        var outerBand = Path(ellipseIn: disc(11.4))
        outerBand.addEllipse(in: disc(7.8))
        c.fill(outerBand, with: .color(outer), style: FillStyle(eoFill: true))
        var ringBand = Path(ellipseIn: disc(7.8))
        ringBand.addEllipse(in: disc(4.5))
        c.fill(ringBand, with: .color(ring), style: FillStyle(eoFill: true))
        c.fill(Path(ellipseIn: disc(4.5)), with: .color(center))
    }
}

// MARK: - 本家の拍番号 (細くて縦長の数字)

/// 標準の書体を横に潰して、本家の細長い拍番号に近づける。
/// size = 書体の大きさ (数字の高さ ≒ size × 0.705) / scaleX = 横の潰し具合 (本家の実測で 約 0.77)
private func drawNumber(_ c: GraphicsContext, _ s: String, at p: CGPoint, anchor: UnitPoint,
                        size: CGFloat, scaleX: CGFloat, alpha: Double) {
    var cc = c
    cc.translateBy(x: p.x, y: p.y)
    cc.scaleBy(x: scaleX, y: 1)
    let t = Text(s).font(.system(size: size, weight: .regular)).foregroundColor(Color.white.opacity(alpha))
    cc.draw(t, at: .zero, anchor: anchor)
}

/// 左の帯の目盛りの色 (本家の実測: 拍の線は純白で約1pt、拍の半分の目盛りは明るい水色)
private func stripLineStyle(rem: Int, den: Int) -> (Color, CGFloat) {
    if rem == 0 { return (Color.white.opacity(0.95), 1.1) }
    if den / gcdInt(rem, den) == 2 { return (Color(red: 0.40, green: 0.81, blue: 0.93), 1.0) }
    return lineStyle(rem: rem, den: den)
}

// MARK: - 左の縦長タイムライン

enum StripRenderer {
    /// 帯の本体の右端 (本家 143.5pt)。この右に、暗い側面 (斜めの面取り) が 約10pt 続く (SeekRenderer が描く)
    static let faceW: CGFloat = 143.5
    static let faceTop: CGFloat = 2
    static let faceBottomInset: CGFloat = 2.5
    /// 帯・シークバーの地。本家は半透明の暗い色で、背景画像と、レーンからはみ出したノーツが透けて見える
    /// (本家のスクリーンショットの実測: 背景を 約 58% 暗くした色)。不透明にしたいときは opacity を 1 に近づける
    static let faceColor = Color.black.opacity(0.58)

    static func draw(ctx: GraphicsContext, size: CGSize, state: EditorState) {
        var c = ctx
        let H = size.height
        let W = size.width
        let faceRect = CGRect(x: 0, y: faceTop, width: faceW, height: max(1, H - faceTop - faceBottomInset))
        c.fill(Path(faceRect), with: .color(faceColor))

        let beats = state.stripBeats
        let ppb = Double(H) / beats
        let center = H * 0.5
        let vb = state.currentBeat()
        func y(_ b: Double) -> CGFloat { center - CGFloat((b - vb) * ppb) }

        // 目盛りと番号は、帯の本体からはみ出さないように切り取る
        var inner = c
        inner.clip(to: Path(faceRect))

        let b0 = vb - Double(center) / ppb
        let b1 = vb + Double(H - center) / ppb
        var d = max(1, state.snapDen)
        while d > 1 && ppb / Double(d) < 6 { d = d / smallestPrime(d) }
        let t0 = Int(floor(b0 * Double(d)))
        let t1 = Int(ceil(b1 * Double(d)))
        if t1 >= t0 && t1 - t0 < 1500 {
            for t in t0...t1 {
                if t < 0 { continue }
                let b = Double(t) / Double(d)
                let yy = y(b)
                let rem = ((t % d) + d) % d
                let st = stripLineStyle(rem: rem, den: d)
                // 拍の線は 6.5pt 〜 帯の本体の右端、細かい目盛りは 9pt から約 27pt の長さ (本家の実測)
                let x0: CGFloat = rem == 0 ? 6.5 : 9
                let x1: CGFloat = rem == 0 ? (faceW - 0.5) : 36
                var p = Path()
                p.move(to: CGPoint(x: x0, y: yy))
                p.addLine(to: CGPoint(x: x1, y: yy))
                inner.stroke(p, with: .color(st.0), lineWidth: st.1)
            }
        }
        // 拍番号 (0拍始まり)。本家は細くて縦長 (数字の高さ 約24.5pt、3桁で幅 約36.5pt)
        var step = 1
        while ppb * Double(step) < 28 { step *= 2 }
        let lb0 = max(0, Int(floor(b0)) - 1)
        let lb1 = Int(ceil(b1))
        if lb1 >= lb0 && lb1 - lb0 < 2000 {
            for b in lb0...lb1 where b % step == 0 {
                drawNumber(inner, "\(b)", at: CGPoint(x: faceW * 0.53, y: y(Double(b) + Double(step) / 2.0)),
                           anchor: .center, size: 34.7, scaleX: 0.78, alpha: 0.78)
            }
        }
        // 帯の枠 (本家の実測: 上下と左は明るい線、右は暗い線。右の外側の側面は SeekRenderer が描く)
        var tb = Path()
        tb.move(to: CGPoint(x: 0, y: faceTop))
        tb.addLine(to: CGPoint(x: faceW, y: faceTop))
        tb.move(to: CGPoint(x: 0, y: H - faceBottomInset))
        tb.addLine(to: CGPoint(x: faceW, y: H - faceBottomInset))
        c.stroke(tb, with: .color(Color.white.opacity(0.57)), lineWidth: 1.3)
        var lf = Path()
        lf.move(to: CGPoint(x: 0.4, y: faceTop))
        lf.addLine(to: CGPoint(x: 0.4, y: H - faceBottomInset))
        c.stroke(lf, with: .color(Color.white.opacity(0.60)), lineWidth: 0.8)
        var rt = Path()
        rt.move(to: CGPoint(x: faceW - 0.3, y: faceTop))
        rt.addLine(to: CGPoint(x: faceW - 0.3, y: H - faceBottomInset))
        c.stroke(rt, with: .color(Color.white.opacity(0.18)), lineWidth: 0.8)
        // 現在位置マーカー
        var m = Path()
        m.move(to: CGPoint(x: 0, y: center))
        m.addLine(to: CGPoint(x: W, y: center))
        c.stroke(m, with: .color(.white), lineWidth: 3)
        var tri = Path()
        tri.move(to: CGPoint(x: 0, y: center))
        tri.addLine(to: CGPoint(x: 9, y: center - 7))
        tri.addLine(to: CGPoint(x: 9, y: center + 7))
        tri.closeSubpath()
        c.fill(tri, with: .color(.orange))
    }
}

// MARK: - 曲全体シークバー

enum SeekRenderer {
    // MARK: 本家の実測値 (iPad Air 4 横画面 1180×820pt。2360×1640px のスクリーンショットから)

    /// 本家のシークバーは、画面の高さより 約0.16% 長い (821.3pt / 820pt)。曲の頭は画面の下端より 1.3pt 外にある。
    /// 再生位置の線も、ヒストグラムの 120 本も、この高さに対して並ぶ (SeekView のタッチも同じ高さで割る)
    static let regionScale: CGFloat = 821.3 / 820.0
    /// 現在表示しているレーンの範囲 (白っぽい帯)。本家には無いので初期値は false (true にすると、これまでどおり出る)
    static let showViewWindow = false

    /// ヒストグラムの棒 (密度の計算は SeekDensity.swift)
    static let barColor = Color(red: 238.0 / 255.0, green: 102.0 / 255.0, blue: 100.0 / 255.0)
    static let barMaxW: CGFloat = 67.4        // 最大の長さ。右端 (W - 0.5) から、左の帯の側面の左端まで届く。1 段 (1/20) = 3.37pt
    static let barHeightRatio: CGFloat = 0.789      // 棒の太さ = 1 本のピッチ (6.84pt) の 0.789 倍 = 5.4pt
    static let barTopRatio: CGFloat = 0.02          // 棒の上端は、その区間の上端から ピッチの 0.02 倍 (0.14pt) 下

    /// 再生位置: 白い線 (太さ 2.3pt) の両端に、橙色の短い縦棒 (6 × 12.3pt)
    static let playLineH: CGFloat = 2.3
    static let capW: CGFloat = 6             // 左の縦棒の幅 (右は 5.2pt。右端の枠線に少し重なるため)
    static let capRightW: CGFloat = 5.2
    static let capH: CGFloat = 12.3
    static let capColor = Color(red: 251.0 / 255.0, green: 176.0 / 255.0, blue: 57.0 / 255.0)

    static func draw(ctx: GraphicsContext, size: CGSize, state: EditorState) {
        var c = ctx
        let H = size.height
        let W = size.width
        let top = StripRenderer.faceTop
        let bottom = H - StripRenderer.faceBottomInset
        // 地は本家と同じ半透明の暗い色 (背景画像とはみ出したノーツが透ける)
        c.fill(Path(CGRect(x: 0, y: top, width: W, height: max(1, bottom - top))), with: .color(StripRenderer.faceColor))
        // 左の帯の側面 (暗い平行四辺形)。帯の右端 (負の座標) から 約10.5pt 右まで、上下は斜めに削れる
        let ox = StripRenderer.faceW - StripView.width
        let sideW: CGFloat = 10.5
        var side = Path()
        side.move(to: CGPoint(x: ox, y: top))
        side.addLine(to: CGPoint(x: ox + sideW, y: top + sideW))
        side.addLine(to: CGPoint(x: ox + sideW, y: bottom - sideW))
        side.addLine(to: CGPoint(x: ox, y: bottom))
        side.closeSubpath()
        c.fill(side, with: .color(Color(red: 23.0 / 255.0, green: 22.0 / 255.0, blue: 20.0 / 255.0)))

        let total = max(1.0, state.totalSec)
        let regionH = H * regionScale
        func y(_ sec: Double) -> CGFloat { regionH - CGFloat(sec / total) * regionH }
        let x0 = ox + sideW        // 側面の右 (これより右が、シークバー本体)
        let right = W - 0.5        // 棒・再生位置の線の右端 (右の枠線の位置)

        // 側面に重なる部分を暗くするための矩形を、描きながら集める。
        // 本家は、側面が「黒 50%」の透明な面で、棒・再生位置の線は その下を通るので、側面の中だけ半分の明るさに見える
        var underSide: [CGRect] = []

        // 表示ウィンドウ (本家には無い。showViewWindow = true のときだけ)
        if showViewWindow {
            let lane = state.geo(CGSize(width: 100, height: H))
            let yTop = y(state.timeMap.sec(atBeat: max(0, lane.beatOf(0))))
            let yBot = y(state.timeMap.sec(atBeat: max(0, lane.beatOf(H))))
            c.fill(Path(CGRect(x: x0, y: yTop, width: W - x0, height: max(2, yBot - yTop))), with: .color(Color.white.opacity(0.12)))
        }

        // ノーツ密度のヒストグラム: 曲全体を 120 等分した 1 本 1 本。長さ = (その区間のノーツ数 ÷ 最大の区間) × barMaxW
        let ratios = state.seekDensityRatios()
        let n = ratios.count
        if n > 0 {
            let pitch = regionH / CGFloat(n)
            for j in 0..<n {                                  // j = 0 が曲の頭 (画面の下)
                let r = CGFloat(ratios[j])
                if r <= 0 { continue }
                let len = barMaxW * r
                let yy = CGFloat(n - 1 - j) * pitch + pitch * barTopRatio
                let rect = CGRect(x: right - len, y: yy, width: len, height: pitch * barHeightRatio)
                c.fill(Path(rect), with: .color(barColor))
                if rect.minX < x0 { underSide.append(rect) }
            }
        }

        // 再生位置 (本家は 白い線 + 両端の橙色の縦棒。ヒストグラムの手前)
        let yp = y(state.currentSec())
        let lineRect = CGRect(x: ox, y: yp - playLineH / 2, width: right - ox, height: playLineH)
        c.fill(Path(lineRect), with: .color(Color.white))
        underSide.append(lineRect)
        let leftCap = CGRect(x: ox - 0.2, y: yp - capH / 2, width: capW, height: capH)
        let rightCap = CGRect(x: right - capRightW, y: yp - capH / 2, width: capRightW, height: capH)
        c.fill(Path(roundedRect: leftCap, cornerRadius: 2.5), with: .color(capColor))
        c.fill(Path(roundedRect: rightCap, cornerRadius: 2.5), with: .color(capColor))
        underSide.append(leftCap)

        // 側面の黒 50% (側面の形に切り抜いて、側面に掛かる部分だけ)
        // 棒・線・縦棒は互いに重なるので、1 つの Path にまとめて 1 回で塗る (別々に塗ると、重なった所が二重に暗くなって、
        // 縦棒の真ん中に暗い横線が出たり、縦棒の下の棒が透けて見えたりする)
        var dimPath = Path()
        for r in underSide {
            let w = min(r.maxX, x0) - r.minX
            if w > 0 {
                dimPath.addRect(CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
            }
        }
        var dim = c
        dim.clip(to: side)
        dim.fill(dimPath, with: .color(Color.black.opacity(0.5)))

        // 側面の縁 (棒の手前に出る明るい細い線)
        var sideEdge = Path()
        sideEdge.move(to: CGPoint(x: ox, y: top))
        sideEdge.addLine(to: CGPoint(x: ox + sideW, y: top + sideW))
        sideEdge.addLine(to: CGPoint(x: ox + sideW, y: bottom - sideW))
        sideEdge.addLine(to: CGPoint(x: ox, y: bottom))
        c.stroke(sideEdge, with: .color(Color.white.opacity(0.45)), lineWidth: 0.9)

        // 右の枠線 (本家の実測: 明るい細い線。時刻表示のパネルとの境目)
        var l = Path()
        l.move(to: CGPoint(x: W - 0.5, y: 0))
        l.addLine(to: CGPoint(x: W - 0.5, y: H))
        c.stroke(l, with: .color(Color.white.opacity(0.60)), lineWidth: 1)
    }
}

// MARK: - 時刻表示 (縦書き)

/// 本家の時刻表示: 細い字を広い字間 (1文字 20.25pt) で並べ、やわらかく光らせる。
/// 上の時刻 (総時間) は画面の上端から、下の時刻 (現在時刻) は下端から、どちらも 113.5pt の位置が中心
enum TimeLabelRenderer {
    static let pitch: CGFloat = 20.25          // 1文字の送り幅 (「:」「.」も1文字ぶんの枠を取る)
    static let centerX: CGFloat = 27.25        // 文字の中心 (このビューの左端から)。画面では 238pt
    static let edgeInset: CGFloat = 113.5
    static let fontSize: CGFloat = 25.5        // 数字の高さ 約18pt
    static let dotSize: CGFloat = 3
    static let upperDotY: CGFloat = -0.75      // 「:」の上の点 (文字の中心からの位置。下向きが +)
    static let lowerDotY: CGFloat = 7.75       // 「:」の下の点 と 「.」 (文字の下端に接する)

    static func draw(ctx: GraphicsContext, size: CGSize, state: EditorState) {
        var c = ctx
        // 明るい半透明のパネル (レーンの番号欄まで続く)
        c.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.timePanel))
        vtext(c, state.timeString(state.totalSec), centerY: edgeInset)
        vtext(c, state.timeString(state.currentSec()), centerY: size.height - edgeInset)
    }

    private static func dot(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat) {
        let r = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
        c.fill(Path(r), with: .color(.white))
    }

    private static func vtext(_ ctx: GraphicsContext, _ s: String, centerY: CGFloat) {
        var cc = ctx
        cc.translateBy(x: centerX, y: centerY)
        cc.rotate(by: .degrees(-90))        // 下から上へ読む。この座標では +x が上向き、+y が右向き (字の下向き)
        cc.addFilter(.shadow(color: Color.white.opacity(0.85), radius: 2.5))
        let font = Font.system(size: fontSize, weight: .light)
        let chars = Array(s)
        let mid = CGFloat(chars.count - 1) / 2
        cc.drawLayer { layer in
            for (i, ch) in chars.enumerated() {
                let x = (CGFloat(i) - mid) * pitch
                if ch == ":" {
                    dot(layer, x, upperDotY)
                    dot(layer, x, lowerDotY)
                } else if ch == "." {
                    dot(layer, x, lowerDotY)
                } else {
                    let t = Text(String(ch)).font(font).foregroundColor(.white)
                    layer.draw(t, at: CGPoint(x: x, y: 0.25), anchor: .center)
                }
            }
        }
    }
}

/// 拡大/縮小ボタンの形: 本家は「正六角形の左半分が画面の外に出た」形 (左端が垂直で、右に尖る五角形)。
/// 外枠 (線の中心) は、左 0.5pt・上下 0.75pt の内側。上辺は x=24.65 まで、右の先端は x=37.7 (本家の実測、幅 39 × 高さ 45)
struct ZoomButtonShape: Shape {
    func path(in r: CGRect) -> Path {
        let top = r.minY + 0.75
        let bottom = r.maxY - 0.75
        let left = r.minX + 0.5
        var p = Path()
        p.move(to: CGPoint(x: left, y: top))
        p.addLine(to: CGPoint(x: r.minX + 24.65, y: top))
        p.addLine(to: CGPoint(x: r.minX + 37.7, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + 24.65, y: bottom))
        p.addLine(to: CGPoint(x: left, y: bottom))
        p.closeSubpath()
        return p
    }
}
