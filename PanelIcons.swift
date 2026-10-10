import SwiftUI

// MARK: - 右ボタン列のアイコン (本家風)
//
// 本家 Malody (iPad Air 4) の右ボタン列のアイコンは、高さ約 36pt の太い白線 (線の太さ 約 4pt、角は丸い) の絵。
// EDIT / BPM / TEST / META は本家のスクリーンショットから輪郭を起こした (PanelIconData)。TEST は本家のカチンコ。
// 本家に無い SETTING は、同じ太さ・同じ大きさで描いている。EFFECT は、まだアイコンを作らず文字 (✦) のまま。
// 座標は「アイコンの中心 = 原点、単位 = 本家の pt (アイコンの高さ 36pt)」。表示の高さに合わせて拡大縮小する。

enum PanelIconKind {
    case edit, bpm, test, meta, setting
    // EDIT 中のアイコン (本家の動画から輪郭を起こした)。speed / divide は右下の2つ
    case back, note, wipe, slide, remove, more, speed, divide
}

struct PanelIconView: View {
    let kind: PanelIconKind
    let color: Color

    /// 本家のアイコンの高さ (これを表示の高さに合わせる)
    static let refHeight: CGFloat = 36

    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 1      // 座標は本家の pt のまま (枠は少し余裕を持たせてあるので、拡大縮小はしない)
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
            case .back:
                Self.fillPolys(ctx, PanelIconData.back, center: center, scale: s, color: color)
            case .note:
                Self.fillPolys(ctx, PanelIconData.note, center: center, scale: s, color: color)
            case .wipe:
                Self.fillPolys(ctx, PanelIconData.wipe, center: center, scale: s, color: color)
            case .slide:
                Self.fillPolys(ctx, PanelIconData.slide, center: center, scale: s, color: color)
            case .remove:
                Self.fillPolys(ctx, PanelIconData.trash, center: center, scale: s, color: color)
            case .more:
                Self.fillPolys(ctx, PanelIconData.more, center: center, scale: s, color: color)
            case .speed:
                Self.fillPolys(ctx, PanelIconData.speed, center: center, scale: s, color: color)
            case .divide:
                Self.fillPolys(ctx, PanelIconData.divide, center: center, scale: s, color: color)
            }
        }
        .frame(width: 50, height: Self.refHeight + 6)      // 本家と同じ大きさ (高さ 36pt、いちばん横長の鉛筆で幅 44pt)。縁が欠けないよう上下に 3pt ずつ余裕
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

    // ── ここから下は、本家の EDIT 中のアイコン (動画から輪郭を起こした。原点 = ボタンの中心、単位 = 本家の pt) ──
    // BACK (←)
    static let back0: [Double] = [-0.35, -17.8, -16.8, -1.59, -17.41, -0.43, -17.41, 0.56, -17.1, 1.33, -0.89, 17.54, -0.12, 17.93, 2.57, 15.39, 2.64, 14.39, -8.5, 3.33, -8.81, 2.56, -8.5, 2.33, 17.4, 2.41, 17.86, 1.56, 17.86, -1.59, 17.32, -2.28, -8.65, -2.28, -8.88, -2.51, -8.81, -3.05, 2.8, -14.57, 2.57, -15.34, 0.11, -17.72]
    static var back: [[Double]] { [back0] }

    // NOTE (角丸の細長い輪)
    static let note0: [Double] = [-21.87, -1.4, -21.87, 1.6, -21.25, 3.98, -20.25, 5.37, -18.87, 6.67, -16.26, 7.82, -15.57, 7.9, 16.09, 7.82, 18.78, 6.67, 20.09, 5.52, 21.16, 4.14, 21.85, 1.68, 21.85, -1.4, 21.01, -4.08, 18.55, -6.54, 16.47, -7.47, 15.09, -7.62, -16.26, -7.54, -18.87, -6.39, -20.41, -4.93, -21.33, -3.55]
    static let note1: [Double] = [-16.49, -0.63, -15.95, -1.63, -14.88, -2.09, 14.78, -2.09, 15.71, -1.86, 16.32, -1.32, 16.55, 0.53, 16.24, 1.68, 14.71, 2.37, -14.26, 2.37, -15.41, 2.22, -16.34, 1.6]
    static var note: [[Double]] { [note0, note1] }

    // WIPE (線とひし形)
    static let wipe0: [Double] = [-21.02, 0.26, -20.72, 1.26, -19.26, 3.25, -5.19, 3.33, -4.35, 3.71, 0.03, 7.09, 0.95, 6.86, 4.49, 3.94, 5.64, 3.33, 19.7, 3.25, 21.54, 0.56, 20.85, -0.9, 19.7, -2.28, 6.41, -2.51, 0.49, -7.04, -0.28, -6.89, -5.12, -2.97, -6.12, -2.43, -18.79, -2.36, -19.64, -1.97]
    static var wipe: [[Double]] { [wipe0] }

    // SLIDE (ギザギザの輪)
    static let slide0: [Double] = [20.09, -15.3, 19.62, -15.61, 4.87, -15.53, -10.11, -8.46, -10.42, -8, -10.27, -7, -7.35, 0.76, -7.04, 2.37, -11.73, 7.29, -20.02, 15.2, -20.18, 15.89, -19.41, 16.12, 11.4, 15.97, 20.24, 3.37, 20.47, 2.6, 10.63, -7.16, 10.17, -8, 12.02, -9.62, 18.55, -14.15, 19.7, -14.69]
    static let slide1: [Double] = [9.33, -12.31, 9.71, -11.92, 9.64, -11.69, 8.41, -10.85, 7.1, -9.16, 6.95, -7.93, 7.33, -6.39, 8.18, -5.16, 16.24, 2.91, 16.01, 3.91, 10.4, 11.97, 9.4, 12.74, -11.96, 12.67, -12.03, 11.97, -4.5, 4.6, -3.89, 3.37, -3.81, 1.45, -6.5, -5.85, -6.42, -6.54, -3.96, -7.93, -0.2, -9.69, 0.8, -9.92, 5.41, -12.23]
    static var slide: [[Double]] { [slide0, slide1] }

    // REMOVE (ゴミ箱)
    static let trash0: [Double] = [-12.57, -9.96, -12.8, -9.35, -12.8, 14.16, -12.65, 15.24, -12.03, 16.55, -10.57, 17.93, -9.73, 18.16, 8.87, 18.16, 9.71, 17.85, 11.1, 16.47, 11.86, 13.86, 11.86, -9.35, 11.63, -9.89, 10.71, -10.27, -11.8, -10.27]
    static let trash1: [Double] = [-15.26, -15.88, -15.18, -12.73, -13.95, -12.11, 13.02, -12.11, 13.63, -12.27, 14.17, -13.04, 14.17, -15.8, 13.94, -16.19, 13.4, -16.42, 7.02, -16.49, 4.79, -18.11, -5.19, -18.18, -6.35, -17.8, -7.88, -16.49, -14.26, -16.42, -15.11, -16.19]
    static var trash: [[Double]] { [trash0, trash1] }

    // MORE (点3つ)
    static let more0: [Double] = [15.86, -5.08, 14.01, -4.16, 12.48, -2.4, 11.94, -0.86, 11.94, 1.06, 12.71, 2.91, 13.94, 4.29, 16.47, 5.44, 18.55, 5.37, 19.7, 4.98, 20.85, 4.21, 22.01, 2.83, 22.62, 1.22, 22.62, -1.17, 22.31, -2.16, 21.54, -3.32, 19.7, -4.78, 18.09, -5.16]
    static let more1: [Double] = [-1.51, -5.08, -3.27, -4.24, -4.66, -2.78, -5.42, -1.01, -5.42, 1.22, -4.12, 3.68, -2.89, 4.67, -0.89, 5.44, 1.11, 5.37, 3.33, 4.29, 4.95, 2.29, 5.26, 0.99, 5.1, -1.63, 3.95, -3.55, 1.95, -4.93]
    static let more2: [Double] = [-18.49, -5.24, -20.64, -4.39, -22.1, -2.93, -22.71, -1.47, -22.71, 1.6, -21.87, 3.37, -20.1, 4.83, -18.33, 5.44, -16.57, 5.44, -14.8, 4.83, -12.8, 2.98, -12.03, 1.06, -12.11, -1.32, -12.8, -2.86, -14.65, -4.62, -16.49, -5.24]
    static var more: [[Double]] { [more0, more1, more2] }

    // 再生速度 (メーター)
    static let speed0: [Double] = [-5.73, -2.75, -5.5, -1.22, -1.66, 8.54, -0.97, 9.31, 0.03, 9.85, 1.18, 9.85, 2.64, 8.93, 3.18, 8, 3.1, 6.31, -0.51, 2.16, -4.89, -2.29]
    static let speed1: [Double] = [-14.41, -12.97, -17.56, -9.44, -19.95, -5.29, -21.25, -0.91, -21.48, 1.55, -21.25, 6.62, -20.18, 10.46, -18.72, 13.54, -17.1, 15.84, -15.72, 17.3, -14.88, 17.84, 14.48, 17.84, 15.24, 17.45, 16.32, 16.38, 18.39, 13.54, 20.32, 9.16, 21.16, 4.85, 21.16, 0.78, 20.32, -3.45, 19.24, -6.13, 16.63, -10.36, 13.55, -13.51, 10.1, -15.82, 7.33, -17.05, 4.26, -17.89, -1.04, -18.27, -5.35, -17.74, -8.96, -16.51, -11.42, -15.2]
    static let speed2: [Double] = [-13.8, -6.21, -11.26, -9.13, -8.96, -10.9, -6.65, -12.13, -2.97, -13.28, 2.64, -13.28, 6.56, -12.05, 8.56, -10.98, 10.94, -9.13, 13.4, -6.37, 14.78, -3.98, 16.01, -0.22, 16.01, 5.85, 14.78, 9.62, 13.55, 11.77, 12.4, 12.92, -12.8, 12.92, -13.95, 11.61, -15.57, 8.46, -16.49, 4.24, -16.49, 1.4, -15.57, -2.83]
    static var speed: [[Double]] { [speed0, speed1, speed2] }

    // 分割 LFB (定規)
    static let divide0: [Double] = [-9.8, -18.24, -10.11, -17.78, -10.03, 17.57, -9.42, 17.95, 10.02, 17.88, 10.4, 17.42, 10.33, -18.01, 9.79, -18.39]
    static let divide1: [Double] = [-6.12, -14.86, 6.49, -14.86, 7.02, -14.39, 7.1, 13.88, 6.64, 14.34, -5.89, 14.42, -6.65, 13.96, -6.58, 10.65, -6.04, 10.27, -3.04, 10.27, -2.58, 9.58, -2.58, 8.43, -2.97, 7.81, -6.12, 7.73, -6.58, 7.43, -6.58, 4.28, -5.96, 3.89, 1.95, 3.97, 2.49, 3.82, 2.8, 3.12, 2.72, 1.74, 2.34, 1.43, -6.04, 1.43, -6.65, 0.9, -6.5, -2.25, -5.96, -2.56, -3.27, -2.49, -2.74, -2.79, -2.58, -4.41, -2.89, -4.94, -5.96, -5.02, -6.65, -5.56, -6.5, -8.63, -6.12, -8.86, -3.12, -8.86, -2.58, -9.63, -2.58, -10.78, -2.97, -11.4, -5.89, -11.4, -6.58, -11.71, -6.65, -14.39]
    static var divide: [[Double]] { [divide0, divide1] }
}

