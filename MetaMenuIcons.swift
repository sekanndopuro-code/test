import SwiftUI

// META の列のアイコン。Back と More (•••) は EDIT 中と同じ (PanelIconView の .back / .more)。
// 本家にある Information (レコードの絵) と Quit (電源の絵) は、他のアイコンと同じ太さ (線 4pt、角は丸い) で描いている。
// どちらも、他のアイコンと同じく、パスで描いている (SF Symbols に頼らない)。

/// Information: 角丸の四角の中に、レコード盤 (輪 + 真ん中の点)
struct InfoIcon: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let box = Path(roundedRect: CGRect(x: cx - 16, y: cy - 15, width: 32, height: 30), cornerRadius: 7)
            ctx.stroke(box, with: .color(color), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            let ring = Path(ellipseIn: CGRect(x: cx - 7.5, y: cy - 7.5, width: 15, height: 15))
            ctx.stroke(ring, with: .color(color), style: StrokeStyle(lineWidth: 3.4))
            let dot = Path(ellipseIn: CGRect(x: cx - 2.6, y: cy - 2.6, width: 5.2, height: 5.2))
            ctx.fill(dot, with: .color(color))
        }
        .frame(width: 42, height: 36)
    }
}

/// Quit: 電源の絵 (上が欠けた輪 + 縦の棒)
struct PowerIcon: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2 + 2           // 輪は少し下げて、上の棒が入るすき間を空ける
            let r: CGFloat = 12.5
            // 上 (-90°) を中心に左右 40° ずつ欠けた輪。-50° から時計回りに 230° まで、点をつないで描く
            var arc = Path()
            var deg = -50.0
            var first = true
            while deg <= 230.0 {
                let rad = deg * Double.pi / 180
                let pt = CGPoint(x: cx + r * CGFloat(cos(rad)), y: cy + r * CGFloat(sin(rad)))
                if first { arc.move(to: pt); first = false } else { arc.addLine(to: pt) }
                deg += 5
            }
            ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            var bar = Path()
            bar.move(to: CGPoint(x: cx, y: cy - r - 4))
            bar.addLine(to: CGPoint(x: cx, y: cy - 1))
            ctx.stroke(bar, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .frame(width: 42, height: 36)
    }
}
