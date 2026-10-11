import SwiftUI

// MARK: - review の結果 (「0 issue found」)
//
// META → Review で多重ノーツが見つからなかったとき、画面の上に一瞬だけ出る小さな札。
// 見た目は Grid settings の中央ダイアログ (GridSettingsDialog.swift) の「クソ小さい版」:
//   ・中身は黒 50% の半透明、縁は白 30% の細い線 (どちらもダイアログと同じ濃さ)
//   ・形も同じ。右上が斜めに欠け、左側の上のほうが少しだけ外に出て段差がある
// 出し入れは勝手に行う。速く現れて (0.08 秒)、少し見せて (0.4 秒)、すっと消える (0.22 秒)。
// タッチは下へ通す。出ている途中でもう一度 review を押したら、出し直す。

/// Grid settings の枠 (`GridDialogFrameShape`) を、横長の小さな札に合わせて縮めた形
struct ReviewNoticeShape: Shape {
    func path(in r: CGRect) -> Path {
        let cham: CGFloat = 6        // 右上の欠け (ダイアログは 12.5pt)
        let step: CGFloat = 3.5      // 左側の段差の出っぱり (ダイアログは 7.5pt)
        let upper: CGFloat = 17      // 左の段差が始まる高さ (ダイアログは 92.25pt)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - cham, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cham))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + step, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + step, y: r.minY + upper + step))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + upper))
        p.closeSubpath()
        return p
    }
}

/// 画面の上の真ん中に出る「0 issue found」。EditorView の一番上の層に重ねる
/// - tick: `EditorState.reviewNoticeTick`。値が変わるたびに 1 回出る
struct ReviewNoticeLayer: View {
    let tick: Int

    @State private var opacity: Double = 0
    @State private var generation = 0       // 出し直したとき、前の「消す予約」を無効にするための番号

    private static let fadeIn = 0.08
    private static let hold = 0.4
    private static let fadeOut = 0.22

    var body: some View {
        Text("0 issue found")
            .font(PanelFont.label(16))
            .foregroundColor(.white)
            .frame(width: 168, height: 34)
            .background(ReviewNoticeShape().fill(Color.black.opacity(0.5)))
            .overlay(ReviewNoticeShape().stroke(Color.white.opacity(0.3), lineWidth: 1))
            .opacity(opacity)
            .padding(.top, 22)
            .allowsHitTesting(false)
            .onChange(of: tick) { _ in show() }
    }

    private func show() {
        generation += 1
        let mine = generation
        withAnimation(.easeOut(duration: Self.fadeIn)) { opacity = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeIn + Self.hold) {
            guard mine == generation else { return }
            withAnimation(.easeIn(duration: Self.fadeOut)) { opacity = 0 }
        }
    }
}
