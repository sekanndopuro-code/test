import SwiftUI

// MARK: - 右ボタン列のアイコン (本家風)
//
// 本家 Malody (iPad Air 4) の右ボタン列のアイコンは、高さ約 36pt の太い白線 (線の太さ 約 4pt、角は丸い) の絵。
// EDIT / BPM / TEST / META は本家のスクリーンショットから輪郭を起こした (PanelIconData)。TEST は本家のカチンコ。
// 本家に無い SETTING は、同じ太さ・同じ大きさで描いている。EFFECT は、まだアイコンを作らず文字 (✦) のまま。
// 座標は「アイコンの中心 = 原点、単位 = 本家の pt (アイコンの高さ 36pt)」。表示の高さに合わせて拡大縮小する。

enum PanelIconKind {
    case edit, bpm, test, meta, setting
}

struct PanelIconView: View {
    let kind: PanelIconKind
    let color: Color

    /// 本家のアイコンの高さ (これを表示の高さに合わせる)
    static let refHeight: CGFloat = 36

    var body: some View {
        Canvas { ctx, size in
            let s = size.height / Self.refHeight
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            switch kind {
            case .edit:
                Self.fillPolys(ctx, PanelIconData.pencil, center: center, scale: s, color: color)
            case .bpm:
                Self.fillPolys(ctx, PanelIconData.metronome, center: center, scale: s, color: color)
            case .test:
                Self.fillPolys(ctx, PanelIconData.clapper, center: center, scale: s, color: color)
            case .meta:
                Self.fillPolys(ctx, PanelIconData.list, center: center, scale: s, color: color)
            case .setting:
                Self.drawGear(ctx, center: center, scale: s, color: color)
            }
        }
        .frame(width: 34, height: 25)
    }

    /// 輪郭 (x, y, x, y, ... の並び) を、偶奇規則で塗る。穴 (内側の輪郭) は抜ける
    private static func fillPolys(_ ctx: GraphicsContext, _ polys: [[Double]], center: CGPoint, scale s: CGFloat, color: Color) {
        var path = Path()
        for flat in polys {
            var pts: [CGPoint] = []
            var i = 0
            while i + 1 < flat.count {
                pts.append(CGPoint(x: center.x + CGFloat(flat[i]) * s, y: center.y + CGFloat(flat[i + 1]) * s))
                i += 2
            }
            if pts.count < 3 { continue }
            path.addLines(pts)
            path.closeSubpath()
        }
        ctx.fill(path, with: .color(color), style: FillStyle(eoFill: true))
    }

    /// SETTING: 歯車 (歯が 8 つ、真ん中に穴)。線の太さ 3.8pt、外形 約 35pt
    private static func drawGear(_ ctx: GraphicsContext, center: CGPoint, scale s: CGFloat, color: Color) {
        let teeth = 8
        let tip = 15.6          // 歯の先 (線の中心の半径)
        let root = 12.0         // 歯の根もと
        let tipHalf = 9.0       // 歯の先の半分の角度 (度)
        let rootHalf = 13.5     // 歯の根もとの半分の角度 (度)
        let step = 360.0 / Double(teeth)
        func pt(_ r: Double, _ deg: Double) -> CGPoint {
            let a = deg * Double.pi / 180.0
            return CGPoint(x: center.x + CGFloat(r * cos(a)) * s, y: center.y + CGFloat(r * sin(a)) * s)
        }
        var gear = Path()
        for i in 0..<teeth {
            let c0 = -90.0 + Double(i) * step
            let a = pt(root, c0 - rootHalf)
            if i == 0 { gear.move(to: a) } else { gear.addLine(to: a) }
            gear.addLine(to: pt(tip, c0 - tipHalf))
            gear.addLine(to: pt(tip, c0 + tipHalf))
            gear.addLine(to: pt(root, c0 + rootHalf))
            // 根もとの円弧 (次の歯まで)
            let gap = step - rootHalf * 2
            for k in 1...2 {
                gear.addLine(to: pt(root, c0 + rootHalf + gap * Double(k) / 3.0))
            }
        }
        gear.closeSubpath()
        let style = StrokeStyle(lineWidth: 3.8 * s, lineCap: .round, lineJoin: .round)
        ctx.stroke(gear, with: .color(color), style: style)
        let hole = Path(ellipseIn: CGRect(x: center.x - 5.2 * s, y: center.y - 5.2 * s, width: 10.4 * s, height: 10.4 * s))
        ctx.stroke(hole, with: .color(color), style: style)
    }
}

