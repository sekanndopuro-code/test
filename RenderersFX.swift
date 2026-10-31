import SwiftUI

// MARK: - FX 表示 (擬似テストプレイ) のレーン描画
//
// EditorState.fxMode が ON のあいだ、LaneRenderer.draw が drawFX に切り替わる (Renderers.swift)。
// 通常の表示は「拍 → 高さ」が一直線 (1 拍 = ppb ピクセル) だが、FX 表示は、テストプレイと同じ「表示位置 P(t) − P(今)」
// (Effects.swift の EffectMap) で高さが決まる。scroll で間隔が伸び縮みし、jump でその先が飛ぶ。
// マイナスの jump / scroll では、時刻の順と画面の順が一致しなくなる (奥へ戻る / 重なる)。
// なので「画面に見える拍の範囲」を、通常のように 1 つの区間では決められない。
// 見える表示位置の範囲を EffectMap.timeRanges で時刻の範囲に直し、それを拍の範囲に直して使う (`fxRanges`)。
//
// テストプレイとそろえてあること:
//   ・seg の丸は描かない (リボンとタップ / ウィップだけ)
//   ・判定を過ぎたもの (時刻が今より前のタップ / ウィップ、全体が過ぎたスライド) は出さない
//   ・スライドは、始点が画面の上端に入ってから出す (始点より前に伸びる部分も、そのとき一緒に出る)
//   ・逆走 (scroll < 0 / jump < 0) のある譜面では、スライドの区間は、終わりの点を判定が過ぎたら消える
//   ・jump で遠くへ飛んだリボンは、画面の範囲に切り詰めて描く (座標が大きすぎると描画が壊れるため)
// 当たり判定・編集は無い (見るだけ)。

/// FX 表示で、画面に見える表示位置に入る「拍の範囲」と、その範囲の 1 拍の画面の高さ
struct FXRange {
    let lo: Double              // 拍
    let hi: Double
    let pxPerBeat: Double       // 範囲の中の 1 拍の画面の高さ (scroll 0 なら 0 = 全部が同じ高さに重なっている)
}

extension LaneRenderer {
    /// 1 画面に描く上限 (scroll 0 で何千ものノーツが同じ高さに重なっても、固まらないように)
    private static let fxMaxBars = 600
    private static let fxMaxQuads = 8000

    static func drawFX(ctx: GraphicsContext, g: LaneGeo, state: EditorState) {
        guard let f = g.fx else { return }
        var c = ctx
        // 左の番号欄の地 (通常の表示と同じ)
        c.fill(Path(CGRect(x: 0, y: 0, width: g.trackL, height: g.H)), with: .color(Color.timePanel))
        drawVLines(&c, g, lines: state.gridLines)

        let ranges = fxRanges(g, f, totalSec: state.totalSec)
        // 分割線 (scroll 0 などで 1 拍が 1pt に満たない範囲は、潰れて塗りつぶしになるだけなので引かない)
        for r in ranges where r.pxPerBeat >= 1 {
            drawHLines(&c, g, den: state.snapDen, from: r.lo, to: r.hi, pxPerBeat: r.pxPerBeat, within: true)
        }
        drawBPM(&c, g, state)
        drawEffects(&c, g, state)
        drawFXNotes(&c, g, f, state, ranges)
        drawPlayline(&c, g)
        for r in ranges where r.pxPerBeat >= 1 {
            drawLabels(&c, g, from: r.lo, to: r.hi, pxPerBeat: r.pxPerBeat, mid: r.lo...max(r.lo, r.hi))
        }
        drawFXHud(&c, g, f)
    }

