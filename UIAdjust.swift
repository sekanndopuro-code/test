import SwiftUI
import UIKit

// MARK: - UI調整モード (画面構成の調整)
//
// SETTING の「UI調整モード」をオンにすると、譜面の編集・再生などは一切できなくなり (画面全体のタッチを止める)、
// 画面構成だけを編集するモードになる (`UIAdjustLayer`)。
//   ・左の帯 (拍の番号と目盛り) の右端をドラッグ → 帯の幅が広がる (`EditorState.stripWidth`。従来は 145pt)。
//       ズーム (−/＋) と FX ボタン、帯の中の拍番号・目盛りも、幅に比例して大きくなる (`StripButtonLayout`)。
//       ノッチ / ダイナミックアイランド (横画面では左端・上下中央) とは重ならない:
//       −/＋ は島より上に収まる大きさまで、FX は島に掛かる位置になるときだけ、島を跨いで下へ移る。
//       それ以上は大きくならない (そこが限界)
//   ・右ボタン列の左端をドラッグ → 列の幅が広がる (`EditorState.rightPanelWidth`。従来は 58pt)。
//       アイコンが幅に比例して大きくなる。ただし、縦に収まらなくなったり、アイコン同士の間隔
//       (アイコンの縁から縁まで) が従来より狭くなる大きさにはならない (そこが限界。`RightPanel.iconScaleLimit`)
//   ・「完了」で通常の画面に戻る。「リセット」で従来の幅 (145pt / 58pt) に戻す
//   決めた幅は保存される (次回起動時も同じ)。UI調整モードそのものは保存しない (開くたびにオフ)

enum UIAdjust {
    /// 左の帯の幅 (設計 pt)。従来は 145。上限は従来の 3 倍 (レーンの最低幅が先に足りなくなるときは、そこまで)
    static let stripWidthDefault: CGFloat = 145
    static let stripWidthMax: CGFloat = 145 * 3
    /// 右ボタン列の幅 (設計 pt)。従来は 58
    static let panelWidthDefault: CGFloat = 58
    static let panelWidthMax: CGFloat = 58 * 3
    /// レーンに最低限残す幅 (設計 pt)。Adv. メニューを開いても、これだけは残るように上限を決める
    static let minLaneWidth: CGFloat = 360

    /// 左の帯の幅の上限。designWidth は設計画面の幅 (= 画面の幅 ÷ 倍率)
    static func maxStripWidth(designWidth: CGFloat, panelWidth: CGFloat, advWidth: CGFloat) -> CGFloat {
        let room = designWidth - SeekPanel.totalWidth - panelWidth - advWidth - minLaneWidth
        return max(stripWidthDefault, min(stripWidthMax, room))
    }

    /// 右ボタン列の幅の上限。アイコンがそれ以上大きくならない幅 (通常の列が縦に収まる限界) より、広げても意味が無い
    static func maxPanelWidth(designWidth: CGFloat, stripWidth: CGFloat, advWidth: CGFloat,
                              height: CGFloat, compact: Bool) -> CGFloat {
        let room = designWidth - stripWidth - SeekPanel.totalWidth - advWidth - minLaneWidth
        let byIcons = panelWidthDefault * RightPanel.iconScaleLimit(forHeight: height, editing: false, compact: compact)
        return max(panelWidthDefault, min(panelWidthMax, min(room, byIcons)))
    }
}

// MARK: - 出し入れ

extension EditorState {
    /// UI調整モードに入る。再生を止め、メニューやウィンドウを閉じて、画面構成だけが見える状態にする
    func enterUIAdjust() {
        if isPlaying { pause() }
        popup = .none
        if sidePanel != nil { closeSidePanel() }
        uiAdjustMode = true
    }

    func exitUIAdjust() {
        uiAdjustMode = false
    }

    /// 帯と右ボタン列の幅を、従来の大きさ (145pt / 58pt) に戻す
    func resetUIAdjust() {
        stripWidth = UIAdjust.stripWidthDefault
        rightPanelWidth = UIAdjust.panelWidthDefault
    }
}

// MARK: - ノッチ / ダイナミックアイランド

/// 横画面で左端にあるノッチ / ダイナミックアイランドが占める範囲。
/// 画面の上下中央に、島なら長さ 125pt (iPhone 16 / 16 Pro: 画面の上から 134pt〜259pt) で居る。
/// 機種の判定は、画面の左右の安全領域の大きさ (島の機種 約59pt 以上 / 旧ノッチの機種 約44〜50pt / 無い機種 0)。
/// iPad の上の iPhone 表示プレビュー (PhonePreview.swift) では、選んだ機種の島を想定する
enum NotchGuard {
    /// 島の長さ (PhonePreview の島の絵と同じ) と、旧ノッチの長さ (iPhone X〜13 の横画面)
    private static let islandLength: CGFloat = 125
    private static let notchLength: CGFloat = 209

