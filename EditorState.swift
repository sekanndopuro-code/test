import SwiftUI
import AVFoundation
import UIKit
import ImageIO

enum EditTool: Equatable {
    case unselected                      // どのツールも選んでいない (レーンの上下スライド/ピンチだけできる)
    case note, wipe, slide, remove, lasso, order, plugin, selectRange, slideModify

    /// Note / Wipe / Slide (配置 + 既存ノーツの選択・移動ができるツール)
    var isPlacement: Bool { self == .note || self == .wipe || self == .slide }
}

/// レーンを触っている間の段階
enum LanePhase {
    case began, changed, ended
}

/// 1回のタッチ (指を置いてから離すまで) が何をしているか
enum LaneDragMode {
    case idle
    case place          // 空きスペースから始めた → 従来どおり配置
    case ignore         // 選択解除に使ったタッチ / 取り消されたタッチ (何もしない)
    case pendingMove    // ノーツに触れた直後 (動かせば移動、動かさず離せば選択のON/OFF)
    case moving         // 選択中のノーツを移動中
    case legacy         // Remove / Select range / Slide modify (タップだけ)
    case segDrag        // Slide modify: 選択中のスライドの seg (点) に触れた (動かせば移動)
    case lasso          // LASSO: 指でなぞって囲んだ範囲のノーツを選択に追加する
    case plugin         // 操作型プラグイン: タッチを OnClick / OnDragStart / OnDragMove / OnDragEnd に渡す
}

enum EditPopup: Equatable {
    case none, speed, divide, more
}

/// 右側からスライドして出るウィンドウ (BPM list / Effect list / Information / SETTING)。シートではなく EditorView に重ねる (SideWindow.swift)
enum SidePanel {
    case bpm
    case effect
    case information      // META → Information (曲名・作者・オフセットなど)
    case setting          // SETTING (音量・各種チェックボックス)
}

/// 作成中のスライド (Slide ツール)。1回目のタップ = 始点、2回目以降のタップ = seg。
/// 最初の seg を置くまでは、始点は譜面に入れない (画面にはゴーストで出る)。最初の seg を置いた時点で noteID のノーツとして譜面に入る
struct SlideDraft {
    var beat: Beat
    var x: Int
    var w: Int
    let noteID: NoteID = NoteIDGen.next()
}

/// 配置前のプレビュー表示用
struct Ghost {
    var tool: EditTool
    var beat: Beat
    var x: Int
    var w: Int
    var endBeat: Beat? = nil
    var endX: Int? = nil
}

/// レーン座標系 (x: 0...255 / beat <-> 画面座標)
struct LaneGeo {
    var W: CGFloat
    var H: CGFloat
    var viewBeat: Double      // 再生ライン(シアンの横棒)の位置の拍
    var ppb: Double           // 1拍あたりのピクセル

    // 本家 (iPad Air 4) の縦線を実測した値: レーンの左端 = ビューの左端 + 25.2pt、右端 = ビューの右端 - 10.2pt (幅 837.6pt)。
    // (ビューの幅 873pt = 画面 1180 - 左の帯 145 - シークバーと時刻 104 - 右のボタン列 58)
    var trackL: CGFloat { 25.2 }
    var trackW: CGFloat { max(10, W - 35.4) }
    var playY: CGFloat { H * 0.9134 }     // 再生ライン (シアンの横棒)。本家は画面の高さの 91.3% (iPad Air 4 で 749 / 820pt)

    func px(_ x: Double) -> CGFloat { trackL + CGFloat(x / 255.0) * trackW }
    func xOf(_ p: CGFloat) -> Double { Double((p - trackL) / trackW) * 255.0 }
    func py(_ b: Double) -> CGFloat { playY - CGFloat((b - viewBeat) * ppb) }
    func beatOf(_ y: CGFloat) -> Double { viewBeat + Double(playY - y) / ppb }
}

final class EditorState: ObservableObject {
    static let speeds: [Double] = [1.0, 0.75, 0.5, 0.25, 0.1]
    static let divides: [Int] = [2, 3, 4, 6, 8, 12, 16, 24, 32]
    static let speedRange = 0.1...1.0            // 再生速度の範囲 (一覧の値だけを使う。数値入力はない)
    static let divideRange = 2...1024            // 分割 1/n の n (入力もこの範囲)
    static let zoomCount = 17          // 0...15 が通常16段階、16 が細部用(1/32拍)

    // MARK: 譜面データ
    @Published var chart: ChartData
    private(set) var timeMap: TimeMap
    /// 曲の長さ (秒)。譜面・BPM・曲が変わったあとの最初の読み出しで、まとめて計算し直す (編集のたびには計算しない)
    var totalSec: Double {
        if totalDirty { computeTotal() }
        return totalCache
    }

    // MARK: 表示・操作の状態
    @Published var viewBeat: Double = 0 {
        didSet { if viewBeat != oldValue { scheduleWarm() } }   // 位置が落ち着いたら、次の再生の下ごしらえをしておく
    }
    @Published var isPlaying = false
    @Published var zoomLevel: Double = 8     // 0...16。整数のときは従来の16段階と同じ。ピンチ中は小数になる
    @Published var snapDen = 4
    @Published var playSpeed = 1.0
    @Published var editing = false
    @Published var tool: EditTool = .unselected {
        didSet {
            if tool == oldValue { return }
            ghost = nil
            if oldValue == .slide { slideDraft = nil }      // Slide ツールを離れたら、作成中のスライドは終わり (置いた seg は残る)
            // Remove に切り替えたら選択は解除する (タップで消すツールなので、赤いノーツが残ると紛らわしい)。
            // 未選択 / Time range / Slide modify では選択を残す (パン・ズームしてからコピー・貼り付け・変換できるように)
            if tool == .remove && !selectedIDs.isEmpty { selectedIDs = [] }
            // Time range の始点・終点の表示は、Time range を抜けたら消す
            if oldValue == .selectRange { rangeStart = nil; rangeEnd = nil }
            // LASSO を抜けたら、なぞっている途中の線は消す (選択は残る)
            if oldValue == .lasso { lassoPoints = [] }
            // Slide modify を抜けたら、編集中のスライドは外す (選択は残る)。
            // 入るとき、選択がスライド1つだけなら、それをそのまま編集対象にする
            if oldValue == .slideModify { modifySlideID = nil }
            // 操作型プラグインのツールを離れたら、そのプラグインは終わり (OnDeactive を呼んで、画像も消す)
            if oldValue == .plugin && tool != .plugin { stopInteractivePlugin() }
            if oldValue == .slideModify || tool == .slideModify { modifySegIndex = nil }
            if tool == .slideModify, selectedIDs.count == 1, let id = selectedIDs.first,
               let ni = indexOfNote(id: id), chart.notes[ni].isSlide {
                modifySlideID = id
            }
        }
    }
    @Published var slideDraft: SlideDraft? = nil     // 作成中のスライド (nil = 作成中でない)
    @Published var selectedIDs: Set<NoteID> = []     // 選択中のノーツ (赤く表示)
    @Published var orderIDs: [NoteID] = []           // 「順番に選択」(Order) で選んだスライド。タップした順。結合系プラグインがこの順番を使う
    @Published var modifySlideID: NoteID? = nil      // Slide modify で編集中のスライド (選ぶと selectedIDs もそのスライドだけになる)
    @Published var modifySegIndex: Int? = nil        // Slide modify で掴んでいる点 (seg)。ドラッグ中だけ入る (白い輪で目印を出す)
    @Published var popup: EditPopup = .none
    @Published var gridLines = 16
    @Published var gridAlign = true
    @Published var widthUnits = 64
    @Published var lassoPoints: [CGPoint] = []       // LASSO でなぞっている途中の線 (レーン内の画面座標。指を離したら空に戻る)
    @Published var rangeStart: Beat? = nil
    @Published var rangeEnd: Beat? = nil
    @Published var clip: [Note] = []