    /// 画面 (上下に margin ずつ広げた範囲) に見える表示位置に入る、拍の範囲の一覧。
    /// effect が無ければ 1 つだけ (通常の表示と同じ範囲)。scroll / jump の区間ごとに分かれる
    static func fxRanges(_ g: LaneGeo, _ f: FXWarp, totalSec: Double, margin: CGFloat = 24) -> [FXRange] {
        let pps = g.fxPxPerSec(f)
        guard pps.isFinite, pps > 0 else { return [] }
        let pLo = f.pNow - Double(g.H - g.playY + margin) / pps
        let pHi = f.pNow + Double(g.playY + margin) / pps
        let tMin = -1.0
        let tMax = totalSec + 30            // scroll 0 の区間は、時刻の範囲が果てしなく長くなるので、曲の終わりの少し先で切る
        var out: [FXRange] = []
        for r in f.map.timeRanges(p: pLo, pHi) {
            let t0 = max(r.lo, tMin)
            let t1 = min(r.hi, tMax)
            if !(t1 >= t0) { continue }
            let b0 = f.time.beat(atSec: t0)
            let b1 = f.time.beat(atSec: t1)
            let db = b1 - b0
            let slope = abs(f.map.scroll(at: (t0 + t1) / 2))
            // 範囲の中の 1 拍の高さ = |scroll| × 1 拍の秒数 × 1 秒の高さ (BPM が変わる範囲でも、平均で見る)
            let px = db > 1e-9 ? slope * (t1 - t0) * pps / db : slope * g.ppb
            out.append(FXRange(lo: b0, hi: b1, pxPerBeat: px))
        }
        return out
    }

    // MARK: ノーツ

    private static func drawFXNotes(_ c: inout GraphicsContext, _ g: LaneGeo, _ f: FXWarp, _ state: EditorState,
                                    _ ranges: [FXRange]) {
        if ranges.isEmpty { return }
        let pps = g.fxPxPerSec(f)
        let now = f.nowSec
        let notes = state.chart.notes

        // 見える範囲に掛かるノーツ (複数の範囲にまたがるものは 1 回だけ)
        var cand: [Int] = []
        if ranges.count == 1 {
            cand = state.notesOverlapping(lo: ranges[0].lo, hi: ranges[0].hi)
        } else {
            var seen = Set<Int>()
            for r in ranges {
                for i in state.notesOverlapping(lo: r.lo, hi: r.hi) where seen.insert(i).inserted { cand.append(i) }
            }
            cand.sort()
        }
        if cand.isEmpty { return }

        func yOf(_ p: Double) -> CGFloat { g.playY - CGFloat((p - f.pNow) * pps) }

        // 1) スライドのリボン
        let topDist = Double(g.playY) / pps + 0.05          // 画面の上端までの表示位置 (秒)。始点がここより手前に来たら出す
        let negFrom = f.map.negFrom                         // 逆走 / マイナス jump が始まる時刻 (無ければ +infinity)
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        var ts: [Double] = []
        var quads = 0
        for i in cand where notes[i].isSlide {
            if quads >= fxMaxQuads { break }
            let n = notes[i]
            let sb = n.beat.value
            xs.removeAll(keepingCapacity: true)
            ys.removeAll(keepingCapacity: true)
            ts.removeAll(keepingCapacity: true)
            let headT = f.time.sec(atBeat: sb)
            let headP = f.map.p(headT)
            xs.append(g.px(Double(n.x)))
            ys.append(yOf(headP))
            ts.append(headT)
            var maxT = headT
            for s in n.segs {
                let t = f.time.sec(atBeat: sb + s.beat.value)
                xs.append(g.px(Double(n.x + s.x)))
                ys.append(yOf(f.map.p(t)))
                ts.append(t)
                if t > maxT { maxT = t }
            }
            if maxT <= now - 1e-4 { continue }                              // 全体が判定を過ぎた
            if headT > now + 1e-4 && headP - f.pNow > topDist { continue }  // 始点がまだ画面の上端に入っていない
            let gated = maxT > negFrom                                      // 区間の終わりの点を判定が過ぎたら、その区間は消す
            let hw = CGFloat(n.w) / 255.0 * g.trackW / 2.0
            for k in 1..<xs.count {
                if gated && max(ts[k - 1], ts[k]) <= now { continue }
                // jump で何百万拍も先 / 手前へ飛んだ点があっても、描くのは画面の縦の範囲だけ
                guard let q = clipQuad(ya: ys[k - 1], xa: xs[k - 1], yb: ys[k], xb: xs[k],
                                       yMin: -24, yMax: g.H + 24) else { continue }
                var path = Path()
                path.move(to: CGPoint(x: q.xa - hw, y: q.ya))
                path.addLine(to: CGPoint(x: q.xa + hw, y: q.ya))
                path.addLine(to: CGPoint(x: q.xb + hw, y: q.yb))
                path.addLine(to: CGPoint(x: q.xb - hw, y: q.yb))
                path.closeSubpath()
                c.fill(path, with: .color(Color.ribbonFill))
                quads += 1
            }
        }

        // 2) タップ / ウィップの棒 (判定を過ぎたものは出さない)
        var bars = 0
        for i in cand where !notes[i].isSlide {
            if bars >= fxMaxBars { break }
            let n = notes[i]
            let t = f.time.sec(atBeat: n.beat.value)
            if t < now - 1e-4 { continue }
            let y = yOf(f.map.p(t)) - barLift
            if y < -24 || y > g.H + 24 { continue }
            let hw = CGFloat(n.w) / 255.0 * g.trackW / 2.0
            let cx = g.px(Double(n.x))
            if n.isWipe {
                drawWipe(&c, xL: cx - hw, xR: cx + hw, yMid: y, selected: false)
            } else {
                drawTap(&c, rect: CGRect(x: cx - hw, y: y - tapH / 2, width: hw * 2, height: tapH), selected: false)
            }
            bars += 1
        }
        // (slide の点 = seg の丸は、FX 表示では描かない)
    }

