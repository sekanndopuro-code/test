import SwiftUI
import UIKit

// MARK: - 再生中に毎フレーム描き直す Canvas

/// TimelineView の中の Canvas は、クロージャが timeline.date を使っていないと
/// SwiftUI が「中身は変わっていない」と判断して再描画しない。
/// → 毎フレーム変わる値 (frame) をクロージャに取り込ませて、必ず描き直させる。
struct FrameCanvas: View {
    @ObservedObject var state: EditorState
    let draw: (GraphicsContext, CGSize) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !state.isPlaying)) { timeline in
            let frame = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                _ = frame
                draw(ctx, size)      // 時計は EditorState の CADisplayLink が進める (ここでは読むだけ)
            }
        }
    }
}

// MARK: - 背景画像 (画面全体)

/// 最初に読み込んだ背景画像を、画面いっぱい (ホームインジケータの下まで) に敷いて、黒を重ねて暗くする。
/// 帯・タイムライン・レーン・右ボタン列は透明に描くので、画像がすべての下に透けて見える。
/// 画像が無いときは、これまでどおり真っ黒。暗さは SETTING の「背景画像の暗さ」で変える
struct EditorBackground: View {
    @ObservedObject var state: EditorState

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = state.bgImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    Color.black.opacity(state.bgDim)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 譜面レーン

struct LaneView: View {
    @ObservedObject var state: EditorState

    /// 1回のタッチ (指を置いてから離すまで) の使い道。最初の1回で決まり、離すまで変わらない
    private enum Session {
        case idle
        case tool      // 編集ツールで操作 (配置 / 選択 / 移動 / 削除 ...)
        case pan       // 上下スライドでスクロール
    }

    @State private var session: Session = .idle
    @State private var touchStart: CGPoint? = nil    // 今のタッチの始点 (タッチの見分けに使う)
    @State private var scrollOrigin: Double? = nil
    @State private var pinchStart: Double? = nil     // ピンチ開始時の表示拍数
    @State private var panBlocked = false            // ピンチ中・直後は、指が1本残ってもスクロールしない
    @GestureState private var pinchActive = false    // ピンチ中だけ true (途中で取り消されても自動で false に戻る)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                FrameCanvas(state: state) { ctx, size in
                    LaneRenderer.draw(ctx: ctx, size: size, state: state)
                }
                .contentShape(Rectangle())
                .gesture(laneGesture(size: proxy.size))
                .simultaneousGesture(pinchGesture)
                .onChange(of: pinchActive) { active in
                    if !active { pinchStart = nil }    // ピンチの onEnded が届かなかった場合の保険
                }

