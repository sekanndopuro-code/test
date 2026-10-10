import SwiftUI

// MARK: - More メニュー (EDIT の「•••」) のアイコン (本家風)
//
// 本家 Malody (iPad Air 4) の「Select copy range / Paste / Flip notes horizontal / Grid settings /
// Slide modify / Slide to Wipe / Wipe to Slide」のアイコンは、本家の画面収録 (2360 x 1640) から輪郭を起こした。
// 座標は「アイコンの原点 = 0, 0、単位 = 本家の pt」。原点は、メニューの左端から 21.5pt・その行の縦の真ん中
// (アイコンごとにずれがあるのは本家の絵のまま。コピーと貼り付けが少し右に寄っているのも本家のとおり)。
// 本家に無い「Time range」(= 自作の範囲選択) は、正方形の中に上矢印を、同じ太さの線で描いている。
// 同じく本家に無い「Lasso」は、点線の輪と、そこから垂れる縄 (パスで描いている)。

enum MoreMenuIconKind {
    case copy, paste, timeRange, lasso, flip, grid, slideModify, slideToWipe, wipeToSlide
}

struct MoreMenuIcon: View {
    let kind: MoreMenuIconKind
    let color: Color

    /// アイコンの原点が、アイコン枠の左端から何 pt のところか (本家: メニューの左端から 21.5pt)
    static let originX: CGFloat = 21.5

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: Self.originX, y: size.height / 2)
            switch kind {
            case .copy:        Self.fillPolys(ctx, MoreMenuIconData.copy, center: center, color: color)
            case .paste:       Self.fillPolys(ctx, MoreMenuIconData.paste, center: center, color: color)
            case .timeRange:   Self.drawTimeRange(ctx, center: center, color: color)
            case .lasso:       Self.drawLasso(ctx, center: center, color: color)
            case .flip:        Self.fillPolys(ctx, MoreMenuIconData.flip, center: center, color: color)
            case .grid:        Self.fillPolys(ctx, MoreMenuIconData.grid, center: center, color: color)
            case .slideModify: Self.fillPolys(ctx, MoreMenuIconData.slideModify, center: center, color: color)
            case .slideToWipe: Self.fillPolys(ctx, MoreMenuIconData.slideToWipe, center: center, color: color)
            case .wipeToSlide: Self.fillPolys(ctx, MoreMenuIconData.wipeToSlide, center: center, color: color)
            }
        }
    }

    /// 輪郭 (x, y, x, y, ... の並び) を、偶奇規則で塗る。穴 (内側の輪郭) は抜ける
    private static func fillPolys(_ ctx: GraphicsContext, _ polys: [[Double]], center: CGPoint, color: Color) {
        var path = Path()
        for flat in polys {
            var pts: [CGPoint] = []
            var i = 0
            while i + 1 < flat.count {
                pts.append(CGPoint(x: center.x + CGFloat(flat[i]), y: center.y + CGFloat(flat[i + 1])))
                i += 2
            }
            if pts.count < 3 { continue }
            path.addLines(pts)
            path.closeSubpath()
        }
        ctx.fill(path, with: .color(color), style: FillStyle(eoFill: true))
    }

    /// Lasso: 点線の輪と、そこから垂れる縄。外形は Time range と同じ 約 29pt、線の太さも同じ 約 3.6pt
    private static func drawLasso(_ ctx: GraphicsContext, center c: CGPoint, color: Color) {
        let lw: CGFloat = 3.6
        let loop = Path(ellipseIn: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 17))
        ctx.stroke(loop, with: .color(color),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: [4.4, 3.4]))
        var rope = Path()
        rope.move(to: CGPoint(x: c.x - 6.5, y: c.y + 3.5))
        rope.addQuadCurve(to: CGPoint(x: c.x - 3, y: c.y + 13),
                          control: CGPoint(x: c.x - 11, y: c.y + 9))
        ctx.stroke(rope, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
    }

    /// Time range: 角の丸い正方形 (外形 29pt) の中に、上向きの矢印。線の太さは本家のアイコンと同じ 約 3.6pt
    private static func drawTimeRange(_ ctx: GraphicsContext, center c: CGPoint, color: Color) {
        let lw: CGFloat = 3.6
        let half: CGFloat = 14.5 - lw / 2
        let box = Path(roundedRect: CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2),
                       cornerRadius: 4)
        let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        ctx.stroke(box, with: .color(color), style: style)
        var arrow = Path()
        arrow.move(to: CGPoint(x: c.x, y: c.y + 7.5))
        arrow.addLine(to: CGPoint(x: c.x, y: c.y - 7.5))
        arrow.move(to: CGPoint(x: c.x - 6.5, y: c.y - 1))
        arrow.addLine(to: CGPoint(x: c.x, y: c.y - 7.5))
        arrow.addLine(to: CGPoint(x: c.x + 6.5, y: c.y - 1))
        ctx.stroke(arrow, with: .color(color), style: style)
    }
}

