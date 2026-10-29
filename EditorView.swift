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

    /// レーンの右隣のボタン列の幅 (ノーツがレーンの右端からはみ出したとき、この下まで描く)
    private static var spillRight: CGFloat { RightPanel.width }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // レーンの左端が、エディタ全体の左端からどれだけ右にあるか (左の帯・シークバー・Adv. メニューの幅。Adv. の開閉アニメーションにも追従する)
            let spillL = max(0, proxy.frame(in: .named(EditorView.rootSpace)).minX)
            let spillR = Self.spillRight

            // タッチを受けるのは、これまでどおりレーンの枠の中だけ。描画は下の overlay が、枠の外まで広げて行う。
            Color.clear
                .contentShape(Rectangle())
                .gesture(laneGesture(size: size))
                .simultaneousGesture(pinchGesture)
                .onChange(of: pinchActive) { active in
                    if !active { pinchStart = nil }    // ピンチの onEnded が届かなかった場合の保険
                }
                .overlay(alignment: .topLeading) {
                    // 枠をはみ出したノーツ (リボン・点・棒) も、本家と同じく左の帯・シークバー・右のボタン列の下まで描く。
                    // 描画の座標は、いつものレーンの座標のまま (左へ spillL だけ平行移動して描くので、はみ出しは負の x になる)。
                    // 当たり判定は、レーンの枠の中のまま変わらない (上の gesture はレーンの大きさの Color.clear にだけ付いている)。
                    FrameCanvas(state: state) { ctx, _ in
                        var c = ctx
                        c.translateBy(x: spillL, y: 0)
                        LaneRenderer.draw(ctx: c, size: size, state: state)
                    }
                    .frame(width: size.width + spillL + spillR, height: size.height)
                    .offset(x: -spillL)
                    .allowsHitTesting(false)
                }
                // EDIT を開いている間は、どのツール (未選択 / LASSO / Remove なども) でも常に出す。
                // LASSO などで選んだノーツの幅を、その場で変えられるようにするため
                .overlay(alignment: .bottom) {
                    if state.editing {
                        widthBar
                    }
                }
        }
        // ここで .clipped() はしない (枠の外まで描くため)。左の帯・シークバーより下の層に置くのは EditorView 側の zIndex
    }

    /// 新しいタッチの始まりの処理 (使い道を決める)。onChanged の最初の1回で呼ぶ。
    /// 指が触れてすぐ離れた短いタップでは、onChanged が1回も呼ばれずに onEnded だけ届くことがあるので、onEnded からも呼ぶ。
    /// - Returns: 編集ツールのタッチとして始めたら true (呼び出し側は、この回の続きの処理をしない)
    @discardableResult
    private func beginSession(_ v: DragGesture.Value, size: CGSize) -> Bool {
        touchStart = v.startLocation
        scrollOrigin = nil
        panBlocked = pinchStart != nil      // 本当にピンチの最中のときだけ、スクロールを止める
        // 編集ツールを選んでいるときだけ編集操作。未選択 (または閲覧モード) のときは上下スライドだけ
        session = state.laneToolActive ? .tool : .pan
        state.holdCancel()
        if session == .tool {
            state.laneTouch(start: v.startLocation, current: v.location, size: size, phase: .began)
            return true
        }
        if !panBlocked { state.holdBegan() }     // ツール未選択: 押し続けると選択が解除される (SETTING の秒数)
        return false
    }

    private func laneGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // 新しいタッチかどうかは、始点 (startLocation) でも見分ける。
                // ピンチに取り消されたタッチは onEnded が届かないことがあり、session / panBlocked が残ったままになる。
                // その状態だと、ピンチの後の最初のドラッグが「ピンチの続き」と見なされて無視されていた。
                if session == .idle || touchStart != v.startLocation {
                    if beginSession(v, size: size) { return }
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
                    // 触れただけ (まだ動かしていない) では位置を動かさない: スナップで触れた瞬間に飛ばないように
                    if let o = scrollOrigin, v.translation.height != 0 {
                        state.scrollViewBeat(o + Double(v.translation.height) / ppb)
                    }
                case .idle:
                    break
                }
            }
            .onEnded { v in
                state.holdCancel()
                // onChanged が1回も届かないまま離された (指が触れてすぐ離れた短いタップ。メニューを閉じた直後などに起きる) とき。
                // これまでは session が idle のままで、タップが丸ごと無視されていた (Time range の始点・LASSO のタップ解除が反応しない)。
                // 編集ツールのときだけ、ここで「始まり → 終わり」を続けて処理する
                if (session == .idle || touchStart != v.startLocation) && state.laneToolActive {
                    beginSession(v, size: size)
                }
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
                    get: { state.snapWidth(state.widthUnits) },      // グリッド有効時は、ノーツに入る幅 (1マスの整数倍) をそのまま見せる
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
    @GestureState private var touching = false   // 指が触れている間だけ true (取り消されても自動で false に戻る)

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
                .updating($touching) { _, active, _ in active = true }
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
        .onChange(of: touching) { active in
            // システムジェスチャーや2本目の指でタッチが取り消されると、onEnded は届かない。
            // そのまま grab が残ると、次のタッチで onBegan が呼ばれず、選択中のノーツの幅が変わらなくなる (onEnded は何度呼んでも安全)
            if !active {
                grab = nil
                onEnded()
            }
        }
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
    @State private var scrollBeats: Double = 1      // ドラッグを始めたときの「帯の高さ全体 = 何拍か」(ズームに比例。ドラッグ中は固定)
    @GestureState private var touching = false      // 指が触れている間だけ true (取り消されても自動で false に戻る)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                FrameCanvas(state: state) { ctx, size in
                    StripRenderer.draw(ctx: ctx, size: size, state: state)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($touching) { _, active, _ in active = true }
                        .onChanged { v in
                            if origin == nil {
                                if state.isPlaying { state.pause() }
                                origin = state.viewBeat
                                // スクロール量はズームに比例させる。ドラッグ中に別の指でズームが変わっても飛ばないよう、始めた時点の値で固定する
                                scrollBeats = state.stripScrollBeats
                            }
                            let ppb = Double(proxy.size.height) / scrollBeats
                            if let o = origin, v.translation.height != 0 {
                                state.scrollViewBeat(o + Double(v.translation.height) / ppb)
                            }
                        }
                        .onEnded { _ in origin = nil }
                )
                .onChange(of: touching) { active in
                    if !active { origin = nil }     // 取り消されて onEnded が届かなくても、次のドラッグが古い位置から始まらないように
                }

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
    /// 六角形の中心の x (このビューの左端から)。本家は、画面の左端から 205pt (左の帯 145pt + 60pt)
    static let hexCenterX: CGFloat = 60

    var body: some View {
        GeometryReader { proxy in
            let H = proxy.size.height
            // 押せる範囲は、従来どおりの縦長の長方形 (本家の六角形だと小さくて、シークバーを誤って触ってしまうため)。
            // 高さは全体の 1/5。ただし、上下の時刻表示 (縦書き) に掛からない範囲に収める (小さい画面用)
            let btnH = min(H / 5, max(60, H - 340))
            let btnW = Self.totalWidth - 2          // レーンとの間に 2pt 空ける
            // 現在位置の白い線は左の帯の端 (145pt) で終わるので、六角形の左の頂点まで少し伸ばす (本家は線が頂点に届く)
            let stubW = Self.hexCenterX - PlayToggleButton.hexWidth / 2 + 1
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    SeekView(state: state, seeking: $seeking).frame(width: Self.seekWidth)
                    TimeLabelView(state: state).frame(width: Self.labelWidth)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: stubW, height: 3)
                    .position(x: stubW / 2, y: H / 2)
                    .opacity(seeking ? 0 : 1)
                    .allowsHitTesting(false)
                // 見た目は六角形 (中心は hexCenterX)、押せる範囲は btnW × btnH の長方形 (左端から)
                PlayToggleButton(state: state, dimmed: seeking,
                                 hitSize: CGSize(width: btnW, height: btnH),
                                 hexOffsetX: Self.hexCenterX - btnW / 2)
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
                        let f = 1.0 - Double(v.location.y / max(1, proxy.size.height * SeekRenderer.regionScale))      // 描画と同じ高さで割る (本家のシークバーは画面より 0.16% 長い)
                        state.seek(fraction: f)
                    }
                    .onEnded { _ in
                        dragging = false
                        state.seekEnd()
                    }
            )
            .onChange(of: touching) { active in
                seeking = active
                if !active && dragging {        // 取り消されて onEnded が届かなかったとき (seekEnd は何度呼んでも安全)
                    dragging = false
                    state.seekEnd()
                }
            }
        }
        .clipped()
    }
}