    // MARK: Adv. (Lua プラグイン)
    @Published var advOpen = false                   // Adv. メニューを開いているか (開くとレーンが右端を固定したまま左から縮む)
    @Published var pluginRunning = false             // プラグインを実行中か
    @Published var pluginLog = ""                    // 直近の実行で print() された内容
    @Published var pluginDialog: PluginDialog? = nil // プラグインが出した ShowMessage / GetUserInput の表示 (出ている間、プラグインは待っている)
    var pluginBridge: PluginBridge? = nil
    // 操作型プラグイン (PluginType 2。例: GizaSlide)
    @Published var activePluginID: String? = nil     // アクティブな操作型プラグイン (Adv. メニューの行に ON と出る)
    @Published var pluginSprites: [PluginSprite] = [] // プラグインが AddSprite でレーンの上に出している画像
    var pluginSession: PluginSession? = nil
    var pluginDragStarted = false                    // いまのタッチで、OnDragStart を呼んだか
    @Published var ghost: Ghost? = nil
    @Published var toast: String? = nil
    @Published var saveStatus = "保存済み"
    @Published var metaOpen = false           // META を押した後の右ボタン列 (Back / Information / More / Review / Quit)。EDIT と同じく、アイコン列が入れ替わる
    @Published var reviewNoticeTick = 0       // review で重なりが見つからなかった回数。増えるたびに、画面の上に「0 issue found」が一瞬だけ出る (ReviewNotice.swift)
    @Published var sidePanel: SidePanel? = nil    // BPM / Effect / Information / SETTING の右ウィンドウ。出し入れは openSidePanel / closeSidePanel (横から滑って一瞬で出入りする)
    @Published var showGridDialog = false     // Grid settings のダイアログ (シートではなく EditorView の上に重ねる。アニメーションなしで一瞬で出る)
    @Published var testLaunch: TestPlayLaunch? = nil
    @Published var playInfo = ""          // 直近の再生開始に掛かった時間 (SETTING に表示する診断用)
    @Published var undoCount = 0
    @Published var redoCount = 0

    // MARK: SETTING (音量。次回起動時も保存される。ウィンドウは sidePanel = .setting)
    @Published var musicVolume: Double = 1.0 {          // 曲の音量 0...1
        didSet {
            UserDefaults.standard.set(musicVolume, forKey: "editor.musicVolume")
            applyVolumes()
        }
    }
    @Published var noteVolume: Double = 0.8 {           // ノーツサウンドの音量 0...1 (0 でキー音オフ)
        didSet {
            UserDefaults.standard.set(noteVolume, forKey: "editor.noteVolume")
            applyVolumes()
        }
    }

    // 長押しで選択解除 (ツール未選択のとき、レーンを押し続けると選択中のノーツが全部解除される)。次回起動時も保存される
    static let holdRange = 1.0...5.0
    @Published var holdDeselectSec: Double = 2.0 {      // 押し続ける秒数 (SETTING で 1.0〜5.0)
        didSet { UserDefaults.standard.set(holdDeselectSec, forKey: "editor.holdDeselectSec") }
    }

    // 遅い速度の再生 (伸ばした音) の調整。次回起動時も保存される
    @Published var sharpStretch = false {               // true: 伸ばす窓を小さくして、ドラムなどの立ち上がりをはっきりさせる (低い音は少しぼやける)
        didSet {
            UserDefaults.standard.set(sharpStretch, forKey: "editor.sharpStretch")
            if engineAudio != nil { scheduleWarm() }
        }
    }

    // スライドの seg を、時系列順でない位置に置くのを許可するか。次回起動時も保存される。初期値はオフ (本家と同じ)
    //   「時系列順でない」= 直前に置いた seg (終点の seg) より前の時間。始点より前 (beat がマイナス) もこれに含まれる
    //   オフ: Slide ツールで終点の seg より前の時間をタップすると、「完」と同じく seg の配置を終える。
    //         Slide modify で終点の seg より前の時間をタップすると、seg は足さずに選択を外す。
    //         seg を縦にドラッグしても、前後の seg の時間を越えない
    //   オン: 時間を行ったり来たりする seg (beat がマイナスも) を置ける
    @Published var allowUnorderedSeg = false {
        didSet { UserDefaults.standard.set(allowUnorderedSeg, forKey: "editor.allowUnorderedSeg") }
    }

    // Grid align がオンのとき、ノーツを動かした後の「中心」を、いつもグリッド線の上に合わせるか。次回起動時も保存される。初期値はオン (本家と同じ)
    //   オン: 動かしたノーツ (スライドなら始点と各 seg) の中心が、動かした先でいちばん近いグリッド線に吸着する。
    //         置いたときの座標と同じ値になる (例: 123 にあったノーツを 64 の線へ持っていくと、ちょうど 64。±1 ずれない)
    //   オフ: 指の移動量を「グリッド1マスの整数倍」に丸めて、動かす前の位置からその量だけずらす (固定変位)
    @Published var gridCenterAlign = true {
        didSet { UserDefaults.standard.set(gridCenterAlign, forKey: "editor.gridCenterAlign") }
    }

    // Slide modify で seg を動かすとき、縦 (時間) 方向にも動かせるようにするか。次回起動時も保存される。初期値はオフ (本家と同じ)
    //   オフ: seg は横 (x) にだけ動く。拍 (時間) は掴んだ時のまま
    //   オン: 縦にも動く (1/n 拍に吸着)
    @Published var allowSegVerticalMove = false {
        didSet { UserDefaults.standard.set(allowSegVerticalMove, forKey: "editor.allowSegVerticalMove") }
    }