    /// リボンの 1 区間 (a → b) を、縦の範囲 yMin...yMax に切り詰める (x は y に比例して動く)。範囲の外にしか無ければ nil
    private static func clipQuad(ya: CGFloat, xa: CGFloat, yb: CGFloat, xb: CGFloat,
                                 yMin: CGFloat, yMax: CGFloat) -> (ya: CGFloat, xa: CGFloat, yb: CGFloat, xb: CGFloat)? {
        guard ya.isFinite, yb.isFinite, xa.isFinite, xb.isFinite else { return nil }
        if (ya < yMin && yb < yMin) || (ya > yMax && yb > yMax) { return nil }
        let dy = yb - ya
        var ta: CGFloat = 0
        var tb: CGFloat = 1
        if dy != 0 {
            let t1 = (yMin - ya) / dy
            let t2 = (yMax - ya) / dy
            ta = max(0, min(t1, t2))
            tb = min(1, max(t1, t2))
            if tb < ta { return nil }
        }
        let dx = xb - xa
        return (ya: ya + dy * ta, xa: xa + dx * ta, yb: ya + dy * tb, xb: xa + dx * tb)
    }

    // MARK: 表示

    /// 左上の「SC 0.65」: いまの再生ラインの scroll (本家の画面にある表示)
    private static func drawFXHud(_ c: inout GraphicsContext, _ g: LaneGeo, _ f: FXWarp) {
        let label = "SC " + fxNumberText(f.map.scroll(at: f.nowSec))
        let plate = CGRect(x: g.trackL + 6, y: 6, width: CGFloat(label.count) * 7.6 + 14, height: 20)
        c.fill(Path(roundedRect: plate, cornerRadius: 4), with: .color(Color.black.opacity(0.5)))
        let text = Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(Color.white.opacity(0.92))
        c.draw(text, at: CGPoint(x: plate.minX + 7, y: plate.midY), anchor: .leading)
    }

    /// 整数なら小数点なし (1 / 0 / -2)、それ以外は小数 3 桁まで (0.65 / 1.5)
    private static func fxNumberText(_ v: Double) -> String {
        if !v.isFinite { return "-" }
        if v == v.rounded() && abs(v) < 1e9 { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