/// 再生/停止ボタン。見た目は本家と同じ六角形 (外形 100 × 86.6pt、白い縁 2.8pt、中は不透明なグレー) だが、
/// 押せる範囲は hitSize の縦長の長方形 (六角形より大きい。六角形は押せる範囲の飾りで、タッチは受けない)。
/// 通常の Button は「指を離した時」に反応するため、タップの長さぶん(60〜120ms)が必ず遅れる。
/// ここでは指が触れた瞬間に切り替える (停止の体感遅延を減らすため)。
/// 離した時に切り替える従来の動きに戻したい場合は、下の gesture を Button { state.togglePlay() } に置き換える。
/// dimmed (シークバーをドラッグ中) のときは透明にして、タッチも受けない。
struct PlayToggleButton: View {
    @ObservedObject var state: EditorState
    var dimmed: Bool = false
    /// 押せる範囲の大きさ (従来の縦長の長方形)
    var hitSize: CGSize
    /// 六角形の中心の、押せる範囲の中心からのずれ (右が正)
    var hexOffsetX: CGFloat = 0
    @State private var pressed = false
    @GestureState private var touching = false      // 指が触れている間だけ true (取り消されても自動で false に戻る)

    /// 六角形の外形 (正六角形: 頂点から頂点まで 100pt、高さ 100 × √3 / 2 = 86.6pt)。本家の動画から実測
    static let hexWidth: CGFloat = 100
    static let hexHeight: CGFloat = 86.6
    /// 白い縁の太さ
    private static let border: CGFloat = 2.8