/// 本家の画面収録から起こした輪郭 (偶奇規則で塗る。1つ目が外形、残りは穴や中の図形)
enum MoreMenuIconData {
    static let copy0: [Double] = [-5.25, 7.5, 4, 7.5, 4, 9.75, -5.25, 9.75]
    static let copy1: [Double] = [-5.25, 2.75, 4, 2.75, 4, 5, -5.25, 5]
    static let copy2: [Double] = [-5.25, -1.75, 4, -1.75, 4, 0.5, -5.25, 0.5]
    static let copy3: [Double] = [17.25, -16.5, 15.75, -17, -1, -17, -2, -16.25, -2.75, -15, -3, -14.5, -3, -10.5, -3.5, -10, -8.25, -10, -9.5, -9.5, -10.5, -8.75, -11, -7, -11, 14, -10.5, 15.25, -10, 16, -8, 17, -7.25, 16.75, 8.5, 16.5, 9.75, 16, 10.5, 15, 10.5, 14.25, 10.5, 10.5, 11, 9.75, 16.25, 9.5, 18, 8.5, 18.5, 7.75, 18.5, 7, 18.5, -14.25, 18.25, -15.5]
    static let copy4: [Double] = [-7.5, -6.75, 6.75, -7, 7.5, -6.5, 7.5, 13, 7.25, 13.5, 6.5, 13.75, -7, 13.75, -7.5, 13.25, -7.75, -6.5]
    static let copy5: [Double] = [0.5, -13.75, 15, -14, 15.25, -13.75, 15.5, -13.25, 15.5, 6, 15.25, 6.5, 14.75, 6.5, 11.25, 6.5, 10.75, 6, 10.5, -7.5, 10, -8.75, 9.25, -9.5, 8, -10, 0.5, -10, 0, -10.5, 0, -13]
    static let copy: [[Double]] = [copy0, copy1, copy2, copy3, copy4, copy5]

    static let paste0: [Double] = [-5, 7.5, 4, 7.5, 4, 9.75, -5, 9.75]
    static let paste1: [Double] = [18.5, 3, 18.25, 2.75, 15.75, 3, 15.5, 3.25, 15.5, 5.75, 15.25, 6.25, 12.5, 6.25, 12, 6.5, 12, 6.75, 12, 9.25, 12.5, 9.25, 16.25, 9.25, 17.5, 8.75, 18.25, 8, 18.5, 7]
    static let paste2: [Double] = [-5, 2.5, 4, 2.5, 4, 4.75, -5, 4.75]
    static let paste3: [Double] = [-5, -2, 4, -2, 4, 0.25, -5, 0.25]
    static let paste4: [Double] = [13.25, -12.25, 9.5, -12.25, 9.25, -12, 9.5, -11.25, 10.5, -10.5, 9.75, -9.75, 7.75, -10, -8.25, -10.25, -10, -9, -11, -7.5, -11, 12.75, -10.75, 14.25, -9.75, 15.75, -8.25, 16.75, 8.25, 16.5, 9.25, 16, 10, 15.5, 10.5, 14.25, 10.5, -7.75, 11, -8.5, 11.5, -9, 12, -9, 12.25, -8.25, 12.5, -8, 13, -8, 13.5, -8.25, 13.75, -8.75, 13.75, -11.5]
    static let paste5: [Double] = [-7.5, -7, 6.75, -7, 7.5, -6.5, 7.5, 12.5, 7.25, 13.25, -7, 13.5, -7.5, 13, -7.75, -6.25]
    static let paste6: [Double] = [3.75, -17, 3.5, -17, -0.25, -17, -1.75, -16.5, -2.5, -15.75, -3, -14.75, -3, -11.5, -2, -11.25, -0.5, -11.25, 0, -11.75, 0, -13.25, 0.5, -14, 3, -14, 3.75, -14.25, 4, -14.5]
    static let paste7: [Double] = [11.5, -17, 11, -16.75, 11.25, -14.25, 12, -14, 15.25, -14, 15.5, -13.25, 15.75, -9.75, 18.25, -9.75, 18.5, -11.5, 18.5, -14.5, 18, -16.25, 17.25, -16.75, 16.25, -17]
    static let paste: [[Double]] = [paste0, paste1, paste2, paste3, paste4, paste5, paste6, paste7]