// MARK: - 本家に寄せた右ボタン列まわりの部品

extension Color {
    /// 選択中のアイコン・メニューの文字の色 (本家の動画から実測: R0 G206 B255)
    static let panelBlue = Color(red: 0.0, green: 206.0 / 255.0, blue: 1.0)
}

/// 右ボタン列まわりの文字。本家の字体 (角ばった細めの字) そのものは iPad に入っていないので、
/// 幅と高さの比が近い、iPad 標準の字体で代用している。字体を変えたいときは、ここの名前だけ変えればよい
/// (本家の字体ファイルを Playgrounds に入れた場合も、ここに名前を書けば全部に効く)。
enum PanelFont {
    /// 再生速度 / 分割のメニューの数字 (本家: 1/32 や 0.75x)
    static func menu(_ size: CGFloat) -> Font { Font.custom("DINCondensed-Bold", size: size) }
    /// EDIT 中のアイコンの左に出る名前 (本家: Back / Note / Wipe ...)
    static func label(_ size: CGFloat) -> Font { Font.custom("AvenirNextCondensed-Medium", size: size) }
}

/// 左右が尖った (上下が平らな) 正六角形。本家の再生ボタンの形
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.25, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - w * 0.25, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX - w * 0.25, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.25, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 右向きの三角形 (再生マーク)。角は、描く側 (PlayGlyph) で丸める
struct PlayTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