    /// 左端のノッチ / 島の縦の範囲 (画面の上端から測った実寸 pt)。無い機種は nil
    static func leftBand(screenHeight h: CGFloat) -> ClosedRange<CGFloat>? {
        let length: CGFloat
        if PhonePreview.isAvailable {
            // iPad。プレビューで島のある機種を選んでいるときだけ
            let raw = UserDefaults.standard.string(forKey: PhonePreview.deviceKey) ?? ""
            guard let device = PhonePreviewDevice(rawValue: raw), device.hasIsland else { return nil }
            length = islandLength
        } else if UIDevice.current.userInterfaceIdiom == .phone {
            let inset = horizontalInset()
            if inset >= 55 {
                length = islandLength
            } else if inset >= 40 {
                length = notchLength
            } else {
                return nil
            }
        } else {
            return nil
        }
        return (h / 2 - length / 2)...(h / 2 + length / 2)
    }

    /// 画面の左右の安全領域の大きさ (横画面の iPhone では、ノッチ / 島のある機種だけ大きい)
    private static func horizontalInset() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        guard let insets = window?.safeAreaInsets else { return 0 }
        return max(insets.left, insets.right)
    }
}

private struct NotchBandKey: EnvironmentKey { static let defaultValue: ClosedRange<CGFloat>? = nil }

extension EnvironmentValues {
    /// 左端のノッチ / 島が占める縦の範囲 (設計 pt、画面の上端から)。無い機種は nil。DesignCanvas が入れる
    var notchBand: ClosedRange<CGFloat>? {
        get { self[NotchBandKey.self] }
        set { self[NotchBandKey.self] = newValue }
    }
}

// MARK: - 左の帯の上のボタン (−/＋ と FX) の配置

/// ズーム (−/＋) と FX ボタンの大きさと位置。左の帯の幅に比例して大きくなる (scale = 帯の幅 ÷ 145)。
/// 島のある機種では、島に掛からない範囲に収める:
///   ・−/＋ とその下の「Zoom n」は、島より上に収まる大きさまで
///   ・FX は、ふだんは「Zoom n」の下。大きくなって島に掛かる位置になるときは、島を跨いで島の下へ移る
/// scale = 1 のときは、これまでと同じ位置になる (島に掛からない)。
struct StripButtonLayout {
    /// 実際に使うボタンの拡大率 (要求より小さいことがある)
    var scale: CGFloat
    /// 要求の拡大率まで大きくできなかったか (島 / 画面の高さが限界)
    var limited: Bool
    /// 島を跨いで、FX を島の下に置いているか
    var jumped: Bool
    /// −の当たり判定の上端 / −と＋のすき間 / 「Zoom n」の文字の大きさ / FX の当たり判定の上端 (どれも設計 pt、帯の上端から)
    var minusTop: CGFloat
    var gap: CGFloat
    var labelFont: CGFloat
    var fxTop: CGFloat

    /// 島との間に空ける余白 (設計 pt)
    private static let notchMargin: CGFloat = 8
    /// 画面の下端に残す余白 (設計 pt)
    private static let bottomMargin: CGFloat = 8

    /// ボタン 1 つの当たり判定の大きさ。見た目 (39 × 45 に scale) より小さくはならない。
    /// コンパクト表示 (iPhone) では、見た目より広げる (DesignScreen.hitLength)
    static func hit(forScale k: CGFloat, compact: Bool, designScale: CGFloat) -> CGSize {
        let vw = 39 * k
        let vh = 45 * k
        return CGSize(width: max(vw, DesignScreen.hitLength(vw, scale: designScale, compact: compact)),
                      height: max(vh, DesignScreen.hitLength(vh, scale: designScale, compact: compact)))
    }

    /// 要求の拡大率から、実際に使える大きさと位置を決める。収まらないときは、1 まで少しずつ小さくする
    static func resolve(requested: CGFloat, compact: Bool, designScale: CGFloat,
                        band: ClosedRange<CGFloat>?) -> StripButtonLayout {
        let want = max(1, requested)
        var k = want
        while k > 1 {
            let (layout, fits) = make(scale: k, compact: compact, designScale: designScale, band: band)
            if fits {
                var l = layout
                l.limited = k < want - 0.005
                return l
            }
            k -= 0.01
        }
        var l = make(scale: 1, compact: compact, designScale: designScale, band: band).0
        l.limited = want > 1.005
        return l
    }