    var body: some View {
        // 縁の内側の六角形 (辺からの距離を border だけ縮める。頂点から頂点までは 2 / √3 倍ぶん縮む)
        let innerW = Self.hexWidth - Self.border * 2 * 1.1547
        let innerH = Self.hexHeight - Self.border * 2
        let fillColor = pressed ? Color(red: 0.60, green: 0.62, blue: 0.67) : Color(red: 128.0 / 255.0, green: 131.0 / 255.0, blue: 141.0 / 255.0)
        ZStack {
            // 見た目の六角形。タッチは受けない (押せる範囲は、下の透明な長方形が決める)
            ZStack {
                HexagonShape().fill(Color.white)
                HexagonShape().fill(fillColor).frame(width: innerW, height: innerH)
                PlayGlyph(isPlaying: state.isPlaying)
            }
            .frame(width: Self.hexWidth, height: Self.hexHeight)
            .offset(x: hexOffsetX)
            .allowsHitTesting(false)
            // 押せる範囲 (透明)
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($touching) { _, active, _ in active = true }
                        .onChanged { _ in
                            if !pressed {
                                pressed = true
                                state.togglePlay()
                            }
                        }
                        .onEnded { _ in pressed = false }
                )
        }
        .frame(width: hitSize.width, height: hitSize.height)
        .opacity(dimmed ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: dimmed)
        .allowsHitTesting(!dimmed)
        .onChange(of: touching) { active in
            if !active { pressed = false }      // 取り消されても、次のタップが無視されないように
        }
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

/// 右ボタン列の1つぶん。本家と同じく、枠も文字 (キャプション) も無く、アイコンだけを置く。
/// 押せる範囲は、ボタン列の幅 × 1つぶんの高さ (RightPanel が決める) いっぱいまで広げてある。
/// 選択中はアイコンがシアンになる。badge は、アイコンの右上に重ねる小さな数字 (Order で選んだ数など)
struct PanelButton: View {
    let glyph: String
    var active: Bool = false
    var dimmed: Bool = false
    var badge: String? = nil
    /// 文字 (glyph) の代わりに出すアイコン。引数は今のボタンの文字色 (選択中はシアン)
    var icon: ((Color) -> AnyView)? = nil
    let action: () -> Void