                // EDIT を開いている間は、どのツール (未選択 / LASSO / Remove なども) でも常に出す。
                // LASSO などで選んだノーツの幅を、その場で変えられるようにするため
                if state.editing {
                    widthBar
                }
            }
        }
        .clipped()
    }

    private func laneGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // 新しいタッチかどうかは、始点 (startLocation) でも見分ける。
                // ピンチに取り消されたタッチは onEnded が届かないことがあり、session / panBlocked が残ったままになる。
                // その状態だと、ピンチの後の最初のドラッグが「ピンチの続き」と見なされて無視されていた。
                if session == .idle || touchStart != v.startLocation {
                    touchStart = v.startLocation
                    scrollOrigin = nil
                    panBlocked = pinchStart != nil      // 本当にピンチの最中のときだけ、スクロールを止める
                    // 編集ツールを選んでいるときだけ編集操作。未選択 (または閲覧モード) のときは上下スライドだけ
                    session = state.laneToolActive ? .tool : .pan
                    state.holdCancel()
                    if session == .tool {
                        state.laneTouch(start: v.startLocation, current: v.location, size: size, phase: .began)
                        return
                    }
                    if !panBlocked { state.holdBegan() }     // ツール未選択: 押し続けると選択が解除される (SETTING の秒数)
                }
                switch session {
                case .tool:
                    state.laneTouch(start: v.startLocation, current: v.location, size: size, phase: .changed)
                case .pan:
                    if hypot(v.translation.width, v.translation.height) > 10 { state.holdCancel() }
                    if panBlocked { return }
                    if scrollOrigin == nil {
                        if state.isPlaying { state.pause() }
                        scrollOrigin = state.viewBeat
                    }
                    let ppb = Double(size.height) / state.visibleBeats
                    if let o = scrollOrigin {
                        state.setViewBeat(o + Double(v.translation.height) / ppb)
                    }
                case .idle:
                    break
                }
            }
            .onEnded { v in
                state.holdCancel()
                if session == .tool {
                    state.laneTouch(start: v.startLocation, current: v.location, size: size, phase: .ended)
                }
                session = .idle
                touchStart = nil
                scrollOrigin = nil
                panBlocked = false
            }
    }

    /// ピンチでズーム (編集ツール未選択 / 閲覧モードのときだけ)。再生ラインの位置を基準に拡大縮小する
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchActive) { _, active, _ in active = true }
            .onChanged { scale in
                if state.laneToolActive { return }
                state.holdCancel()                      // ピンチは長押しではない
                if !panBlocked { panBlocked = true }    // ピンチ中は上下スクロールしない
                if pinchStart == nil {
                    pinchStart = state.visibleBeats
                    scrollOrigin = nil
                }
                if let s0 = pinchStart {
                    state.pinchZoom(startVisibleBeats: s0, scale: Double(scale))
                }
            }
            .onEnded { _ in
                pinchStart = nil
            }
    }

    /// ノーツ幅スライダー。本家と同じく、レーンの左端 (x=0) から、置かれるノーツの幅の位置までを、透明な白の単色の帯で見せる。
    /// 文字・つまみ・暗い土台は出さない。レーンの x=0〜255 とぴったり同じ位置に置く (レーンの描画と同じ trackL / trackW を使う)。
    /// 帯は本家の位置 (画面の下端から約 19pt 上、高さ 18pt) に描き、指で触れる範囲はその周りの下端まで広くとっている
    private var widthBar: some View {
        GeometryReader { proxy in
            let g = LaneGeo(W: proxy.size.width, H: proxy.size.height, viewBeat: 0, ppb: 1)
            LaneWidthSlider(
                value: Binding(
                    get: { state.widthUnits },
                    set: { state.widthSliderMoved($0) }      // 選択中のノーツがあれば、その幅も変わる
                ),
                trackL: g.trackL,
                trackW: g.trackW,
                onBegan: { state.widthSliderBegan() },
                onEnded: { state.widthSliderEnded() }
            )
        }
        .frame(height: LaneWidthSlider.touchHeight)
    }
}

/// レーンに合わせたノーツ幅スライダー (4〜255)
/// 座標は LaneView と同じ (左端 = レーンビューの左端)。x = trackL + 幅/255 × trackW が、帯の右端
struct LaneWidthSlider: View {
    @Binding var value: Int
    let trackL: CGFloat
    let trackW: CGFloat
    var onBegan: () -> Void = {}                 // 指を置いた瞬間 / 離した瞬間
    var onEnded: () -> Void = {}
    @State private var grab: CGFloat? = nil      // 帯の右端を掴んだときの、指と右端のずれ

    static let touchHeight: CGFloat = 52         // 指で触れる範囲の高さ (画面の下端から)
    static let barHeight: CGFloat = 18           // 帯の高さ (本家の実測 約 18pt)
    static let barBottom: CGFloat = 19           // 帯の下端から画面の下端までの距離 (本家の実測 約 19pt)

    private let minValue = 4
    private let maxValue = 255

    private func xOf(_ v: Int) -> CGFloat {
        trackL + CGFloat(v) / 255.0 * trackW
    }