    // 上下スクロール / シークバーで動かす「現在位置」(再生ラインの位置) を、分割 (LFB = 1/n 拍) の線にそろえるか。次回起動時も保存される。初期値はオン
    //   オン: レーン・左の帯・シークバーを動かすと、現在位置はいつも 1/n 拍の線の上で止まる。
    //         線から線へ動かせば、時刻表示の差が「分割 1 マスが何 ms か」(分割 1/1 なら 1 拍が何 ms か) になる
    //   オフ: 指の動きに合わせて、線の間にも止まる (これまでと同じ)
    //   再生を止めた位置と、Info / プラグインなどで「この拍へ飛ぶ」ときの位置は、そのまま (飛ばない)
    @Published var snapViewToLFB = true {
        didSet { UserDefaults.standard.set(snapViewToLFB, forKey: "editor.snapViewToLFB") }
    }

    // MARK: ファイル
    let song: SongPCM?                  // 開くときに 1 回だけ展開した曲 (エディタの再生・テストプレイ・曲の長さが、これを共有する)
    let mcURL: URL
    let mcName: String
    let oggData: Data?
    let oggFileName: String
    // 背景画像は、Information の「写真から読み込む」で入れ替えられる (入れ替えると、画面の背景も mcz 書き出しの中身も新しいものになる)
    @Published private(set) var bgData: Data?
    @Published private(set) var bgFileName: String
    var onClose: (() -> Void)?

    // MARK: 背景画像 (最初に読み込んだ画像を、暗くして画面全体に透かして敷く。本家と同じ)
    @Published private(set) var bgImage: UIImage?
    @Published var bgDim: Double = 0.7 {            // 画像の上に重ねる黒の濃さ (SETTING で 0〜95%)
        didSet { UserDefaults.standard.set(bgDim, forKey: "editor.bgDim") }
    }