/// 本家のスクリーンショットから起こした輪郭 (偶奇規則で塗る。1つ目が外形、残りは穴や中の図形)
enum PanelIconData {
    // EDIT (えんぴつ): 外形 44.1 × 35.9pt
    static let pencil0: [Double] = [17.37, -0.92, 17, -0.91, 16.62, -1.16, 6.18, -14.25, 6.09, -14.69, 6.23, -14.94, 8.12, -16.45, 9.81, -17.39, 11.62, -17.89, 13.19, -17.95, 15.06, -17.53, 16.11, -17, 17.37, -15.85, 21.42, -10.69, 21.89, -9.56, 22.03, -8.44, 21.9, -6.56, 21.44, -5.21, 20.87, -4.24, 19.94, -3.06, 17.87, -1.22]
    static let pencil1: [Double] = [-20.94, 17.94, -21.63, 17.95, -21.94, 17.82, -22.03, 17.56, -21.93, 17.06, -17.36, 3.5, -16.94, 2.89, 3.68, -12.94, 4.31, -13.23, 4.83, -13.06, 15, -0.01, 15.16, 0.44, 15.04, 0.88, -5.94, 16.41, -8.69, 16.85, -11.75, 17.02, -13.75, 17.33, -16.75, 17.5, -18.81, 17.81]
    static let pencil2: [Double] = [-14.01, 12.5, -11.31, 12.32, -7.88, 11.84, 8.3, -0.12, 8.39, -0.44, 8.21, -0.87, 3.98, -6.31, 3.75, -6.45, 3.25, -6.45, 2.56, -5.99, -12.77, 5.69, -13.35, 6.63, -15.13, 12.13, -14.88, 12.49]
    static var pencil: [[Double]] { [pencil0, pencil1, pencil2] }

    // BPM (メトロノーム): 外形 26.8 × 36.0pt
    static let metronome0: [Double] = [12.72, 17.99, -12.66, 18, -13.16, 17.97, -13.41, 17.76, -13.4, 16.73, -13.07, 15.61, -12.4, 11.79, -11.06, 5.61, -6.89, -16.39, -6.56, -17.58, -6.28, -17.95, 4.22, -18, 4.84, -17.87, 5.17, -17.52, 13.41, 17.36, 13.28, 17.8]
    static let metronome1: [Double] = [7.92, 14.29, 8.35, 14.04, 8.4, 13.42, 2.35, -13.58, 2.06, -14.02, 1.59, -14.21, -2.59, -14.23, -3.16, -14.13, -3.5, -13.77, -3.8, -12.46, -8.39, 11.79, -8.63, 13.48, -8.59, 14.04, -8.09, 14.33, -4.28, 14.23, -3.94, 13.86, -3.37, 12.48, -2.59, 11.44, -0.91, -5.04, -0.49, -7.89, -0.28, -8.33, -0.12, -7.96, 0.33, -4.52, 2.18, 11.36, 2.91, 12.42, 3.54, 13.92, 3.78, 14.19, 4.34, 14.34]
    static var metronome: [[Double]] { [metronome0, metronome1] }