    var body: some View {
        let hx = xOf(value)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Color.clear.frame(width: trackL, height: Self.barHeight)
                // 左端 → 右端 (= ノーツの幅)。本家と同じ透明な白 (背景に対して約 50% の白)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.5))
                    .frame(width: max(0, hx - trackL), height: Self.barHeight)
                Spacer(minLength: 0)
            }
            .padding(.bottom, Self.barBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if grab == nil {
                        // 帯の右端の近くを掴んだら、ずれを保ったまま動かす。それ以外はタッチした位置へ移る
                        let tx = xOf(value)
                        grab = abs(v.startLocation.x - tx) <= 26 ? tx - v.startLocation.x : 0
                        onBegan()
                    }
                    let px = v.location.x + (grab ?? 0)
                    let u = Int(((px - trackL) / trackW * 255.0).rounded())
                    let nv = min(maxValue, max(minValue, u))
                    if nv != value { value = nv }
                }
                .onEnded { _ in
                    grab = nil
                    onEnded()
                }
        )
    }
}

// MARK: - 左の縦長タイムライン (ノーツ配置中のスクロール用) + ズーム

struct StripView: View {
    /// 左の帯 (拍の番号と目盛り) の幅。本家 (iPad Air 4 の横画面 1180pt) では 約 145pt。
    /// この幅 + シークバー 66 + 時刻 38 で、レーン (左の番号の欄 25.2pt を含む) の左端が 249pt になる。
    /// 本家の帯は、右に約10pt の暗い側面 (斜めの面取り) が続く。側面はシークバーの左端に重なるので、SeekRenderer が描く
    static let width: CGFloat = 145

    @ObservedObject var state: EditorState
    @State private var origin: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                FrameCanvas(state: state) { ctx, size in
                    StripRenderer.draw(ctx: ctx, size: size, state: state)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if origin == nil {
                                if state.isPlaying { state.pause() }
                                origin = state.viewBeat
                            }
                            let ppb = Double(proxy.size.height) / state.stripBeats
                            if let o = origin {
                                state.setViewBeat(o + Double(v.translation.height) / ppb)
                            }
                        }
                        .onEnded { _ in origin = nil }
                )

                // 本家の実測: − の上端は画面の上から 10.75pt、＋はその 57.25pt 下 (ボタンの高さ 45pt + すき間 12.25pt)
                VStack(alignment: .leading, spacing: 0) {
                    ZoomButton(isPlus: false) { state.zoomOut() }
                    Color.clear.frame(width: 1, height: 12.25)
                    ZoomButton(isPlus: true) { state.zoomIn() }
                    Text("Zoom " + state.zoomLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.7))
                        .padding(.leading, 4)
                        .padding(.top, 3)
                }
                .padding(.top, 10.75)
            }
        }
        .clipped()
    }
}

/// 拡大/縮小ボタン。本家の実測: 幅 39 × 高さ 45pt の五角形 (形は ZoomButtonShape)、
/// 塗りは不透明な青みのある灰色、縁は白 1.5pt、記号は白い棒 (長さ 25pt × 太さ 3.3pt) で中心は左端から 16.5pt
struct ZoomButton: View {
    let isPlus: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                ZoomButtonShape().fill(Color(red: 127.0 / 255.0, green: 131.0 / 255.0, blue: 138.0 / 255.0))
                ZoomButtonShape().stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineJoin: .miter))
                ZStack {
                    Rectangle().fill(Color.white).frame(width: 25.5, height: 3.3)
                    if isPlus {
                        Rectangle().fill(Color.white).frame(width: 3.3, height: 25)
                    }
                }
                .position(x: 16.5, y: 22.5)
            }
            .frame(width: 39, height: 45)
            .contentShape(ZoomButtonShape())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 曲全体シークバー + 時刻表示 + 再生ボタン

/// シークバー (66pt) と時刻表示 (38pt) を並べ、その上に再生ボタンを重ねる。
/// 再生ボタンはシークバーの幅からレーン側へはみ出して、時刻表示の上まで広がる (レーンには掛けない)。
/// シークバーをドラッグしている間 (seeking) は、ボタンを透明にして下のシークバーを見えるようにする。
struct SeekPanel: View {
    @ObservedObject var state: EditorState
    @State private var seeking = false