    private static func make(scale k: CGFloat, compact: Bool, designScale: CGFloat,
                             band: ClosedRange<CGFloat>?) -> (StripButtonLayout, Bool) {
        let h = hit(forScale: k, compact: compact, designScale: designScale)
        let visualH = 45 * k
        let slack = (h.height - visualH) / 2          // 当たり判定の中で、見た目が上下に空ける分
        let top: CGFloat = compact ? 60 : 10.75
        let gap: CGFloat = compact ? 4 : 12.25
        let labelFont: CGFloat = (compact ? 17 : 10) * k
        let labelBottom = top + h.height + gap + h.height + 3 + labelFont * 1.2

        // FX の当たり判定の上端。コンパクト表示は「Zoom n」のすぐ下、それ以外は従来の位置 (159.5) か、それより下
        var fxTop = compact ? labelBottom + 4 : max(159.5, labelBottom + 12)
        var jumped = false
        if let b = band {
            let visTop = fxTop + slack
            let visBottom = visTop + visualH
            if visBottom > b.lowerBound && visTop < b.upperBound {
                fxTop = b.upperBound + notchMargin - slack      // 島を跨いで、島の下へ
                jumped = true
            }
        }

        var fits = fxTop + slack + visualH <= DesignScreen.height - bottomMargin
        if let b = band, labelBottom > b.lowerBound - 2 { fits = false }    // −/＋ と「Zoom n」は、島より上に収める
        let layout = StripButtonLayout(scale: k, limited: false, jumped: jumped,
                                       minusTop: top, gap: gap, labelFont: labelFont, fxTop: fxTop)
        return (layout, fits)
    }
}

// MARK: - UI調整モードの画面

/// UI調整モードのあいだ、EditorView の一番上に重ねる層。
/// 下のエディタへのタッチは全部止める (譜面の編集も再生もできない)。左の帯の右端と、右ボタン列の左端に、
/// 幅を変えるための持ち手を出す。持ち手はどちらも画面の高さいっぱい (どこをなぞっても動く)
struct UIAdjustLayer: View {
    @ObservedObject var state: EditorState
    @Environment(\.designScale) private var designScale
    @Environment(\.editorCompact) private var compact
    @Environment(\.notchBand) private var notchBand

    @State private var stripGrab: CGFloat? = nil      // 帯の右端を掴んだときの、指と右端のずれ
    @State private var panelGrab: CGFloat? = nil      // 右ボタン列の左端を掴んだときの、指と左端のずれ

    /// この層の座標系の名前 (持ち手が動いても、指の位置が揺れないようにするため)
    private static let space = "uiAdjustRoot"

    /// 実寸 1pt が設計 pt でいくつか (画面が小さい iPhone でも、実寸で読める / 押せる大きさにする)
    private var u: CGFloat { 1 / max(designScale, 0.2) }

