import SwiftUI
import UIKit

// MARK: - Grid settings (本家風の中央ダイアログ)
//
// シート (下からせり上がる) ではなく、EditorView の上に重ねる「ただのビュー」。
// アニメーションなしで、押した瞬間に出る (EditorView の overlay で、条件が真になった 1 フレーム目から表示)。
// 寸法は、本家 (iPad Air 4) の画面収録 (2360 x 1640) から実測した値 (pt = 画面収録の px / 2)。
//   ・枠: 801.25 × 356.25pt。画面の真ん中。右上が 12.5pt 斜めに欠け、左は上側が 7.5pt 外に出て段差がある
//   ・枠の中身: 黒 50% の半透明。縁は白 30% の細い線。枠の外 (画面全体) は強くぼかす
//   ・Grid lines: 右そろえの名前 + 横長のバー (右上と左下が斜めに欠ける)。バーは左から灰色に塗られ、数字は真ん中
//   ・Grid align: 名前 + チェックボックス
//   ・戻る / 完了: 白い縁取りの長方形

/// 背景をぼかす。UIVisualEffectView は OS の合成機能なので速く、出した最初の 1 フレームから効く
/// (SwiftUI の .blur を画面全体にかけるより軽い)
struct BackdropBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

/// 本家の枠。右上が斜めに欠け、左側の上 (92pt まで) が 7.5pt だけ外に出ている
private struct GridDialogFrameShape: Shape {
    func path(in r: CGRect) -> Path {
        let cham: CGFloat = 12.5
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - cham, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cham))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 7.5, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 7.5, y: r.minY + 99.75))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 92.25))
        p.closeSubpath()
        return p
    }
}

/// Grid lines のバー。右上が 13.5pt、左下が 8pt 斜めに欠ける
private struct GridBarShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 13.5, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 13.5))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 8, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 8, y: r.minY + 26.5))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 18))
        p.closeSubpath()
        return p
    }
}

/// 押している間だけ少し薄くする (本家の戻る / 完了も、押した手応えがある)
private struct GridDialogButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

struct GridSettingsDialog: View {
    @ObservedObject var state: EditorState

    /// 編集中の値。「完了」で state に書き込み、「戻る」なら捨てる (今までのシートと同じ)
    @State private var lines: Int
    @State private var align: Bool

    private static let minLines = 1
    private static let maxLines = 64

    // ── 本家の寸法 (pt) ──
    private static let designW: CGFloat = 801.25
    private static let designH: CGFloat = 356.25
    private static let labelW: CGFloat = 166.5        // 名前 (右そろえ) の枠の幅。右端は枠の左端から 166.5pt
    private static let labelGap: CGFloat = 20.5       // 名前の右端 → バー / チェックボックスの左端
    private static let barW: CGFloat = 584
    private static let barH: CGFloat = 35
    private static let boxSize: CGFloat = 36.5
    private static let buttonW: CGFloat = 192.75
    private static let buttonH: CGFloat = 50.75

    init(state: EditorState) {
        self.state = state
        _lines = State(initialValue: state.gridLines)
        _align = State(initialValue: state.gridAlign)
    }

    var body: some View {
        ZStack {
            BackdropBlur()
            Color.black.opacity(0.001)                  // 後ろのレーンにタッチを通さない
                .contentShape(Rectangle())
                .onTapGesture {}
            GeometryReader { proxy in
                // 小さい画面では、枠ごと縮める (iPad Air 4 では縮まない)
                let scale = min(1, (proxy.size.width - 24) / Self.designW, (proxy.size.height - 24) / Self.designH)
                dialog
                    .frame(width: Self.designW, height: Self.designH, alignment: .topLeading)
                    .scaleEffect(scale)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .ignoresSafeArea()
        .transaction { $0.animation = nil }
    }

    private var dialog: some View {
        ZStack(alignment: .topLeading) {
            GridDialogFrameShape().fill(Color.black.opacity(0.5))
            GridDialogFrameShape().stroke(Color.white.opacity(0.3), lineWidth: 1.5)
            linesRow.offset(x: 0, y: 46.25)
            alignRow.offset(x: 0, y: 117.75)
            HStack(spacing: 21.5) {
                dialogButton("戻る") { state.showGridDialog = false }
                dialogButton("完了") {
                    state.gridLines = lines
                    state.gridAlign = align
                    state.showGridDialog = false
                }
            }
            .offset(x: 197.5, y: 267)
        }
    }

    // MARK: Grid lines (名前 + バー)

    private var linesRow: some View {
        HStack(spacing: 0) {
            Text("Grid lines")
                .font(PanelFont.label(19))
                .foregroundColor(.white)
                .frame(width: Self.labelW, alignment: .trailing)
            bar.padding(.leading, Self.labelGap)
        }
        .frame(height: Self.barH)
    }

    /// 灰色の部分が、今の値の位置。バーのどこかを触る / なぞると、その位置の値になる
    private var bar: some View {
        let clamped = min(max(lines, Self.minLines), Self.maxLines)
        let frac = CGFloat(clamped - Self.minLines) / CGFloat(Self.maxLines - Self.minLines)
        let fillW = Self.barW * frac
        return ZStack {
            GridBarShape()
                .fill(Color.white.opacity(0.5))
                .mask(
                    HStack(spacing: 0) {
                        Rectangle().frame(width: fillW)
                        Spacer(minLength: 0)
                    }
                )
            GridBarShape().stroke(Color.white.opacity(0.6), lineWidth: 0.8)
            Text("\(lines)")
                .font(PanelFont.menu(23))
                .foregroundColor(.white)
        }
        .frame(width: Self.barW, height: Self.barH)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = min(max(g.location.x / Self.barW, 0), 1)
                    let span = Double(Self.maxLines - Self.minLines)
                    lines = Self.minLines + Int((Double(f) * span).rounded())
                }
        )
    }

    // MARK: Grid align (名前 + チェックボックス)

    private var alignRow: some View {
        HStack(spacing: 0) {
            Text("Grid align")
                .font(PanelFont.label(19))
                .foregroundColor(.white)
                .frame(width: Self.labelW, alignment: .trailing)
            checkbox.padding(.leading, Self.labelGap)
        }
        .frame(width: Self.labelW + Self.labelGap + Self.boxSize + 8, height: 44, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { align.toggle() }
    }

    private var checkbox: some View {
        ZStack {
            Rectangle().strokeBorder(Color.white, lineWidth: 2.4)
            if align {
                Path { p in
                    p.move(to: CGPoint(x: 8.2, y: 19.5))
                    p.addLine(to: CGPoint(x: 14.2, y: 25.5))
                    p.addLine(to: CGPoint(x: 28.5, y: 11.5))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3.2, lineCap: .butt, lineJoin: .miter))
            }
        }
        .frame(width: Self.boxSize, height: Self.boxSize)
    }

    // MARK: 戻る / 完了

    private func dialogButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(.white)
                .frame(width: Self.buttonW, height: Self.buttonH)
                .background(Color.black.opacity(0.25))
                .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1.75))
                .contentShape(Rectangle())
        }
        .buttonStyle(GridDialogButtonStyle())
    }
}