    static let seekWidth: CGFloat = 66
    static let labelWidth: CGFloat = 38
    static var totalWidth: CGFloat { seekWidth + labelWidth }

    var body: some View {
        GeometryReader { proxy in
            let H = proxy.size.height
            // 高さは全体の 1/5。ただし、上下の時刻表示 (縦書き) に掛からない範囲に収める (小さい画面用)
            let btnH = min(H / 5, max(60, H - 340))
            let btnW = Self.totalWidth - 2          // レーンとの間に 2pt 空ける
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    SeekView(state: state, seeking: $seeking).frame(width: Self.seekWidth)
                    TimeLabelView(state: state).frame(width: Self.labelWidth)
                }
                PlayToggleButton(state: state, dimmed: seeking)
                    .frame(width: btnW, height: btnH)
                    .position(x: btnW / 2, y: H / 2)
            }
        }
    }
}

struct SeekView: View {
    @ObservedObject var state: EditorState
    @Binding var seeking: Bool
    @State private var dragging = false
    @GestureState private var touching = false      // 指が触れている間だけ true (取り消されても自動で false に戻る)

    var body: some View {
        GeometryReader { proxy in
            FrameCanvas(state: state) { ctx, size in
                SeekRenderer.draw(ctx: ctx, size: size, state: state)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, active, _ in active = true }
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            state.seekBegin()
                        }
                        let f = 1.0 - Double(v.location.y / max(1, proxy.size.height))
                        state.seek(fraction: f)
                    }
                    .onEnded { _ in
                        dragging = false
                        state.seekEnd()
                    }
            )
            .onChange(of: touching) { active in
                seeking = active
            }
        }
        .clipped()
    }
}

/// 再生/停止ボタン (縦長の長方形)。
/// 通常の Button は「指を離した時」に反応するため、タップの長さぶん(60〜120ms)が必ず遅れる。
/// ここでは指が触れた瞬間に切り替える (停止の体感遅延を減らすため)。
/// 離した時に切り替える従来の動きに戻したい場合は、下の gesture を Button { state.togglePlay() } に置き換える。
/// dimmed (シークバーをドラッグ中) のときは透明にして、タッチも受けない。
struct PlayToggleButton: View {
    @ObservedObject var state: EditorState
    var dimmed: Bool = false
    @State private var pressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: pressed ? 0.60 : 0.45).opacity(0.92))
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.white)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .opacity(dimmed ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: dimmed)
        .allowsHitTesting(!dimmed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        state.togglePlay()
                    }
                }
                .onEnded { _ in pressed = false }
        )
    }
}

struct TimeLabelView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        FrameCanvas(state: state) { ctx, size in
            TimeLabelRenderer.draw(ctx: ctx, size: size, state: state)
        }
    }
}

// MARK: - 右端のボタン列

struct PanelButton: View {
    let glyph: String
    let caption: String
    var active: Bool = false
    var dimmed: Bool = false
    /// 文字 (glyph) の代わりに出すアイコン。引数は今のボタンの文字色 (選択中はシアン)
    var icon: ((Color) -> AnyView)? = nil
    let action: () -> Void