    // TEST (カチンコ): 外形 38.9 × 36.0pt
    static let clapper0: [Double] = [15.34, 17.99, -13.97, 18.01, -15.1, 17.8, -16.6, 16.92, -17.66, 15.59, -18.22, 14.11, -18.27, 1.36, -18.06, 0.3, -19.12, -3.2, -19.43, -4.83, -19.4, -6.01, -19.15, -7.26, -18.16, -8.95, -16.6, -10.29, -15.22, -10.87, 10.09, -17.8, 11.65, -18.01, 12.9, -17.89, 14.3, -17.39, 15.15, -16.86, 16.09, -15.95, 16.58, -15.26, 17.11, -14.01, 18.34, -9.45, 18.28, -8.84, 18.03, -8.54, 16.47, -8.05, 9.4, -6.36, 3.03, -4.59, -14.22, -0.37, -16.18, 0.3, -15.78, 0.5, -14.91, 0.57, 19.09, 0.61, 19.33, 0.92, 19.43, 1.49, 19.43, 13.24, 19.24, 14.61, 18.65, 15.86, 17.69, 16.92, 16.22, 17.82]
    static let clapper1: [Double] = [8.75, -9.39, 9.46, -9.64, 10.03, -10.21, 10.27, -10.89, 10.27, -11.83, 10.08, -12.39, 9.53, -12.99, 8.9, -13.34, 7.97, -13.38, 7.34, -13.09, 6.75, -12.51, 6.41, -11.7, 6.41, -11.01, 6.77, -10.14, 7.28, -9.62, 7.97, -9.38]
    static let clapper2: [Double] = [0.15, -6.95, 0.59, -7.11, 1.08, -7.51, 1.53, -8.14, 1.62, -8.83, 1.53, -9.58, 1.09, -10.31, 0.3, -10.83, -0.22, -10.95, -0.85, -10.89, -1.66, -10.44, -2.15, -9.83, -2.31, -9.14, -2.26, -8.26, -1.96, -7.7, -1.26, -7.08, -0.6, -6.91]
    static let clapper3: [Double] = [-9.34, -4.45, -8.6, -4.68, -7.85, -5.58, -7.73, -6.14, -7.78, -7.14, -8.27, -7.89, -8.8, -8.26, -9.41, -8.45, -10.16, -8.42, -11.16, -7.83, -11.59, -6.83, -11.64, -6.2, -11.24, -5.2, -10.66, -4.62]
    static let clapper4: [Double] = [14.1, 14.05, 14.8, 13.8, 15.16, 13.42, 15.26, 13.05, 15.26, 5.49, 15.15, 5.01, 14.82, 4.74, -13.47, 4.66, -13.91, 4.72, -14.15, 5.05, -14.21, 12.92, -14.03, 13.42, -13.28, 14]
    static var clapper: [[Double]] { [clapper0, clapper1, clapper2, clapper3, clapper4] }

    // META (一覧): 外形 37.3 × 36.0pt
    static let list0: [Double] = [14.62, 17.97, -14.19, 17.99, -15, 17.88, -15.94, 17.55, -17.38, 16.53, -18.29, 15.15, -18.63, 13.53, -18.64, -13.6, -18.32, -15.32, -17.8, -16.29, -17.25, -16.9, -15.82, -17.84, -14.57, -17.99, 14.43, -17.99, 16.06, -17.82, 17.5, -16.83, 18.43, -15.38, 18.64, -14.16, 18.63, 14.09, 18.4, 15.15, 18, 15.95, 17.5, 16.57, 16.25, 17.5]
    static let list1: [Double] = [13.9, 13.65, 14.35, 13.28, 14.47, 12.65, 14.48, -13.04, 14.11, -13.72, 13.68, -13.89, -13.32, -13.89, -14.13, -13.65, -14.35, -12.97, -14.34, 12.53, -14.13, 13.46, -13.38, 13.69]
    static let list2: [Double] = [-5.13, -3.78, -6.57, -3.81, -6.89, -4.1, -6.92, -7.22, -6.82, -7.71, -6.63, -7.88, 6.18, -7.92, 6.81, -7.79, 7.02, -7.47, 7.1, -4.29, 6.99, -4.04, 6.68, -3.86]
    static let list3: [Double] = [6.56, 2.6, -6.63, 2.61, -6.93, 2.21, -6.87, -1.22, -6.69, -1.44, -6.44, -1.49, 6.68, -1.44, 6.97, -1.29, 7.07, -1.04, 7.09, 2.15, 6.95, 2.46]
    static let list4: [Double] = [6.62, 9.03, -6.63, 9.05, -6.83, 8.9, -6.91, 8.59, -6.91, 5.28, -6.75, 5.02, -6.38, 4.94, 6.75, 5.01, 6.99, 5.15, 7.1, 5.4, 7.07, 8.09, 7, 8.83]
    static var list: [[Double]] { [list0, list1, list2, list3, list4] }
}