    var body: some View {
        let fg = active ? Color.panelBlue : (dimmed ? Color.white.opacity(0.35) : Color.white)
        Button(action: action) {
            ZStack {
                if let icon = icon {
                    icon(fg)
                } else {
                    // 本家のアイコン (高さ 約36pt) と同じくらいの存在感になるよう、文字を大きく
                    Text(glyph)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(fg)
                }
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.laneCyan)
                        .offset(x: 22, y: -21)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RightPanel: View {
    @ObservedObject var state: EditorState

    // ── 本家 (iPad Air 4 / 横画面 1180 × 820pt) のスクリーンショットから実測した値 ──
    /// ボタン列の幅 (左の細い白線から画面の右端まで。アイコンの中心はその真ん中)
    static let width: CGFloat = 58
    /// アイコンの中心どうしの間隔 (本家: 68.45〜68.6pt)。アイコン自体は高さ 36pt なので、上下に 約32pt の余白が入る
    static let slotPitch: CGFloat = 68.5
    /// 最初のアイコンの中心は画面の上端から 45pt、最後のアイコンの中心は下端から 45pt (= 1つぶんの枠の上下に 10.75pt)
    static let edgeInset: CGFloat = 10.75
    /// 下に固定する 2つ (再生速度 / 分割)
    private static let bottomCount = 2
    /// ポップアップ (再生速度 / 分割のメニュー) の右端が、ボタン列の左端から空ける間隔 (本家: 約 10.8pt)
    static let sideGap: CGFloat = 10.8
    /// EDIT 中の名前 (Back / Note ...) の箱の右端が、ボタン列の左端から空ける間隔 (本家: 約 12.4pt)
    static let labelGap: CGFloat = 12.4
    /// ポップアップの下端が、画面の下端から浮く高さ (本家: 約 2.5pt)
    static let popupBottomInset: CGFloat = 2.5

    /// EDIT 中のアイコンの左に出る名前の濃さ。EDIT に入って 2.6 秒たつと、0.7 秒かけて消える (本家と同じ)
    @State private var labelAlpha: Double = 1
    @State private var labelFade: DispatchWorkItem? = nil

    /// アイコンの中心どうしの間隔。本家の間隔を基本にして、入りきらないとき (EDIT 中のボタンが多いとき・小さい画面) だけ詰める。
    /// 上の並びのボタン数は、EDIT 中は 9 (アイコンが増える。LASSO は More メニューの中)、通常は 6
    static func pitch(forHeight height: CGFloat, editing: Bool) -> CGFloat {
        let topCount = editing ? 9 : 6
        return min(slotPitch, (height - edgeInset * 2) / CGFloat(topCount + bottomCount))
    }

    /// EDIT 中の More ボタン (上から 8 番目) の中心の高さ。More メニューは、これを基準に置く
    static func moreCenterY(forHeight height: CGFloat) -> CGFloat {
        edgeInset + pitch(forHeight: height, editing: true) * 7.5
    }

    var body: some View {
        GeometryReader { proxy in
            let pitch = Self.pitch(forHeight: proxy.size.height, editing: state.editing)
            VStack(spacing: 0) {
                // EDIT / Back で、アイコン列が右へ滑って入れ替わる (入れ替わり中は 2つが重なるので ZStack に入れる)
                ZStack(alignment: .top) {
                    if state.editing {
                        editButtons(pitch: pitch)
                            .transition(.panelSwap)
                    } else if state.metaOpen {
                        metaButtons(pitch: pitch)
                            .transition(.panelSwap)
                    } else {
                        mainButtons(pitch: pitch)
                            .transition(.panelSwap)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: state.editing)
                .animation(.easeInOut(duration: 0.2), value: state.metaOpen)
                Spacer(minLength: 0)
                // 下の2つは本家と同じ絵 (上: 再生速度のメーター / 下: 分割 LFB の定規)。メニューが開いても色は変えない (本家も白のまま)
                PanelButton(glyph: "⏱", icon: { AnyView(PanelIconView(kind: .speed, color: $0)) }) {
                    state.popup = state.popup == .speed ? .none : .speed
                }
                .frame(height: pitch)
                PanelButton(glyph: "▤", icon: { AnyView(PanelIconView(kind: .divide, color: $0)) }) {
                    state.popup = state.popup == .divide ? .none : .divide
                }
                .frame(height: pitch)
            }
            .padding(.vertical, Self.edgeInset)
            .overlay(alignment: .topLeading) {
                labelColumn(pitch: pitch)
                    .animation(.easeInOut(duration: 0.2), value: state.editing)
                    .animation(.easeInOut(duration: 0.2), value: state.metaOpen)
            }
            .overlay(alignment: .bottom) {
                // 保存の状態 (オートセーブ)。下の2つのアイコンの上の余白に、小さく出す (レイアウトには影響しない)
                Text(state.saveStatus)
                    .font(.system(size: 9))
                    .foregroundColor(Color.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(width: Self.width - 4)
                    .padding(.bottom, Self.edgeInset + pitch * CGFloat(Self.bottomCount) + 1)
                    .allowsHitTesting(false)
            }
        }
        // BPM / Effect の右ウィンドウが開いているあいだは、本家と同じくアイコンが見えなくなる (ウィンドウが列の上まで覆う)
        .opacity(state.sidePanel == nil ? 1 : 0)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.35))           // 背景画像とはみ出したノーツが透けて見える
        .overlay(Rectangle().fill(Color.white.opacity(0.6)).frame(width: 1), alignment: .leading)   // 本家は左端に細い白線
        .onChange(of: state.editing) { editing in
            restartLabelTimer(editing)
        }
        .onChange(of: state.metaOpen) { open in
            restartLabelTimer(open)
        }
    }

    /// EDIT 中のアイコンの左に出る名前 (上から、editButtons の並びと同じ順)
    private var editLabels: [String] {
        ["Back", "Note", "Wipe", state.slideDraft != nil ? "Done" : "Slide", "Remove",
         "Order", "Adv.", "More", "Undo / Redo"]
    }

    /// META 中のアイコンの左に出る名前 (上から、metaButtons の並びと同じ順)
    private var metaLabels: [String] { ["Back", "Information", "More", "Review", "Quit"] }

    /// 名前の列。ボタン列の左端のすぐ左 (レーンの上) に、右そろえで並ぶ。タッチは下のレーンへ通す
    @ViewBuilder
    private func labelColumn(pitch: CGFloat) -> some View {
        if state.editing || state.metaOpen {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array((state.editing ? editLabels : metaLabels).enumerated()), id: \.offset) { entry in
                    PanelEditLabel(text: entry.element)
                        .frame(height: pitch)
                }
            }
            .padding(.top, Self.edgeInset)
            .fixedSize()
            .frame(width: 0, alignment: .trailing)      // 幅 0 の枠の右端にそろえる = 列は、枠の左側へ伸びる
            .offset(x: -Self.labelGap)
            .opacity(labelAlpha)
            .allowsHitTesting(false)
            .transition(.panelSwap)
        }
    }

    /// 名前を出して、しばらくしたら消す
    private func restartLabelTimer(_ editing: Bool) {
        labelFade?.cancel()
        labelFade = nil
        guard editing else { return }
        labelAlpha = 1
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.7)) { labelAlpha = 0 }
        }
        labelFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    private func mainButtons(pitch: CGFloat) -> some View {
        VStack(spacing: 0) {
            PanelButton(glyph: "✎", icon: { AnyView(PanelIconView(kind: .edit, color: $0)) }) {
                state.popup = .none
                state.editing = true
            }
            .frame(height: pitch)
            PanelButton(glyph: "♩", icon: { AnyView(PanelIconView(kind: .bpm, color: $0)) }) {
                state.openSidePanel(.bpm)
            }
            .frame(height: pitch)
            // scroll / jump (BPM の下)。アイコンは未作成で文字のまま
            PanelButton(glyph: "✦") { state.openSidePanel(.effect) }
                .frame(height: pitch)
            // TEST のアイコンは、本家の 3番目 (カチンコ)
            PanelButton(glyph: "▶︎|", icon: { AnyView(PanelIconView(kind: .test, color: $0)) }) {
                state.startTestPlay()
            }
            .frame(height: pitch)
            // META: 押すと右ボタン列が Back / Information / More / Quit に入れ替わる (EditorState+Meta.swift)
            PanelButton(glyph: "≡", icon: { AnyView(PanelIconView(kind: .meta, color: $0)) }) {
                state.openMetaMenu()
            }
            .frame(height: pitch)
            // SETTING: BPM / Effect と同じ、右から滑って入るウィンドウ (SideWindow.swift)
            PanelButton(glyph: "⚙︎",
                        icon: { AnyView(PanelIconView(kind: .setting, color: $0)) }) {
                state.openSidePanel(.setting)
            }
            .frame(height: pitch)
        }
    }