    var body: some View {
        let fg = active ? Color.laneCyan : (dimmed ? Color.white.opacity(0.35) : Color.white)
        Button(action: action) {
            VStack(spacing: 1) {
                if let icon = icon {
                    icon(fg).frame(height: 25)
                } else {
                    Text(glyph).font(.system(size: 21, weight: .semibold))
                }
                Text(caption).font(.system(size: 9, design: .monospaced))
            }
            .foregroundColor(fg)
            .frame(width: 58, height: 50)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(active ? 0.22 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.laneCyan : Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// LASSO ボタンの絵。点線の輪と、そこから垂れる縄 (SF Symbols に頼らず、パスで描いている)
struct LassoIcon: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let loop = Path(ellipseIn: CGRect(x: w * 0.06, y: h * 0.04, width: w * 0.88, height: h * 0.56))
            ctx.stroke(loop, with: .color(color),
                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [3.4, 2.6]))
            var rope = Path()
            rope.move(to: CGPoint(x: w * 0.30, y: h * 0.56))
            rope.addQuadCurve(to: CGPoint(x: w * 0.46, y: h * 0.95),
                              control: CGPoint(x: w * 0.12, y: h * 0.80))
            ctx.stroke(rope, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        .frame(width: 30, height: 25)
    }
}

struct RightPanel: View {
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(spacing: 6) {
            if state.editing {
                editButtons
            } else {
                mainButtons
            }
            Spacer(minLength: 0)
            Text(state.saveStatus)
                .font(.system(size: 9))
                .foregroundColor(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(width: 58)
            PanelButton(glyph: "⏱", caption: String(format: "%gx", state.playSpeed),
                        active: state.popup == .speed) {
                state.popup = state.popup == .speed ? .none : .speed
            }
            PanelButton(glyph: "▤", caption: "1/\(state.snapDen)", active: state.popup == .divide) {
                state.popup = state.popup == .divide ? .none : .divide
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 24)                            // 画面の下端まで届くようにしたので、ホームインジケータの所を空ける
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.35))           // 背景画像が透けて見える
        .overlay(Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1), alignment: .leading)
    }

    private var mainButtons: some View {
        VStack(spacing: 6) {
            PanelButton(glyph: "✎", caption: "EDIT", icon: { AnyView(PanelIconView(kind: .edit, color: $0)) }) {
                state.popup = .none
                state.editing = true
            }
            PanelButton(glyph: "♩", caption: "BPM", icon: { AnyView(PanelIconView(kind: .bpm, color: $0)) }) {
                state.sheet = .bpm
            }
            PanelButton(glyph: "✦", caption: "EFFECT") { state.sheet = .effect }     // scroll / jump (BPM の下)。アイコンは未作成で文字のまま
            // TEST のアイコンは、本家の 3番目 (カチンコ)
            PanelButton(glyph: "▶︎|", caption: "TEST", icon: { AnyView(PanelIconView(kind: .test, color: $0)) }) {
                state.startTestPlay()
            }
            PanelButton(glyph: "≡", caption: "META", icon: { AnyView(PanelIconView(kind: .meta, color: $0)) }) {
                state.sheet = .meta
            }
            PanelButton(glyph: "⚙︎", caption: "SETTING", active: state.showSetting,
                        icon: { AnyView(PanelIconView(kind: .setting, color: $0)) }) {
                state.popup = .none
                state.showSetting.toggle()
            }
        }
    }