    static let flip0: [Double] = [0.5, 6, 3.25, 6, 3.25, 15.5, 0.5, 15.5]
    static let flip1: [Double] = [0.5, -15, 3.25, -15, 3.25, -5.5, 0.5, -5.5]
    static let flip2: [Double] = [18.25, -15.75, 3, -0.5, 3, 0.25, 18, 15.25, 18.5, 15, 18.5, 14.5, 18.5, -15.25]
    static let flip3: [Double] = [-16.75, -16.75, -17, -16, -17, 16, -16.5, 16.25, -0.5, 0, -0.25, -0.5, -7.25, -7.5, -8.25, -8.75, -9, -9.25, -16.5, -16.75]
    static let flip4: [Double] = [-12.5, -6.5, -12, -6.5, -6.25, -0.25, -6.5, 0, -8, 1.25, -8.5, 2.25, -12.25, 6, -12.75, 5.75, -13, 5.25, -13, -5.75]
    static let flip: [[Double]] = [flip0, flip1, flip2, flip3, flip4]

    static let grid0: [Double] = [9.75, 9.25, 15.5, 9.25, 15.5, 15, 9.75, 15]
    static let grid1: [Double] = [-2, 8.5, 5.25, 8.5, 5.25, 15.75, -2, 15.75]
    static let grid2: [Double] = [-16.5, 7.25, -7.5, 7.25, -7.5, 16.75, -16.5, 16.75]
    static let grid3: [Double] = [10, -3, 15.5, -3, 15.5, 2.5, 10, 2.5]
    static let grid4: [Double] = [-2, -3.75, 5.25, -3.75, 5.25, 3.5, -2, 3.5]
    static let grid5: [Double] = [-16.5, -5, -7.5, -5, -7.5, 4.5, -16.5, 4.5]
    static let grid6: [Double] = [9.5, -15.5, 15.75, -15.5, 15.75, -9.5, 9.5, -9.5]
    static let grid7: [Double] = [-2.5, -16.5, 5.5, -16.5, 5.5, -8.75, -2.5, -8.75]
    static let grid8: [Double] = [-16.75, -17.25, -7, -17.25, -7, -7.75, -16.75, -7.75]
    static let grid: [[Double]] = [grid0, grid1, grid2, grid3, grid4, grid5, grid6, grid7, grid8]

    static let slideModify0: [Double] = [11.25, 7.25, 10.75, 7.75, 10, 10, 10.75, 10.5, 12.75, 11.25, 13.25, 10.5, 14, 8.5, 12, 7.25]
    static let slideModify1: [Double] = [13.25, 1.75, 12.25, 4, 12, 4.75, 12.5, 5.25, 15, 6, 15.25, 5.5, 16.25, 3, 15, 2.25]
    static let slideModify2: [Double] = [-5.25, -1, -7, 0.75, -7, 1.5, -5.25, 3, -4.5, 3.25, -3, 1.5, -2.5, 0.5, -4.5, -1]
    static let slideModify3: [Double] = [16.5, -3.5, 14.5, -2.25, 14, -1.5, 14.25, -0.5, 14.5, -0.25, 16.5, 0.5, 17, 0.5, 17.5, 0.5, 17.75, -0.25, 18, -1.75, 17.5, -3, 16.75, -3.5]
    static let slideModify4: [Double] = [-3, -5.25, 0.5, -5.25, 0.5, -1.75, -3, -1.75]
    static let slideModify5: [Double] = [13.75, -7.75, 12, -6.75, 11.25, -6, 11.5, -5.25, 13, -3.5, 13.5, -3.5, 15.5, -5, 15.5, -5.5, 14.5, -7.25]
    static let slideModify6: [Double] = [11, -11.75, 10.5, -11.75, 8.5, -10, 8.5, -9.5, 9.75, -8, 10.25, -7.5, 12, -8.5, 12.75, -9.25, 12.5, -10]
    static let slideModify7: [Double] = [8, -16.5, 7.5, -16.75, 0, -16.75, -3.5, -16.5, -3.5, -13.75, -2, -13, -1.5, -11.75, -2, -11, -2.75, -11, -3.25, -10.5, -3, -8, -2.5, -7.5, 0, -7.75, 0.5, -7.25, 2.75, -2.5, 3, -1.75, 2.5, -1.25, -5.75, 5, -6.5, 5, -8.5, 3.25, -9, 3.5, -10.75, 5.75, -10.5, 6, -9.25, 7.25, -9.25, 7.5, -10.5, 8.75, -11.25, 8.5, -12, 8, -12.5, 8, -14.25, 10, -14, 11.5, -16, 13, -17, 13.75, -17, 15, -16.25, 16, -15.5, 16.25, -9, 16.25, -8.25, 16.5, -7.25, 16.25, 9.25, 16.25, 10.75, 16.5, 11, 16.25, 12, 14, 12, 13.5, 9.25, 12.5, 8, 12.75, -9, 12.75, -9.25, 12.5, -6.75, 10.25, 4.5, 1.5, 6.75, -0.25, 7, -1, 6.75, -2, 2, -12.5, 1.75, -13, 2.25, -13.5, 5.5, -13.5, 6.25, -13, 7, -11.75, 8, -11.75, 9.5, -13, 10, -13.25, 9.75, -13.75]
    static let slideModify: [[Double]] = [slideModify0, slideModify1, slideModify2, slideModify3, slideModify4, slideModify5, slideModify6, slideModify7]