    /// 背景画像を画面に出せる大きさ (長辺 2048px 以内) で読み込む。大きいファイルでも重くならないように縮める
    private static func makeBackground(_ data: Data?) -> UIImage? {
        guard let data = data, let full = UIImage(data: data) else { return nil }
        let longSide = max(full.size.width, full.size.height) * full.scale
        if longSide <= 2048 { return full }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return full }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return full }
        return UIImage(cgImage: cg)
    }

    // MARK: 再生クロック
    // 画面の時計は2通り。どちらも「そのフレームが画面に出る時刻 (frameHost)」で時刻を決める。
    //  ・エンジン方式 (音源あり。全部の速度): テストプレイと同じ GameAudio が「実際に鳴っているサンプル位置」から時計を作る。
    //    曲と画面が同じ時計なので、そもそもズレない。キー音もこの時計から予約する。
    //  ・壁時計 (音源なし・エンジンを作れなかったとき): 動き出した時刻からの経過時間だけで進める (曲が無いので、合わせる相手がいない)。
    //    以前は、エンジンが使えないときの予備として AVAudioPlayer の方式があったが、曲を SongPCM に展開するようにしたので無くした。
    private var startWall: Double = 0       // 壁時計: 画面の時計が動き出す時刻
    private var startSec: Double = 0
    private var rateNow: Double = 1
    private var engineAudio: GameAudio?     // サンプル位置の時計を持つ曲の再生 (音源があれば全部の速度で使う)
    private var useEngine = false           // 今の再生がエンジン方式か
    private var frameLink: FrameLink?       // 再生中だけ動く (画面に出る時刻を取る)
    private var frameHost = 0.0             // 今フレームが画面に出る時刻 (CACurrentMediaTime 軸)
    private var saveWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    var seekWasPlaying = false

    // MARK: キー音の予約 (再生中のみ使う。@Published にしない = 描画中に触っても安全)
    private var keyTimes: [Double] = []      // ノーツ先頭の譜面時刻(秒)。昇順・同時刻は1つにまとめる
    private var keyDirty = true              // 譜面を触ったら true → 次の tick で作り直す
    private var keyDone = -1.0               // この譜面時刻までのキー音は予約済み
    private var warmWork: DispatchWorkItem?
    /// 異常に遠い位置にあるため、曲の長さの計算から除いた点(ノーツ/seg)の数
    var ignoredBeatCount: Int {
        if totalDirty { computeTotal() }
        return ignoredCache
    }
    private static let keyLookahead = 0.25   // 何秒先まで予約するか (描画が重くてフレームが遅れても、予約は間に合う)
    /// 再生ボタンを押してから、譜面と曲が動き出すまでの余裕 (秒)。短いほど反応が速いが、短すぎると曲の頭出しがずれる
    private static let playLead = 0.05

    // MARK: ノーツ選択・移動中のタッチ状態 (@Published にしない)
    var holdWork: DispatchWorkItem? = nil // 長押しで選択解除のタイマー (指を離す / 動かす / ピンチで取り消す)
    var dragMode: LaneDragMode = .idle
    var dragMoved = false                 // 10pt 以上動かしたか (一度動いたら true のまま)
    var dragTouchedID: NoteID? = nil      // 最初に触れたノーツ
    var dragToggleOnTap = false           // 動かさず離したとき、そのノーツの選択を外すか
    var moveTargets: [(index: Int, orig: Note)] = []   // 移動対象と、移動前の状態
    var moveAnchorBeat: Beat = .zero      // 最初に触れたノーツの移動前の拍 (グリッドに吸着させる基準)
    var moveMinBeat: Beat = .zero         // 移動対象の先頭の拍 (0拍より前へ行かせないため)
    var moveLeftEdge = 0.0                // 移動対象全体の左端 / 右端 (x: 0...255 の範囲から出さないため)
    var moveRightEdge = 255.0
    var moveLastDelta: Beat = .zero       // 直近に反映した移動量 (変わらないときは何もしない)
    var moveLastDX = 0

    // Slide modify: seg (点) をドラッグで動かしている間の状態 (指を離すまでが Undo 1回分)
    var segDragNoteID: NoteID? = nil
    var segDragIndex = 0
    var segDragOrig: Seg? = nil           // 動かす前の seg (元の位置に戻して離したら Undo を積まない)
    var segDragGrab: CGSize = .zero       // 触れた位置から、点の中心までのずれ
    var segDragUndoPushed = false

    // 幅スライダーで選択中のノーツの幅を変えている間の状態 (指を離すまでが Undo 1回分)
    var widthTargets: [(index: Int, orig: Note)] = []
    var widthUndoPushed = false

    private struct Snapshot {
        var notes: [Note]
        var times: [TimePoint]
        var effects: [EffectPoint]
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(chart: ChartData, mcURL: URL, mcName: String, song: SongPCM?,
         oggData: Data?, oggFileName: String, bgData: Data?, bgFileName: String) {
        var c = chart
        c.times.sort { $0.beat < $1.beat }
        self.chart = c
        self.timeMap = TimeMap(c.times)
        self.mcURL = mcURL
        self.mcName = mcName
        self.song = song
        self.oggData = oggData
        self.oggFileName = oggFileName
        self.bgData = bgData
        self.bgFileName = bgFileName
        self.bgImage = Self.makeBackground(bgData)
        if let d = c.testInt("divide"), Self.divideRange.contains(d) {
            self.snapDen = d
        }
        recomputeTotal()
        let ud = UserDefaults.standard
        if let v = ud.object(forKey: "editor.musicVolume") as? Double { self.musicVolume = min(max(v, 0), 1) }
        if let v = ud.object(forKey: "editor.noteVolume") as? Double { self.noteVolume = min(max(v, 0), 1) }
        if let v = ud.object(forKey: "editor.bgDim") as? Double { self.bgDim = min(max(v, 0), 0.95) }
        if let v = ud.object(forKey: "editor.sharpStretch") as? Bool { self.sharpStretch = v }
        if let v = ud.object(forKey: "editor.allowUnorderedSeg") as? Bool {
            self.allowUnorderedSeg = v
        } else if let v = ud.object(forKey: "editor.allowNegativeSeg") as? Bool {
            self.allowUnorderedSeg = v          // 前の版の設定「beatがマイナスのsegを置くのを許可する」の値を引き継ぐ
        }
        if let v = ud.object(forKey: "editor.allowSegVerticalMove") as? Bool { self.allowSegVerticalMove = v }
        if let v = ud.object(forKey: "editor.snapViewToLFB") as? Bool { self.snapViewToLFB = v }
        if let v = ud.object(forKey: "editor.gridCenterAlign") as? Bool { self.gridCenterAlign = v }
        if let v = ud.object(forKey: "editor.holdDeselectSec") as? Double {
            self.holdDeselectSec = min(max(v, Self.holdRange.lowerBound), Self.holdRange.upperBound)
        }
        prepareEngineAudio()
        applyVolumes()
        KeySound.shared.prepare()
        scheduleWarm()
        if ignoredBeatCount > 0 {
            showToast("異常に遠い位置の点が\(ignoredBeatCount)個あります(曲の長さの計算から除外)")
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveNow()
        }
    }

    deinit {
        frameLink?.stop()
        engineAudio?.shutdown()
        pluginBridge?.cancel.cancel()
        pluginDialog?.finish(nil)       // 待っているプラグインがあれば、解放する
    }

    /// サンプル位置の時計つきの再生 (テストプレイと同じ GameAudio)。曲は開くときに展開済みの SongPCM を読むだけで、
    /// ここでファイルを書いたり、デコードし直したりはしない。
    /// 作れなかったとき (オーディオエンジンが起動できないなど) は nil のままにして、音なし (壁時計) で動かす
    private func prepareEngineAudio() {
        guard engineAudio == nil, let s = song else { return }
        do {
            let g = try GameAudio(song: s)
            g.setVolume(Float(musicVolume))
            engineAudio = g
        } catch {
            engineAudio = nil
            showToast("オーディオエンジンを起動できなかったので、音なしで動かします")
        }
    }

    // MARK: - 時間・座標

    /// ズーム段階 → レーンに表示する拍数。0...15 は従来と同じ、15〜16 の間は 1拍 → 1/32拍 をなめらかにつなぐ
    static func visibleBeats(forLevel z: Double) -> Double {
        let zz = max(0.0, min(Double(zoomCount - 1), z))
        if zz <= 15.0 { return 16.0 * pow(1.0 / 16.0, zz / 15.0) }
        return pow(1.0 / 32.0, zz - 15.0)
    }

    /// visibleBeats(forLevel:) の逆変換 (ピンチ操作用)
    static func level(forVisibleBeats v: Double) -> Double {
        let vb = max(1.0 / 32.0, min(16.0, v))
        if vb >= 1.0 { return 15.0 * (1.0 - log(vb) / log(16.0)) }
        return 15.0 + (-log(vb)) / log(32.0)
    }

    var zoomIndex: Int { Int(zoomLevel.rounded()) }
    var visibleBeats: Double { Self.visibleBeats(forLevel: zoomLevel) }

    /// 左の縦長タイムラインは、本家と同じく倍率を固定する (ズームには連動しない)。
    /// 本家の実測: 1拍 = 約 178pt (iPad Air 4 の高さ 820pt で 約 4.6拍)
    var stripBeats: Double { 4.6 }

    /// 左の帯を上下になぞったとき、帯の高さ全体ぶん指を動かすと進む拍数。
    /// 帯の見た目の倍率 (stripBeats) は本家どおり固定のまま、スクロール量だけをズームに比例させる
    /// (= レーンの表示範囲 visibleBeats。拡大するほど細かく、縮小するほど大きく動く)。
    /// 帯の高さ ≒ レーンの高さなので、帯をなぞった距離と、レーンの譜面が動く距離がそろう。
    /// 動きが速すぎる / 遅すぎるときは、ここに倍率 (例: visibleBeats * 0.5) をかけて調整する
    var stripScrollBeats: Double { visibleBeats }

    var zoomLabel: String { zoomIndex >= 16 ? "1/32拍" : "\(zoomIndex + 1)/16" }

    var maxBeat: Double { max(1, timeMap.beat(atSec: totalSec)) }

    /// 曲の長さを「古い」印にするだけ (O(1))。実際の計算は、totalSec / ignoredBeatCount を次に読むときに 1 回だけ行う
    func recomputeTotal() {
        totalDirty = true
        densityDirty = true          // シークバーのノーツ密度は、次に描くときに作り直す
    }

    private var totalCache = 1.0
    private var ignoredCache = 0
    private var totalDirty = true

    private func computeTotal() {
        totalDirty = false
        let audioSec = (song?.duration ?? 0) + Double(chart.offsetMs) / 1000.0
        // 壊れた値 (何億拍も先にある seg など) が1つあるだけで、曲の長さが何万分にもなってしまう。
        // → 「曲の長さ + 60秒」(曲が無いときは3時間) より遠い点(マイナス側も)は、長さの計算から除く。
        //   データそのものは書き換えない (保存時もそのまま)。
        let limitSec = audioSec > 1 ? audioSec + 60.0 : 3.0 * 3600.0
        let limitBeat = timeMap.beat(atSec: limitSec)
        var last = 0.0
        var ignored = 0
        for n in chart.notes {
            let s = n.beat.value
            if s.isFinite && abs(s) <= limitBeat {
                if s > last { last = s }
            } else {
                ignored += 1
                continue
            }
            for g in n.segs {
                let b = s + g.beat.value
                if b.isFinite && abs(b) <= limitBeat {
                    if b > last { last = b }
                } else {
                    ignored += 1
                }
            }
        }
        ignoredCache = ignored
        let noteSec = timeMap.sec(atBeat: last) + 2.0
        totalCache = max(audioSec, noteSec, 1.0)
    }

    // MARK: シークバーのノーツ密度 (本家と同じ 120 本のヒストグラム。計算は SeekDensity.swift)

    private var densityRatios: [Double] = []
    private var densityDirty = true
    private var densityTotal = -1.0

    /// 120 本それぞれの棒の長さの割合 (0...1)。[0] = 曲の頭 (画面では下)。
    /// 譜面・BPM・曲の長さを触ったとき (recomputeTotal) だけ作り直す。毎フレーム呼んでも、中身は使い回すだけ
    func seekDensityRatios() -> [Double] {
        if densityDirty || densityTotal != totalSec || densityRatios.isEmpty {
            let counts = SeekDensity.counts(notes: chart.notes, timeMap: timeMap, totalSec: totalSec)
            densityRatios = SeekDensity.ratios(counts)
            densityTotal = totalSec
            densityDirty = false
        }
        return densityRatios
    }

    /// 画面に出す譜面時刻。再生中は「今フレームが画面に出る時刻」で決まるので、
    /// レーン・縦タイムライン・シークバー・時刻表示のどれを先に描いても、同じフレームでは同じ値になる
    func currentSec() -> Double {
        guard isPlaying else { return timeMap.sec(atBeat: viewBeat) }
        return playSec(atHost: frameHost)
    }

    private func playSec(atHost h: Double) -> Double {
        if useEngine, let a = engineAudio {
            return max(startSec, a.chartTime(atUptime: h))      // 動き出す前 (先読みの50ms) は開始位置で止める
        }
        return startSec + max(0, h - startWall) * rateNow
    }

    func currentBeat() -> Double {
        isPlaying ? timeMap.beat(atSec: currentSec()) : viewBeat
    }

    func geo(_ size: CGSize) -> LaneGeo {
        LaneGeo(W: size.width, H: size.height, viewBeat: currentBeat(), ppb: Double(size.height) / visibleBeats)
    }

    func timeString(_ sec: Double) -> String {
        let s = max(0, sec)
        let ms = Int((s * 1000).rounded())
        return String(format: "%02d:%02d.%03d", ms / 60000, (ms / 1000) % 60, ms % 1000)
    }

    // MARK: - 再生

    /// 再生中、画面の更新ごとに1回だけ呼ばれる (CADisplayLink)。
    /// 時計の更新 → キー音の予約 → 終了判定。Canvas は複数あっても、ここは1フレームに1回だけ
    private func onFrame(_ link: CADisplayLink) {
        guard isPlaying else { return }
        let now = CACurrentMediaTime()
        frameHost = link.targetTimestamp            // 「この更新が画面に出る時刻」で描く (描画にかかった時間の揺れが出ない)
        if useEngine {
            engineAudio?.refreshAnchor()            // 実際に鳴っているサンプル位置で時計を合わせ直す
        }
        scheduleKeySounds(now: now)
        if currentSec() > totalSec + 0.5 {
            DispatchQueue.main.async { [weak self] in self?.pause() }   // リンクのコールバックの中で止めない (pause は何度呼ばれても安全)
        }
    }

    private func startFrameLink() {
        frameLink?.stop()
        frameLink = FrameLink { [weak self] l in self?.onFrame(l) }
    }

    private func stopFrameLink() {
        frameLink?.stop()
        frameLink = nil
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard !isPlaying else { return }
        popup = .none
        let sec = max(0, timeMap.sec(atBeat: viewBeat))
        let rate = playSpeed
        let lead = Self.playLead
        let offSec = Double(chart.offsetMs) / 1000.0
        warmWork?.cancel()
        KeySound.shared.prepare()           // 止めていたキー音ノードを先に起こしておく (時計を始めた後に起こすと開始が引っ掛かる)
        // 先に曲の下ごしらえと再生予約をして、画面の時計はその後で始める
        // (逆順だと、下ごしらえに掛かった分だけ曲が譜面より遅れて始まる)
        if let a = engineAudio {
            useEngine = true
            a.setStretchSize(sharpStretch ? 512 : 1024)
            a.setRate(rate)                                   // 1.0 未満のときは、その速度に伸ばした音を流す (1.0 は曲をそのまま)
            a.begin(chartTime: sec, offsetTotal: offSec)      // 以降の時計は、鳴っているサンプル位置から作られる
            let stretchTag = rate < 1.0 ? "・伸ばした音(\(a.stretchEngine))" : ""
            playInfo = String(format: "再生開始の下ごしらえ %.0f ms (%@%@)", a.lastBeginMs, a.lastBeginWarm ? "先読み済み" : "先読みなし", stretchTag)
        } else {
            useEngine = false                                 // 音源なし (または音声エンジンを作れなかった): 壁時計だけで進める
            playInfo = ""
        }
        startSec = sec
        startWall = CACurrentMediaTime() + lead
        rateNow = rate
        keyDone = sec - 0.000001            // 開始位置ちょうどのノーツも鳴らす
        frameHost = CACurrentMediaTime()
        isPlaying = true
        startFrameLink()
    }

    func pause() {
        guard isPlaying else { return }
        let b = timeMap.beat(atSec: currentSec())     // 最後に画面に出した位置で止める (止めた瞬間に飛ばない)
        stopFrameLink()
        if useEngine, let a = engineAudio {
            // 診断: 再生中に「先に作っておいた音」の残りが最小でいくつまで減ったか。0〜2 だと作成が再生に間に合っていない
            let q = a.queueStats()
            if a.rate < 1.0 {
                if q.min >= 0 {
                    playInfo += String(format: " / 先読みの残り最小 %d/%d", q.min, q.target)
                } else {
                    playInfo += String(format: " / 先読みが目標(%d)に届く前に停止", q.target)
                }
            }
            a.halt()
        }
        KeySound.shared.cancelScheduled()
        isPlaying = false
        viewBeat = min(max(0, b), maxBeat)
    }

    func setViewBeat(_ b: Double) {
        viewBeat = min(max(0, b), maxBeat)
    }

    /// 上下スクロール / シークバーで現在位置を動かすときに使う。
    /// SETTING の「現在位置を分割(LFB)の線にスナップする」がオンなら、いちばん近い 1/n 拍の線 (n = 分割) にそろえる。
    /// 曲の終わりを越える線は使わず、その手前の線にする (終わりの位置は 1/n 拍の線の上とは限らないため)
    func scrollViewBeat(_ b: Double) {
        guard snapViewToLFB, b.isFinite else {
            setViewBeat(b)
            return
        }
        let den = Double(max(1, snapDen))
        var s = (max(0, b) * den).rounded() / den
        let hi = maxBeat
        if s > hi { s = (hi * den).rounded(.down) / den }
        setViewBeat(s)
    }

    /// 曲全体バー: f = 0(曲頭) ... 1(曲末)
    func seekBegin() {
        seekWasPlaying = isPlaying
        if isPlaying { pause() }
    }

    func seek(fraction f: Double) {
        let sec = min(max(0, f), 1) * totalSec
        scrollViewBeat(timeMap.beat(atSec: sec))
    }

    func seekEnd() {
        if seekWasPlaying { play() }
        seekWasPlaying = false
    }

    // MARK: - テストプレイ

    /// 現在の譜面(未保存の編集内容も含む)を MalodySlideTestplayer の中身でプレイする。
    /// 開始位置はエディタで表示中の位置。最初から遊ぶときは先頭へシークしてから押す。
    func startTestPlay() {
        if isPlaying { pause() }
        popup = .none
        do {
            let played = try MalodyChart.make(from: chart)      // 譜面を JSON にして読み直さず、メモリ上の譜面から直接作る
            if played.notes.isEmpty {
                showToast("ノーツがないのでテストできません")
                return
            }
            // 曲は開くときに展開済みの SongPCM を、そのまま共有する (ファイルを書き直したり、デコードし直したりしない)
            var game: GameAudio? = nil
            if let s = song {
                do {
                    game = try GameAudio(song: s)
                    game?.setVolume(Float(musicVolume))
                } catch {
                    showToast("音源を読めなかったので無音でテストします")
                }
            }
            KeySound.shared.prepare()
            let start = max(0, timeMap.sec(atBeat: viewBeat))
            testLaunch = TestPlayLaunch(chart: played, audio: game, startSec: start)
        } catch {
            showToast("テストプレイを開始できませんでした")
        }
    }

    func zoomIn() { zoomLevel = min(Double(Self.zoomCount - 1), zoomLevel.rounded(.down) + 1) }
    func zoomOut() { zoomLevel = max(0, zoomLevel.rounded(.up) - 1) }

    /// ピンチ操作: 開始時の表示拍数 ÷ 拡大率 にする (再生ラインの位置を基準に拡大縮小)
    func pinchZoom(startVisibleBeats: Double, scale: Double) {
        guard scale.isFinite, scale > 0.01 else { return }
        zoomLevel = Self.level(forVisibleBeats: startVisibleBeats / scale)
    }

    /// 再生速度を変える (一覧の値: 1.0 / 0.75 / 0.5 / 0.25 / 0.1)
    func setSpeed(_ v: Double) {
        let nv = min(max(v, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        let was = isPlaying
        if was { pause() }
        playSpeed = nv
        popup = .none
        if was { play() } else { scheduleWarm() }
    }

    /// 分割 1/n の n を変える (2〜1024)
    func setDivide(_ d: Int) {
        let nd = min(max(d, Self.divideRange.lowerBound), Self.divideRange.upperBound)
        snapDen = nd
        chart.setTest("divide", nd)
        popup = .none
        scheduleSave()
    }

    /// 入力欄の文字から分割を決める ("16" でも "1/16" でもよい)。範囲外は 1/2〜1/1024 に丸める
    func applyDivideInput(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("1/") { t.removeFirst(2) }
        guard let v = Int(t) else {
            showToast("分割は 2〜1024 の整数で入力してください")
            return
        }
        setDivide(v)
        if snapDen != v {
            showToast("分割を 1/\(snapDen) にしました (入力できるのは 1/2〜1/1024)")
        }
    }

    // MARK: - Undo / Redo

    func pushUndo() {
        undoStack.append(Snapshot(notes: chart.notes, times: chart.times, effects: chart.effects))
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
    }

    /// 直前の pushUndo を取り消す (結局動かさなかった移動など、何も変わっていないときに使う)
    func dropLastUndo() {
        if undoStack.isEmpty { return }
        undoStack.removeLast()
        undoCount = undoStack.count
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        modifySegIndex = nil                            // 戻すと seg の並びが変わるので、選んでいた点は外す
        redoStack.append(Snapshot(notes: chart.notes, times: chart.times, effects: chart.effects))
        chart.notes = s.notes
        chart.times = s.times
        chart.effects = s.effects
        undoCount = undoStack.count
        redoCount = redoStack.count
        chartChanged()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        modifySegIndex = nil
        undoStack.append(Snapshot(notes: chart.notes, times: chart.times, effects: chart.effects))
        chart.notes = s.notes
        chart.times = s.times
        chart.effects = s.effects
        undoCount = undoStack.count
        redoCount = redoStack.count
        chartChanged()
    }

    /// 譜面を変更した後に必ず呼ぶ (時間テーブル再構築 + オートセーブ予約)
    func chartChanged() {
        pruneSelection()
        timeMap = TimeMap(chart.times)
        keyDirty = true
        scheduleWarm()
        recomputeTotal()
        scheduleSave()
    }

    /// 削除・Undo などで消えたノーツを、選択から外す
    func pruneSelection() {
        if let id = modifySlideID, indexOfNote(id: id) == nil { modifySlideID = nil }
        if let j = modifySegIndex {
            if let i = modifySlideIndex, j < chart.notes[i].segs.count {} else { modifySegIndex = nil }
        }
        if selectedIDs.isEmpty && orderIDs.isEmpty { return }
        // 全ノーツの ID から Set を作る (以前のやり方) のではなく、選択中の ID が全部残っているかを 1 回なぞって調べる。
        // 全部残っていれば (ふつうはこちら) 何も作らず、早めに終わる
        if !selectedIDs.isEmpty, let alive = aliveSubset(of: selectedIDs) { selectedIDs = alive }
        if !orderIDs.isEmpty, let alive = aliveSubset(of: Set(orderIDs)) {
            orderIDs = orderIDs.filter { alive.contains($0) }      // 消えたスライドは順番から外す (番号は詰まる)
        }
    }

    /// ids のうち、いま譜面に残っているものだけの集合。全部残っていれば nil
    private func aliveSubset(of ids: Set<NoteID>) -> Set<NoteID>? {
        var found = Set<NoteID>()
        found.reserveCapacity(ids.count)
        for n in chart.notes where ids.contains(n.id) {
            found.insert(n.id)
            if found.count == ids.count { return nil }
        }
        return found
    }

    // MARK: - ノーツの索引 (NoteIndex.swift)
    // chart.notes が書き換わると notesRevision が増える。索引は、その番号が変わったときだけ作り直す (中身は探すときに作る)

    private var noteIndexCache = NoteIndex()
    private var noteIndexRevision = -1
    private var memoID: NoteID = 0          // 最後に調べた ID と、その位置 (同じ ID を何度も調べる操作を O(1) にする)
    private var memoPos = -1

    private var currentNoteIndex: NoteIndex {
        let rev = chart.notesRevision
        if rev != noteIndexRevision {
            noteIndexCache = NoteIndex()
            noteIndexRevision = rev
        }
        return noteIndexCache
    }

    /// ノーツ ID → chart.notes の添字 (無ければ nil)。`firstIndex(where: { $0.id == id })` の代わり
    func indexOfNote(id: NoteID) -> Int? {
        let ns = chart.notes
        if memoPos >= 0, memoPos < ns.count, memoID == id, ns[memoPos].id == id { return memoPos }
        guard let p = currentNoteIndex.position(ofID: id, in: ns) else { return nil }
        memoID = id
        memoPos = p
        return p
    }

    /// 拍の範囲 [lo, hi] に掛かるノーツの添字 (小さい順)。スライドは seg も含めた範囲で判定する
    func notesOverlapping(lo: Double, hi: Double) -> [Int] {
        currentNoteIndex.indices(lo: lo, hi: hi, in: chart.notes)
    }

    /// いま画面に見えているノーツ (の添字)。ノーツの描画・順番の表示が使う。
    /// 描く側が「はみ出し 24pt まで描く」ので、範囲は少し広めに取る (広い分は描く側が画面外として省く)
    func visibleNoteIndices(_ g: LaneGeo) -> [Int] {
        let ppb = g.ppb
        guard ppb.isFinite, ppb > 0 else { return Array(chart.notes.indices) }
        let margin = 0.05 + 40.0 / ppb
        return notesOverlapping(lo: g.beatOf(g.H) - margin, hi: g.beatOf(0) + margin)
    }

    func metaChanged() {
        scheduleWarm()
        recomputeTotal()
        scheduleSave()
    }

    // MARK: - 保存 / エクスポート

    func scheduleSave() {
        saveStatus = "未保存…"
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveInBackground() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    // 保存は、譜面のコピー (ChartData は値なのでコピーは一瞬) を、別のスレッドで JSON にしてファイルへ書く。
    // 以前はメインスレッドでやっていたので、大きな譜面では、保存の瞬間に画面が止まっていた。
    private static let saveQueue = DispatchQueue(label: "malody.save", qos: .utility)
    private var saveGeneration = 0      // 保存を始めるたびに増やす。古い保存の結果で、新しい表示を上書きしないための目印

    /// 譜面を別のスレッドで保存する (自動保存が使う)。画面は止まらない
    func saveInBackground() {
        saveWork?.cancel()
        saveGeneration += 1
        let gen = saveGeneration
        let snapshot = chart
        let name = mcName
        let url = mcURL
        EditorState.saveQueue.async { [weak self] in
            let status = EditorState.writeChart(snapshot, name: name, url: url)
            DispatchQueue.main.async {
                guard let self = self, self.saveGeneration == gen else { return }
                self.saveStatus = status
            }
        }
    }

    /// 譜面を保存して、書き終わるまで待つ (Quit・書き出し・アプリが裏へ回るとき用。途中の自動保存があれば、その後ろに並ぶ)
    func saveNow() {
        saveWork?.cancel()
        saveGeneration += 1
        let snapshot = chart
        let name = mcName
        let url = mcURL
        saveStatus = EditorState.saveQueue.sync { EditorState.writeChart(snapshot, name: name, url: url) }
    }

    /// 実際の書き込み。どのスレッドからでも呼べる。戻り値は、画面に出す保存の状態
    private static func writeChart(_ chart: ChartData, name: String, url: URL) -> String {
        do {
            let data = try chart.serialized()
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("MalodySlideEditor", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(name))
            do {
                try data.write(to: url)
                return "保存済み"
            } catch {
                return "元ファイルに書込不可(アプリ内に保存)"
            }
        } catch {
            return "保存失敗"
        }
    }

    // MARK: - 背景画像を写真から入れ替える (Information → 背景ファイル → 写真から読み込む)

    /// 写真アプリから選んだ画像を、背景に使える形 (JPEG) にする。重いので、呼ぶ側は別スレッドで呼んでよい。
    /// - すでに JPEG で、向きも正しいものは、元のデータをそのまま使う (再圧縮で画質を落とさない)
    /// - HEIC / PNG などは JPEG (画質 0.9) に変換する。向き (EXIF) は、画像そのものに反映して正しい向きにする
    static func backgroundJPEG(fromPhoto data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let isJPEG = data.count > 3 && data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8 && data[data.startIndex + 2] == 0xFF
        if isJPEG && img.imageOrientation == .up { return data }
        let upright: UIImage
        if img.imageOrientation == .up {
            upright = img
        } else {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = img.scale
            format.opaque = true
            upright = UIGraphicsImageRenderer(size: img.size, format: format).image { _ in
                img.draw(in: CGRect(origin: .zero, size: img.size))
            }
        }
        return upright.jpegData(compressionQuality: 0.9)
    }

    /// 背景画像を、JPEG のデータに入れ替える。すでに読み込んでいる背景は置き換える。
    /// - 背景ファイル名 (mc の meta.background) は、いま書いてある名前を引き継ぐ。拡張子が jpg / jpeg でなければ .jpg に直す (中身が JPEG なので)。名前が空なら bg.jpg
    /// - Quit しても消えないように、画像ファイルとしても残す (`persistBackground`)
    /// - 戻り値: 新しい背景ファイル名 (入れ替えられなければ nil)
    @discardableResult
    func applyBackground(jpeg: Data) -> String? {
        guard let img = Self.makeBackground(jpeg) else {
            showToast("画像を読み込めませんでした")
            return nil
        }
        var name = chart.metaString(["background"]).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = bgFileName.trimmingCharacters(in: .whitespaces) }
        let ext = (name as NSString).pathExtension.lowercased()
        if name.isEmpty {
            name = "bg.jpg"
        } else if ext != "jpg" && ext != "jpeg" {
            name = (name as NSString).deletingPathExtension + ".jpg"
        }
        bgData = jpeg
        bgImage = img
        bgFileName = name
        chart.setMetaString(["background"], name)
        metaChanged()
        let saved = persistBackground(jpeg, name: name)
        showToast(saved ? "背景を写真に入れ替えました (\(name))" : "背景を入れ替えました (\(name))。画像ファイルは保存できませんでした")
        return name
    }

    /// 入れ替えた背景を、画像ファイルとしても書き出す。
    ///  ・mc がアプリ内のフォルダにある (mcz を展開したときなど) → mc と同じフォルダへ (次に開くとき、名前が合えば自動で読み込まれる)
    ///  ・それ以外 (Files アプリの mc など) → Documents/MalodySlideEditor/<mc名>/ へ (他の譜面の画像と名前がぶつからないように、フォルダを分ける)
    private func persistBackground(_ data: Data, name: String) -> Bool {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return false }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let appRoot = docs.appendingPathComponent("MalodySlideEditor", isDirectory: true)
        let mcDir = mcURL.deletingLastPathComponent()
        let dir: URL
        if mcDir.resolvingSymlinksInPath().path.hasPrefix(appRoot.resolvingSymlinksInPath().path + "/") {
            dir = mcDir
        } else {
            let base = (mcName as NSString).deletingPathExtension
            dir = appRoot.appendingPathComponent(base.isEmpty ? "chart" : base, isDirectory: true)
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(leaf), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func exportPackage() throws -> URL {
        saveNow()
        var zip = ZipWriter()
        let base = (mcName as NSString).deletingPathExtension
        let folder = base.isEmpty ? "chart" : base
        zip.add(name: "\(folder)/\(mcName)", data: try chart.serialized())
        if let od = oggData {
            let n = chart.soundFile.isEmpty ? oggFileName : chart.soundFile
            zip.add(name: "\(folder)/\(n)", data: od)
        }
        if let bd = bgData {
            let bn = chart.metaString(["background"])
            zip.add(name: "\(folder)/\(bn.isEmpty ? bgFileName : bn)", data: bd)
        }
        var title = chart.metaString(["song", "title"])
        if title.isEmpty { title = folder }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let safe = title.components(separatedBy: bad).joined(separator: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).mcz")
        try zip.finish().write(to: url, options: .atomic)
        return url
    }

    // MARK: - 小物

    func showToast(_ s: String, seconds: Double = 2.2) {
        toast = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// プラグインからの知らせ用。画面を止めずに出す (文字が長いほど、少し長く出る)
    func showPluginNotice(_ s: String) {
        showToast(s, seconds: min(6.0, 2.2 + Double(s.count) * 0.05))
    }

    func setOffset(_ ms: Int) {
        if isPlaying { pause() }
        chart.offsetMs = ms
        metaChanged()
    }

    // MARK: - 音量 / キー音

    /// 停止中、位置や譜面の変更が少し止まったら、曲の再生位置を先に用意しておく (再生ボタンを押した瞬間の下ごしらえを省くため)。
    /// 曲は展開済みのメモリを読むだけなので、普通の速度ではほとんど要らない。伸ばした音 (0.75倍など) は作るのに時間が掛かるので、これが効く。
    /// 別スレッドで用意するので軽く、0.04秒で動く
    private func scheduleWarm() {
        warmWork?.cancel()
        guard engineAudio != nil else { return }
        let rate = playSpeed
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isPlaying else { return }
            if self.keyDirty { self.rebuildKeyTimes() }      // 譜面を触った後のキー音の表は、止まっている間に作っておく (再生開始のフレームで作ると引っ掛かる)
            let sec = max(0, self.timeMap.sec(atBeat: self.viewBeat))
            let offSec = Double(self.chart.offsetMs) / 1000.0
            self.engineAudio?.setStretchSize(self.sharpStretch ? 512 : 1024)
            self.engineAudio?.setRate(rate)
            self.engineAudio?.warm(chartTime: sec, offsetTotal: offSec)
        }
        warmWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: w)
    }

    func applyVolumes() {
        engineAudio?.setVolume(Float(musicVolume))
        KeySound.shared.volume = Float(noteVolume)
    }

    private func rebuildKeyTimes() {
        var out: [Double] = []
        out.reserveCapacity(chart.notes.count)
        for n in chart.notes {
            out.append(timeMap.sec(atBeat: n.beat.value))
        }
        out.sort()
        var uniq: [Double] = []
        uniq.reserveCapacity(out.count)
        for t in out {
            if let last = uniq.last, t - last < 0.001 { continue }   // 同時押しは1発にまとめる
            uniq.append(t)
        }
        keyTimes = uniq
        keyDirty = false
    }

    /// 再生中、毎フレーム呼ばれる(何度呼ばれても同じ音を二重に予約しない)。
    /// これから keyLookahead 秒以内に来るノーツを、鳴る時刻を指定してオーディオエンジンに渡す。
    /// 時刻の指定なので、フレームの細かさに関係なくサンプル精度で曲と揃う。
    private func scheduleKeySounds(now: Double) {
        guard isPlaying else { return }
        let rate = rateNow
        // どの譜面時刻までを予約するか。エンジン方式は、曲と同じ時計 (サンプル位置) から決める。
        // キー音は出力遅延ぶん早めに鳴らし始める必要があるので、その分だけ先まで見る
        let eng: GameAudio? = useEngine ? engineAudio : nil
        let horizon: Double
        if let a = eng {
            horizon = a.chartTime(atUptime: now + Self.keyLookahead + a.outputLatency)
        } else {
            horizon = startSec + (now + Self.keyLookahead - startWall) * rate
        }
        if horizon <= keyDone { return }
        if noteVolume <= 0.001 {            // 消音中も予約位置だけは進める (戻した時に溜まった分が一気に鳴らないように)
            keyDone = horizon
            return
        }
        if keyDirty { rebuildKeyTimes() }
        if keyTimes.isEmpty { keyDone = horizon; return }

        // keyDone より後ろの最初のノーツを二分探索
        var lo = 0
        var hi = keyTimes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keyTimes[mid] <= keyDone { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < keyTimes.count && keyTimes[i] <= horizon {
            let t = keyTimes[i]
            // 譜面時刻 t が鳴る壁時計の時刻 (レーン上でノーツが再生ラインに触れる瞬間 = 曲のその位置が聞こえる瞬間)。
            // エンジン方式: 画面の時刻は「聞こえる時刻」なので、そこから出力遅延ぶん引いた時刻に鳴らし始める (曲のサンプルと同じ扱い)
            let host: Double
            if let a = eng {
                host = a.uptime(atChartTime: t) - a.outputLatency
            } else {
                host = startWall + (t - startSec) / rate
            }
            if host > now - 0.08 {                  // 大きく遅れてしまった分は捨てる
                KeySound.shared.play(atTime: host)
            }
            i += 1
        }
        keyDone = horizon
    }
}

/// CADisplayLink を使うための小さな入れ物。EditorState は NSObject ではないので、selector を直接は渡せない。
/// stop() を呼ぶまで CADisplayLink がこのオブジェクトを保持する (EditorState の pause / deinit で止める)
final class FrameLink: NSObject {
    private var link: CADisplayLink?
    private var handler: ((CADisplayLink) -> Void)?

    init(_ handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
        super.init()
        let l = CADisplayLink(target: self, selector: #selector(fire(_:)))
        l.add(to: .main, forMode: .common)       // 指でスクロール・ピンチしている間も止まらないように
        link = l
    }

    @objc private func fire(_ l: CADisplayLink) {
        handler?(l)
    }

    func stop() {
        link?.invalidate()
        link = nil
        handler = nil
    }
}