    private var editButtons: some View {
        VStack(spacing: 6) {
            PanelButton(glyph: "←", caption: "Back") {
                state.advOpen = false
                state.stopInteractivePlugin()
                if state.tool == .plugin { state.tool = .unselected }
                state.editing = false
                state.tool = .unselected
                state.selectedIDs = []
                state.ghost = nil
                state.popup = .none
            }
            // 選択中のアイコンをもう一度タップすると、未選択に戻る (未選択 = レーンの上下スライド / ピンチだけ)
            PanelButton(glyph: "▬", caption: "Note", active: state.tool == .note) { state.toggleTool(.note) }
            PanelButton(glyph: "◆", caption: "Wipe", active: state.tool == .wipe) { state.toggleTool(.wipe) }
            // スライド作成中 (始点を置いたあと) は「完」になり、押すとその始点の seg 配置を終える
            PanelButton(glyph: state.slideDraft != nil ? "完" : "⌇", caption: "Slide", active: state.tool == .slide) {
                if state.slideDraft != nil { state.finishSlide() } else { state.toggleTool(.slide) }
            }
            // 選択中のノーツがあれば、それを削除する。何も選択していなければ Remove ツールの ON/OFF (タップで1個ずつ消す)
            PanelButton(glyph: "✕", caption: "Remove", active: state.tool == .remove) { state.removeButtonTapped() }
            // 指でなぞって囲んだ範囲のノーツを、まとめて選択に追加する (お絵描きソフトの投げ縄)。もう一度タップで未選択に戻る
            PanelButton(glyph: "◌", caption: "LASSO", active: state.tool == .lasso,
                        icon: { AnyView(LassoIcon(color: $0)) }) {
                state.toggleTool(.lasso)
                if state.tool == .lasso {
                    state.showToast("指でなぞって囲んだノーツを選択に追加します (タップで解除)")
                }
            }
            // 「順番に選択」: スライドをタップした順に番号を付ける。結合系プラグイン (折り返し敷など) が、この順番で結合する。
            // ツールを離れても順番は残る (caption の数字が、選んだ数)。空きをタップするとリセット
            PanelButton(glyph: "①②", caption: state.orderIDs.isEmpty ? "Order" : "Order \(state.orderIDs.count)",
                        active: state.tool == .order) {
                state.toggleTool(.order)
                if state.tool == .order {
                    state.showToast("スライドをタップした順に番号を付けます (空きをタップでリセット)")
                }
            }
            // Lua プラグインのメニュー。開くとレーンが細くなり、再生ボタンとレーンの間にプラグインの一覧が出る
            PanelButton(glyph: "λ", caption: "Adv.", active: state.advOpen) {
                state.popup = .none
                withAnimation(.easeInOut(duration: 0.22)) { state.advOpen.toggle() }
            }
            PanelButton(glyph: "•••", caption: "More",
                        active: state.popup == .more || state.tool == .selectRange || state.tool == .slideModify) {
                state.popup = state.popup == .more ? .none : .more
            }
            HStack(spacing: 4) {
                smallButton("↶", enabled: state.undoCount > 0) { state.undo() }
                smallButton("↷", enabled: state.redoCount > 0) { state.redo() }
            }
        }
    }