    /// META を押した後の列。本家の 6 つのうち、使う Information / More / Quit だけ (階層なし)。More と Quit の間に、自作の Review
    private func metaButtons(pitch: CGFloat) -> some View {
        VStack(spacing: 0) {
            PanelButton(glyph: "←", icon: { AnyView(PanelIconView(kind: .back, color: $0)) }) {      // Back
                state.closeMetaMenu()
            }
            .frame(height: pitch)
            PanelButton(glyph: "i", icon: { AnyView(InfoIcon(color: $0)) }) {      // Information (右ウィンドウ)
                state.openSidePanel(.information)
            }
            .frame(height: pitch)
            PanelButton(glyph: "•••", icon: { AnyView(PanelIconView(kind: .more, color: $0)) }) {      // More: すぐ mcz を共有
                state.shareMCZNow()
            }
            .frame(height: pitch)
            PanelButton(glyph: "□", icon: { AnyView(ReviewIcon(color: $0)) }) {      // Review: 多重ノーツを探して、いちばん早い拍へ飛ぶ (無ければ「0 issue found」)
                state.reviewChart()
            }
            .frame(height: pitch)
            PanelButton(glyph: "⏻", icon: { AnyView(PowerIcon(color: $0)) }) {      // Quit: すぐ保存して閉じる
                state.quitEditor()
            }
            .frame(height: pitch)
        }
    }

    /// Slide のアイコン。スライド作成中 (始点を置いたあと) は「完」の文字になるので、アイコンは出さない
    private func slideIconBuilder() -> ((Color) -> AnyView)? {
        if state.slideDraft != nil { return nil }
        return { AnyView(PanelIconView(kind: .slide, color: $0)) }
    }