/// 六角形の中の再生 / 一時停止マーク。外形は 本家と同じ 約 32 × 28pt (角が丸い)
struct PlayGlyph: View {
    let isPlaying: Bool
    private static let tint = Color(white: 0.955)

    var body: some View {
        ZStack {
            if isPlaying {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2.5).fill(Self.tint).frame(width: 9.5, height: 28)
                    RoundedRectangle(cornerRadius: 2.5).fill(Self.tint).frame(width: 9.5, height: 28)
                }
            } else {
                // 縁取りの太さ 6pt の丸い角で、角を丸める (輪郭は 26 × 22 + 縁の 3pt ずつ = 32 × 28)
                PlayTriangleShape()
                    .fill(Self.tint)
                    .overlay(PlayTriangleShape().stroke(Self.tint, style: StrokeStyle(lineWidth: 6, lineJoin: .round)))
                    .frame(width: 26, height: 22)
                    .offset(x: 1.7)
            }
        }
    }
}

/// EDIT / Back を押したときの、アイコン列の入れ替わりの動き用。
/// 本家は、古いアイコンが右へ滑って消え、そのあと新しいアイコンが右から滑り込む (全体で 0.15 秒くらい)
struct PanelSlideFade: ViewModifier {
    let offset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var panelSwap: AnyTransition {
        let hidden = PanelSlideFade(offset: 46, opacity: 0)
        let shown = PanelSlideFade(offset: 0, opacity: 1)
        let insertion = AnyTransition.modifier(active: hidden, identity: shown)
            .animation(Animation.easeOut(duration: 0.12).delay(0.07))
        let removal = AnyTransition.modifier(active: hidden, identity: shown)
            .animation(Animation.easeIn(duration: 0.08))
        return AnyTransition.asymmetric(insertion: insertion, removal: removal)
    }
}

/// EDIT 中、アイコンの左に出る名前。本家は、黒い半透明の箱 (黒 80%、高さ 43pt) の上に白い字
struct PanelEditLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PanelFont.label(25))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(height: 43)
            .background(Color.black.opacity(0.8))
    }
}