    private func smallButton(_ t: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(enabled ? Color.white : Color.white.opacity(0.25))
                .frame(width: 27, height: 36)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 画面全体

struct EditorView: View {
    @ObservedObject var state: EditorState

    /// 右下の分割の「入力…」で開く数値入力
    @State private var showInput = false
    @State private var inputText = ""

    var body: some View {
        HStack(spacing: 0) {
            StripView(state: state).frame(width: StripView.width)
            SeekPanel(state: state).frame(width: SeekPanel.totalWidth)
            // Adv. メニュー: 幅 0 → 196 に変わると、右隣のレーンは右端を固定したまま左端が右へ動いて縮む
            AdvPanel(state: state)
                .frame(width: advWidth, alignment: .leading)
                .clipped()
                .allowsHitTesting(advWidth > 0)
            LaneView(state: state)
            RightPanel(state: state).frame(width: 66)
        }
        .background(EditorBackground(state: state))      // 背景画像 (無いときは黒)。ノーツ・レーン・帯は透明に描いて、これを透かす
        .ignoresSafeArea(.keyboard, edges: .bottom)      // 数値入力のキーボードで、エディタ全体が縮まないように
        .overlay(slideModifyLayer, alignment: .top)
        .overlay(popupLayer)
        .overlay(settingLayer)
        .overlay(PluginDialogLayer(state: state))
        .overlay(toastLayer, alignment: .bottom)
        .alert("分割 (1/n)", isPresented: $showInput) {
            TextField("2〜1024", text: $inputText)
                .keyboardType(.numberPad)
            Button("OK") { commitInput() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("n を 2〜1024 の整数で (例: 48 → 1/48)")
        }
        .fullScreenCover(item: $state.testLaunch) { launch in
            TestPlayScreen(launch: launch) { state.testLaunch = nil }
        }
        .sheet(item: $state.sheet) { s in
            switch s {
            case .bpm:
                BPMListSheet(state: state)
            case .effect:
                EffectListSheet(state: state)
            case .grid:
                GridSettingsSheet(state: state)
            case .meta:
                MetaSheet(state: state)
            }
        }
    }

    /// Adv. メニューの今の幅 (EDIT 中に開いているときだけ。閉じているときは 0)
    private var advWidth: CGFloat {
        (state.editing && state.advOpen) ? AdvPanel.width : 0
    }

    /// Slide modify の窓。レーンの上に重ねるだけで、背景は暗くせず、窓の外のタップも奪わない。
    /// (「コンパクト」にすると上の細い横長だけになり、レーンのスライドを直接タップ・ドラッグして編集できる)
    @ViewBuilder
    private var slideModifyLayer: some View {
        if state.editing && state.tool == .slideModify {
            SlideModifyWindow(state: state)
                .frame(maxWidth: 460)
                .padding(.leading, StripView.width + SeekPanel.totalWidth + advWidth + 8)     // 左の帯・シークバー・Adv. メニューを避けて、レーンの上に置く
                .padding(.trailing, 66 + 8)                           // 右のボタン列を避ける
                .padding(.top, 8)
        }
    }

    /// SETTING ウィンドウ。背景は暗くせず、タップも奪わない
    /// (曲を再生したまま音量を調整して、聞き比べられるように)
    @ViewBuilder
    private var settingLayer: some View {
        if state.showSetting {
            SettingWindow(state: state)
                .padding(.trailing, 66)      // 右のボタン列を避けて、レーン側の中央に置く
        }
    }

    @ViewBuilder
    private var popupLayer: some View {
        if state.popup != .none {
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { state.popup = .none }
                popupBody
                    .padding(.trailing, 72)
                    .padding(.bottom, state.popup == .speed ? 66 : 8)
            }
        }
    }

    @ViewBuilder
    private var popupBody: some View {
        switch state.popup {
        case .speed:
            popupList(speedItems())
        case .divide:
            popupList(divideItems())
        case .more:
            moreList
        case .none:
            EmptyView()
        }
    }

    private struct PopupItem {
        let title: String
        let selected: Bool
        let action: () -> Void
    }

    private func speedItems() -> [PopupItem] {
        var out: [PopupItem] = []
        for v in EditorState.speeds {
            let sel = abs(v - state.playSpeed) < 0.0001
            out.append(PopupItem(title: String(format: "%gx", v), selected: sel, action: { state.setSpeed(v) }))
        }
        return out
    }

    private func divideItems() -> [PopupItem] {
        var out: [PopupItem] = []
        for d in EditorState.divides {
            out.append(PopupItem(title: "1/\(d)", selected: d == state.snapDen, action: { state.setDivide(d) }))
        }
        out.append(PopupItem(title: "入力…", selected: !EditorState.divides.contains(state.snapDen), action: { openInput() }))
        return out
    }

    private func openInput() {
        state.popup = .none
        inputText = ""
        showInput = true
    }

    private func commitInput() {
        state.applyDivideInput(inputText)
    }

    private func popupList(_ items: [PopupItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { entry in
                Button(action: entry.element.action) {
                    Text(entry.element.title)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundColor(entry.element.selected ? Color.laneCyan : Color.white)
                        .frame(width: 86, height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black.opacity(0.94))
        .overlay(Rectangle().stroke(Color.white.opacity(0.35), lineWidth: 1))
    }

    private var moreList: some View {
        VStack(alignment: .leading, spacing: 0) {
            moreItem("Copy", dim: state.selectedIDs.isEmpty) { state.popup = .none; state.copySelection() }
            moreItem("Paste", dim: state.clip.isEmpty) { state.popup = .none; state.paste() }
            moreItem("Time range", active: state.tool == .selectRange) {
                state.popup = .none
                state.beginSelectRange()
            }
            moreItem("Flip notes horizontal") { state.popup = .none; state.flipHorizontal() }
            moreItem("Grid settings") { state.popup = .none; state.sheet = .grid }
            moreItem("Slide modify", active: state.tool == .slideModify) {
                state.popup = .none
                state.tool = .slideModify
            }
            moreItem("Slide to Wipe") { state.popup = .none; state.slideToWipe() }
            moreItem("Wipe to Slide") { state.popup = .none; state.wipeToSlide() }
        }
        .frame(width: 230)
        .background(Color.black.opacity(0.94))
        .overlay(Rectangle().stroke(Color.white.opacity(0.35), lineWidth: 1))
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }

    private func moreItem(_ t: String, active: Bool = false, dim: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 17))
                .foregroundColor(active ? Color.laneCyan : (dim ? Color.white.opacity(0.4) : Color.white))
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let t = state.toast {
            Text(t)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(white: 0.15).opacity(0.95)))
                .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .padding(.bottom, 60)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - SETTING ウィンドウ (曲の音量 / ノーツサウンドの音量)

struct SettingWindow: View {
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("SETTING")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                Spacer()
                Button {
                    state.showSetting = false
                } label: {
                    Text("✕")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            volumeRow(title: "曲の音量", value: $state.musicVolume, onEditingChanged: nil)

            volumeRow(title: "ノーツサウンドの音量", value: $state.noteVolume) { editing in
                // 指を離した時に1回鳴らして、音量を確かめられるようにする
                if !editing { KeySound.shared.playNow() }
            }

            Text("ノーツサウンドは、再生中にノーツが再生ラインに触れる瞬間と、テストプレイで叩いた瞬間に鳴ります。0% で消せます。")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().background(Color.white.opacity(0.3))

            if state.bgImage != nil {
                bgRow

                Divider().background(Color.white.opacity(0.3))
            }

            checkRow(title: "立ち上がりをはっきりさせる (伸ばす窓を小さく)",
                     note: "伸ばした音の、ドラムなどの出だしのにじみが約半分になります (0.1倍で前46ms・後74ms → 前26ms・後36ms)。そのかわり 60Hz付近の低音が少しゆらぎます。次の再生から変わります。",
                     isOn: $state.sharpStretch)

            Divider().background(Color.white.opacity(0.3))

            checkRow(title: "beatがマイナスのsegを置くのを許可する",
                     note: "オフのとき: Slide ツールで始点より前をタップすると、「完」を押さなくても seg の配置を終えられます。Slide modify では始点より前に置けず、ドラッグしても始点の位置で止まります。オンにすると、始点より前 (beat がマイナス) にも seg を置けます。",
                     isOn: $state.allowNegativeSeg)

            Divider().background(Color.white.opacity(0.3))

            holdRow

            if !state.playInfo.isEmpty {
                Text(state.playInfo)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.laneCyan.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundColor(.white)
        .padding(16)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.35), lineWidth: 1))
    }

    /// 背景画像の暗さ (0〜95%、5% 刻み。保存される。背景画像を読み込んでいるときだけ出る)
    private var bgRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("背景画像の暗さ")
                    .font(.system(size: 15))
                Spacer()
                Text("\(Int((state.bgDim * 100).rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.laneCyan)
            }
            Slider(value: $state.bgDim, in: 0...0.95, step: 0.05)
                .tint(Color.laneCyan)
        }
    }

    /// 長押しで選択解除までの秒数 (1.0〜5.0 秒、0.1 秒刻み。保存される)
    private var holdRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("長押しで選択解除")
                    .font(.system(size: 15))
                Spacer()
                Text(String(format: "%.1f 秒", state.holdDeselectSec))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.laneCyan)
            }
            Slider(value: $state.holdDeselectSec, in: EditorState.holdRange, step: 0.1)
                .tint(Color.laneCyan)
            Text("編集ツールを選んでいないとき、レーンを動かさずに押し続けると、選択中のノーツが全部解除されます。")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func checkRow(title: String, note: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                        .font(.system(size: 22))
                        .foregroundColor(isOn.wrappedValue ? Color.laneCyan : Color.white.opacity(0.7))
                    Text(title)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(note)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func volumeRow(title: String, value: Binding<Double>,
                           onEditingChanged: ((Bool) -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.laneCyan)
            }
            Slider(value: value, in: 0...1, step: 0.05, onEditingChanged: { editing in
                onEditingChanged?(editing)
            })
            .tint(Color.laneCyan)
        }
    }
}