    private func editButtons(pitch: CGFloat) -> some View {
        let slideIcon = slideIconBuilder()
        return VStack(spacing: 0) {
            PanelButton(glyph: "←", icon: { AnyView(PanelIconView(kind: .back, color: $0)) }) {      // Back
                state.advOpen = false
                state.stopInteractivePlugin()
                if state.tool == .plugin { state.tool = .unselected }
                state.editing = false
                state.tool = .unselected
                state.selectedIDs = []
                state.ghost = nil
                state.popup = .none
            }
            .frame(height: pitch)
            // 選択中のアイコンをもう一度タップすると、未選択に戻る (未選択 = レーンの上下スライド / ピンチだけ)
            PanelButton(glyph: "▬", active: state.tool == .note,
                        icon: { AnyView(PanelIconView(kind: .note, color: $0)) }) { state.toggleTool(.note) }      // Note
                .frame(height: pitch)
            PanelButton(glyph: "◆", active: state.tool == .wipe,
                        icon: { AnyView(PanelIconView(kind: .wipe, color: $0)) }) { state.toggleTool(.wipe) }      // Wipe
                .frame(height: pitch)
            // スライド作成中 (始点を置いたあと) は「完」になり、押すとその始点の seg 配置を終える
            PanelButton(glyph: state.slideDraft != nil ? "完" : "⌇", active: state.tool == .slide, icon: slideIcon) {      // Slide
                if state.slideDraft != nil { state.finishSlide() } else { state.toggleTool(.slide) }
            }
            .frame(height: pitch)
            // 選択中のノーツがあれば、それを削除する。何も選択していなければ Remove ツールの ON/OFF (タップで1個ずつ消す)
            PanelButton(glyph: "✕", active: state.tool == .remove,
                        icon: { AnyView(PanelIconView(kind: .remove, color: $0)) }) { state.removeButtonTapped() }      // Remove
                .frame(height: pitch)
            // 「順番に選択」: スライドをタップした順に番号を付ける。結合系プラグイン (折り返し敷など) が、この順番で結合する。
            // ツールを離れても順番は残る (右上の数字が、選んだ数)。空きをタップするとリセット
            PanelButton(glyph: "①②", active: state.tool == .order,      // Order
                        badge: state.orderIDs.isEmpty ? nil : "\(state.orderIDs.count)",
                        icon: { AnyView(OrderIcon(color: $0)) }) {
                state.toggleTool(.order)
                if state.tool == .order {
                    state.showToast("スライドをタップした順に番号を付けます (空きをタップでリセット)")
                }
            }
            .frame(height: pitch)
            // Lua プラグインのメニュー。開くとレーンが細くなり、再生ボタンとレーンの間にプラグインの一覧が出る
            PanelButton(glyph: "λ", active: state.advOpen) {      // Adv.
                state.popup = .none
                withAnimation(.easeInOut(duration: 0.22)) { state.advOpen.toggle() }
            }
            .frame(height: pitch)
            PanelButton(glyph: "•••",      // More
                        active: state.popup == .more || state.tool == .selectRange || state.tool == .lasso || state.tool == .slideModify,
                        icon: { AnyView(PanelIconView(kind: .more, color: $0)) }) {
                state.popup = state.popup == .more ? .none : .more
            }
            .frame(height: pitch)
            HStack(spacing: 0) {
                PanelButton(glyph: "↶", dimmed: state.undoCount == 0) { state.undo() }      // Undo
                    .disabled(state.undoCount == 0)
                PanelButton(glyph: "↷", dimmed: state.redoCount == 0) { state.redo() }      // Redo
                    .disabled(state.redoCount == 0)
            }
            .frame(height: pitch)
        }
    }
}

// MARK: - 画面の比率への対応 (設計画面)

/// エディタの寸法 (左の帯 145pt・右ボタン列 58pt・フォント・ノーツの太さなど) は、すべて iPad Air 4 の横画面 (高さ 820pt) を基準に決めてある。
/// そのまま別の比率の画面 (4:3 / 16:9 / 16:7 など) に出すと、高さが違う分だけ帯やボタンの比率が崩れる。
/// そこで、画面の高さが 820pt になるように全体を拡大・縮小 (倍率 s = 画面の高さ ÷ 820) した「設計画面」の上に UI を置く。
///   - 設計画面の高さは常に 820pt。幅は 820 × (画面の幅 ÷ 画面の高さ) pt (iPad Air 4 なら 1180pt、4:3 なら 約 1093pt、16:9 なら 約 1458pt、16:7 なら 約 1875pt)
///   - 左の帯・シークバー・右のボタン列は、どの比率でも高さに対する大きさが同じ。余った (足りない) 横幅は、レーンが吸収する
///   - タッチの座標も設計画面の座標で届くので、中のコードは画面の大きさを気にしなくてよい
enum DesignScreen {
    /// 基準にした画面の高さ (iPad Air 4 の横画面)
    static let height: CGFloat = 820