    static let slideToWipe0: [Double] = [3.75, 13.75, 15.5, 13.75, 15.5, 16.25, 3.75, 16.25]
    static let slideToWipe1: [Double] = [3.75, 7.25, 15.5, 7.25, 15.5, 10, 3.75, 10]
    static let slideToWipe2: [Double] = [3.5, 0.75, 15.75, 0.75, 15.75, 3.5, 3.5, 3.5]
    static let slideToWipe3: [Double] = [3.75, -5.5, 15.5, -5.5, 15.5, -3, 3.75, -3]
    static let slideToWipe4: [Double] = [-17, -7, -5, -7, -5, 17, -17, 17]
    static let slideToWipe5: [Double] = [12.25, -12.75, 11.75, -13.5, 6.25, -17, 5.5, -16.75, 4.5, -16, 4.75, -15.5, 6.75, -14.25, 6.5, -13.75, -4.75, -13.75, -8.5, -14, -9.5, -13.75, -9.5, -13.25, -9.5, -12.25, -9.25, -12, -8.5, -11.75, 6.5, -12, 6.75, -11.75, 6.5, -11.25, 4.25, -9.75, 4.5, -9.25, 5.5, -8.5, 6.5, -8.75, 11.75, -12, 12.25, -12.5]
    static let slideToWipe: [[Double]] = [slideToWipe0, slideToWipe1, slideToWipe2, slideToWipe3, slideToWipe4, slideToWipe5]

    static let wipeToSlide0: [Double] = [-16.75, 12.75, -5.5, 12.75, -5.5, 15.5, -16.75, 15.5]
    static let wipeToSlide1: [Double] = [-16.75, 6.5, -5.5, 6.5, -5.5, 9.25, -16.75, 9.25]
    static let wipeToSlide2: [Double] = [-16.75, 0.5, -5.5, 0.5, -5.5, 3, -16.75, 3]
    static let wipeToSlide3: [Double] = [3.25, -5.75, 14.5, -5.75, 14.5, 17, 3.25, 17]
    static let wipeToSlide4: [Double] = [-16.75, -5.75, -5.5, -5.75, -5.5, -3, -16.75, -3]
    static let wipeToSlide5: [Double] = [11.25, -12.75, 10.5, -13.5, 6, -16.5, 5, -16.75, 4.25, -16, 4, -15.5, 6, -14, 6, -13.75, 5.75, -13.5, -8.25, -13.75, -9.5, -13.5, -9.75, -12.5, -9.5, -12, -8.25, -11.75, 5.5, -11.75, 6, -11.5, 5.75, -11.25, 3.75, -9.75, 3.75, -9.5, 4.25, -9, 5.5, -8.5, 10.75, -11.75, 11.25, -12.25]
    static let wipeToSlide: [[Double]] = [wipeToSlide0, wipeToSlide1, wipeToSlide2, wipeToSlide3, wipeToSlide4, wipeToSlide5]
}