    var body: some View {
        if state.uiAdjustMode {
            GeometryReader { proxy in
                content(W: proxy.size.width, H: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private func content(W: CGFloat, H: CGFloat) -> some View {
        let sw = state.stripWidth
        let pw = state.rightPanelWidth
        let tint = Color.panelBlue
        let layout = StripButtonLayout.resolve(requested: sw / UIAdjust.stripWidthDefault,
                                               compact: compact, designScale: designScale, band: notchBand)
        let stripAtLimit = sw >= UIAdjust.maxStripWidth(designWidth: W, panelWidth: pw, advWidth: CGFloat(state.advPanelWidth)) - 0.5
        let panelMax = UIAdjust.maxPanelWidth(designWidth: W, stripWidth: sw, advWidth: CGFloat(state.advPanelWidth),
                                              height: H, compact: compact)
        let panelAtLimit = pw >= panelMax - 0.5
        ZStack(alignment: .topLeading) {
            // 下のエディタのタッチを全部止める (ほんの少し暗くして、調整中だと分かるようにする)
            Color.black.opacity(0.3)
                .frame(width: W, height: H)
                .contentShape(Rectangle())
                .onTapGesture {}
            // 調整できる 2 つの領域
            tint.opacity(0.14)
                .frame(width: sw, height: H)
                .allowsHitTesting(false)
            tint.opacity(0.14)
                .frame(width: pw, height: H)
                .offset(x: W - pw)
                .allowsHitTesting(false)
            handle(atLimit: stripAtLimit, H: H, gesture: stripDrag(W: W))
                .offset(x: sw - 30 * u)
            handle(atLimit: panelAtLimit, H: H, gesture: panelDrag(W: W, H: H))
                .offset(x: W - pw - 30 * u)
            banner(layout: layout, stripLimit: stripAtLimit, panelLimit: panelAtLimit, W: W, H: H)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    // MARK: 持ち手

    /// 縦の線と、真ん中の ⇔ の丸み。限界まで動かしたら橙色にする
    private func handle<G: Gesture>(atLimit: Bool, H: CGFloat, gesture: G) -> some View {
        let c = atLimit ? Color.orange : Color.panelBlue
        return ZStack {
            Rectangle()
                .fill(c)
                .frame(width: 3 * u, height: H)
            RoundedRectangle(cornerRadius: 12 * u, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .frame(width: 34 * u, height: 84 * u)
            RoundedRectangle(cornerRadius: 12 * u, style: .continuous)
                .stroke(c, lineWidth: 2 * u)
                .frame(width: 34 * u, height: 84 * u)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 20 * u, weight: .bold))
                .foregroundColor(c)
        }
        .frame(width: 60 * u, height: H)                 // 指で掴める幅 (実寸 60pt)
        .contentShape(Rectangle())
        .gesture(gesture)
    }

    private func stripDrag(W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if stripGrab == nil { stripGrab = state.stripWidth - v.startLocation.x }
                let maxW = UIAdjust.maxStripWidth(designWidth: W, panelWidth: state.rightPanelWidth,
                                                  advWidth: CGFloat(state.advPanelWidth))
                let target = v.location.x + (stripGrab ?? 0)
                let nv = min(max(target, UIAdjust.stripWidthDefault), maxW)
                if abs(nv - state.stripWidth) > 0.01 { state.stripWidth = nv }
            }
            .onEnded { _ in stripGrab = nil }
    }

    private func panelDrag(W: CGFloat, H: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if panelGrab == nil { panelGrab = (W - state.rightPanelWidth) - v.startLocation.x }
                let maxW = UIAdjust.maxPanelWidth(designWidth: W, stripWidth: state.stripWidth,
                                                  advWidth: CGFloat(state.advPanelWidth), height: H, compact: compact)
                let left = v.location.x + (panelGrab ?? 0)
                let nv = min(max(W - left, UIAdjust.panelWidthDefault), maxW)
                if abs(nv - state.rightPanelWidth) > 0.01 { state.rightPanelWidth = nv }
            }
            .onEnded { _ in panelGrab = nil }
    }

    // MARK: 上の札 (説明・今の倍率・リセット / 完了)

    private func banner(layout: StripButtonLayout, stripLimit: Bool, panelLimit: Bool, W: CGFloat, H: CGFloat) -> some View {
        let stripPct = Int((state.stripWidth / UIAdjust.stripWidthDefault * 100).rounded())
        let buttonPct = Int((layout.scale * 100).rounded())
        let want = state.rightPanelWidth / UIAdjust.panelWidthDefault
        let mainPct = Int((min(want, RightPanel.iconScaleLimit(forHeight: H, editing: false, compact: compact)) * 100).rounded())
        let editPct = Int((min(want, RightPanel.iconScaleLimit(forHeight: H, editing: true, compact: compact)) * 100).rounded())
        let laneLeft = state.stripWidth + SeekPanel.totalWidth
        let laneW = max(1, W - state.rightPanelWidth - laneLeft)

        let line1 = "左の帯 \(stripPct)%  ボタン \(buttonPct)%" + (layout.limited ? " (上限)" : "") + (stripLimit ? "  帯は最大" : "")
        let line2 = "右メニュー \(mainPct)%" + (panelLimit ? " (上限)" : "") + "  EDIT中は \(editPct)% (縦に収まる範囲)"

        return VStack(spacing: 6 * u) {
            Text("UI調整モード")
                .font(.system(size: 16 * u, weight: .bold))
                .foregroundColor(.white)
            Text("青い線をドラッグして、左の帯・右メニューの幅を変えます")
                .font(.system(size: 11 * u))
                .foregroundColor(Color.white.opacity(0.75))
            Text(line1)
                .font(.system(size: 11 * u, design: .monospaced))
                .foregroundColor(Color.panelBlue)
            Text(line2)
                .font(.system(size: 11 * u, design: .monospaced))
                .foregroundColor(Color.panelBlue)
            HStack(spacing: 12 * u) {
                pill("リセット", prominent: false) { state.resetUIAdjust() }
                pill("完了", prominent: true) { state.exitUIAdjust() }
            }
            .padding(.top, 4 * u)
        }
        .padding(12 * u)
        .background(RoundedRectangle(cornerRadius: 14 * u, style: .continuous).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 14 * u, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1 * u))
        .fixedSize()
        .frame(width: laneW, alignment: .top)
        .padding(.top, 14 * u)
        .offset(x: laneLeft)
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16 * u, weight: .bold))
                .foregroundColor(prominent ? Color.black : Color.white)
                .padding(.horizontal, 22 * u)
                .frame(height: 44 * u)
                .background(RoundedRectangle(cornerRadius: 10 * u, style: .continuous)
                    .fill(prominent ? Color.panelBlue : Color.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }
}