    /// 実際の画面の高さ → 設計画面との倍率
    static func scale(forHeight h: CGFloat) -> CGFloat {
        max(h, 1) / height
    }
}

struct DesignCanvas<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let s = DesignScreen.scale(forHeight: geo.size.height)
            content
                .frame(width: geo.size.width / s, height: DesignScreen.height)
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

// MARK: - 画面全体

struct EditorView: View {
    @ObservedObject var state: EditorState

    /// 画面全体の座標系の名前。LaneView が「自分の左端が画面の左端からどれだけ右か」を知るために使う
    static let rootSpace = "editorRoot"

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
            // レーンは、左の帯・シークバー・Adv. メニュー・右のボタン列より下の層 (zIndex -1) に置く。
            // 枠 (レーンの幅) からはみ出したノーツが、それらの下に透けて見えるようにするため (描画は LaneView 側で枠の外まで広げている)
            LaneView(state: state)
                .zIndex(-1)
            RightPanel(state: state)
        }
        .coordinateSpace(name: Self.rootSpace)
        .background(EditorBackground(state: state))      // 背景画像 (無いときは黒)。ノーツ・レーン・帯は透明に描いて、これを透かす
        .ignoresSafeArea(.keyboard, edges: .bottom)      // 数値入力のキーボードで、エディタ全体が縮まないように
        .overlay(popupLayer)
        .overlay(PluginDialogLayer(state: state))
        .overlay(gridDialogLayer)
        .overlay(SidePanelLayer(state: state))           // BPM list / Effect list / Information / SETTING: 右からスライドして出る (トーストより下の層)
        .overlay(toastLayer, alignment: .bottom)
        .overlay(ReviewNoticeLayer(tick: state.reviewNoticeTick), alignment: .top)    // review の「0 issue found」(画面の上に一瞬だけ)
        .alert("分割 (1/n)", isPresented: $showInput) {
            TextField("2〜1024", text: $inputText)
                .keyboardType(.numberPad)
            Button("OK") { commitInput() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("n を 2〜1024 の整数で (例: 48 → 1/48)")
        }
        .alert("Malody側でファイルが変更されています", isPresented: $state.diskConflict) {
            Button("Malody側の内容を読み込む") { state.resolveConflictLoadDisk() }
            Button("このエディタの内容で上書き", role: .destructive) { state.resolveConflictOverwrite() }
        } message: {
            Text("このエディタを開いている間に、ほかのアプリ (Malody など) が譜面ファイルを書き換えました。上書きするとその編集が消えるので、保存を止めています。どちらを使っても、もう一方の内容はアプリ内に控えを残します。")
        }
        .fullScreenCover(item: $state.testLaunch) { launch in
            TestPlayScreen(launch: launch) { state.testLaunch = nil }
        }
    }

    /// Adv. メニューの今の幅 (EDIT 中に開いているときだけ。閉じているときは 0)
    private var advWidth: CGFloat {
        (state.editing && state.advOpen) ? AdvPanel.width : 0
    }

    /// Grid settings のダイアログ。シートと違って、下からせり上がる動きがなく、押した瞬間に出る
    @ViewBuilder
    private var gridDialogLayer: some View {
        if state.showGridDialog {
            GridSettingsDialog(state: state)
                .transition(.identity)
        }
    }

    /// 再生速度 / 分割 / More のメニュー。
    /// 層そのものは常に EditorView に載せたままにして、開いていないあいだは「タッチを受けない」だけにする (SidePanelLayer と同じ作り)。
    /// 以前は、メニューを閉じるたびに画面いっぱいの層ごと取り外していて、Lasso / Time range を選んだ直後の
    /// 最初のレーンのタッチが効かないことがあった
    private var popupLayer: some View {
        GeometryReader { proxy in
            let isMore = state.popup == .more
            ZStack(alignment: isMore ? .topTrailing : .bottomTrailing) {
                if state.popup != .none {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.popup = .none }
                    popupBody
                        .padding(.trailing, RightPanel.width + RightPanel.sideGap)
                        // 本家は、再生速度も分割も、メニューの下端が画面の下端のすぐ上にそろう。
                        // More だけは上から: 上端が、More ボタンの中心より 263pt 上 (自作は More ボタンが本家より下なので、その分メニューも下がる)
                        .padding(isMore ? Edge.Set.top : Edge.Set.bottom,
                                 isMore ? moreMenuTop(height: proxy.size.height) : RightPanel.popupBottomInset)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(state.popup != .none)
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

    /// 再生速度 / 分割のメニュー。大きさ・濃さは本家の動画から実測:
    /// 幅 57.8pt、1行 51.6pt、上下の余白 10.4pt、黒の 50% (下の譜面が透ける)、白い細い縁 (白 70%)
    private static let popupWidth: CGFloat = 57.8
    private static let popupRowHeight: CGFloat = 51.6
    private static let popupPad: CGFloat = 10.4

    private func popupList(_ items: [PopupItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { entry in
                Button(action: entry.element.action) {
                    Text(entry.element.title)
                        .font(PanelFont.menu(29))
                        .foregroundColor(entry.element.selected ? Color.panelBlue : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 3)
                        .frame(width: Self.popupWidth, height: Self.popupRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Self.popupPad)
        .background(Color.black.opacity(0.5))
        .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1.2))
    }

    // ── More メニュー (本家の画面収録から実測) ──
    // 幅 275pt、1行 45.6pt、上下の余白 2pt。黒 50% の半透明 (下の譜面・背景が透ける) + 白の細い縁。
    // アイコンの原点はメニューの左端から 21.5pt、文字の左端は 54.5pt。文字の大きさは、本家の「S」の高さ (15.5pt) に合わせている。
    private static let moreWidth: CGFloat = 275
    private static let moreRowHeight: CGFloat = 45.6
    private static let morePad: CGFloat = 2
    private static let moreTextX: CGFloat = 54.5
    /// 本家は、メニューの上端が More ボタンの中心より 263pt 上にある
    private static let moreTopAboveButton: CGFloat = 263
    private static let moreRowCount = 9

    /// More メニューの上端の高さ (画面の上端から)。画面の下にはみ出すときだけ、はみ出さない位置まで上げる
    private func moreMenuTop(height: CGFloat) -> CGFloat {
        let top = RightPanel.moreCenterY(forHeight: height) - Self.moreTopAboveButton
        let menuHeight = Self.moreRowHeight * CGFloat(Self.moreRowCount) + Self.morePad * 2
        return max(4, min(top, height - menuHeight - 4))
    }

    private var moreList: some View {
        VStack(spacing: 0) {
            moreItem("Copy", icon: .copy, dim: state.selectedIDs.isEmpty) { state.popup = .none; state.copySelection() }
            moreItem("Paste", icon: .paste, dim: state.clip.isEmpty) { state.popup = .none; state.paste() }
            moreItem("Time range", icon: .timeRange, active: state.tool == .selectRange) {
                state.popup = .none
                state.beginSelectRange()
            }
            // 指でなぞって囲んだ範囲のノーツを、まとめて選択に追加する (お絵描きソフトの投げ縄)。Time range と同じ「選択の道具」。
            // もう一度選ぶと未選択に戻る (選択したノーツは残る)
            moreItem("Lasso", icon: .lasso, active: state.tool == .lasso) {
                state.popup = .none
                state.toggleTool(.lasso)
                if state.tool == .lasso {
                    state.showToast("指でなぞって囲んだノーツを選択に追加します (タップで解除)")
                }
            }
            moreItem("Flip notes horizontal", icon: .flip) { state.popup = .none; state.flipHorizontal() }
            moreItem("Grid settings", icon: .grid) { state.popup = .none; state.showGridDialog = true }
            moreItem("Slide modify", icon: .slideModify, active: state.tool == .slideModify) {
                state.popup = .none
                state.tool = .slideModify
            }
            moreItem("Slide to Wipe", icon: .slideToWipe) { state.popup = .none; state.slideToWipe() }
            moreItem("Wipe to Slide", icon: .wipeToSlide) { state.popup = .none; state.wipeToSlide() }
        }
        .padding(.vertical, Self.morePad)
        .frame(width: Self.moreWidth, alignment: .leading)
        .background(Color.black.opacity(0.5))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.75), lineWidth: 0.7))
    }

    /// 選択中のツール (Time range / Lasso / Slide modify) は、右ボタン列と同じ青。使えない項目 (選択なし / クリップなし) は薄く
    private func moreItem(_ t: String, icon: MoreMenuIconKind, active: Bool = false, dim: Bool = false,
                          action: @escaping () -> Void) -> some View {
        let fg = active ? Color.panelBlue : (dim ? Color.white.opacity(0.4) : Color.white)
        return Button(action: action) {
            ZStack(alignment: .leading) {
                MoreMenuIcon(kind: icon, color: fg)
                    .frame(width: 64, height: Self.moreRowHeight)
                Text(t)
                    .font(PanelFont.label(22))
                    .foregroundColor(fg)
                    .lineLimit(1)
                    .padding(.leading, Self.moreTextX)
            }
            .frame(width: Self.moreWidth, height: Self.moreRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let t = state.toast {
            Text(t)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.15).opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 60)
                .allowsHitTesting(false)
        }
    }
}
