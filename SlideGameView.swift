import UIKit
import AVFoundation

// MARK: - テストプレイの画面 (本家のスライドモードの見た目)
//
// 判定・スコア・時間・スクロールの計算は SlideCore.swift、画面の幾何は SlideLayout.swift、画像は SlideSkin.swift。
// ここは「それを CALayer に並べて、CADisplayLink で毎フレーム動かす」だけ。
//
// 構成 (奥 → 手前):
//   背景画像 + 暗幕 (エディタの bgDim)            ・・・ 画面全体 (flat)
//   板 (planeLayer) … 3D 傾斜の台形になる、幅 fw × 高さ 1080 単位の平面
//      背景の暗幕 (#09090C 85%)・左右の縁 (bar0)・スライドの帯・ノーツ・判定線 (judge)・判定文字
//   ヒット光 light2 (横に流れる光)                ・・・ 判定線の画面位置 (flat)
//   HUD: score / combo / acc / HP / ポーズボタン  ・・・ flat
//   ヒット光 light (六角形)                       ・・・ いちばん手前 (flat)
// 板の傾きは、本家の画面収録から測った値 (SlideLayout.swift) の射影変換を CATransform3D にして与える。

// MARK: レイヤーの使い回し

private final class LayerPool {
    private(set) var items: [CALayer] = []
    private var used = 0
    private let make: () -> CALayer
    private weak var host: CALayer?

    init(host: CALayer, make: @escaping () -> CALayer) {
        self.host = host
        self.make = make
    }

    func begin() { used = 0 }

    func next() -> CALayer {
        let l: CALayer
        if used < items.count {
            l = items[used]
        } else {
            l = make()
            host?.addSublayer(l)
            items.append(l)
        }
        used += 1
        l.isHidden = false
        return l
    }

    /// 今回使わなかった分を隠す
    func end() {
        if used < items.count {
            for i in used..<items.count where !items[i].isHidden { items[i].isHidden = true }
        }
    }

    func clear() {
        for l in items { l.removeFromSuperlayer() }
        items.removeAll()
        used = 0
    }
}

// MARK: 数字 (HUD)

/// 等間隔・中央置きの数字。画像は 1 枚ずつ CALayer (使い回し)
private final class GlyphRow {
    let host = CALayer()                      // 中心に置く (大きさ 0)。拡縮 (ポップ) はこの層に掛ける
    private var glyphs: [CALayer] = []
    private let font: SlideHUD.Font
    private let cell: (w: Double, h: Double)
    private let color: UInt32?                // nil = 色を付けない (combo は元から白)
    private let isCombo: Bool
    private var lastText = ""
    private var lastUnit: CGFloat = 0

    init(isCombo: Bool, color: UInt32?) {
        self.isCombo = isCombo
        self.font = isCombo ? SlideHUD.combo : SlideHUD.number
        self.cell = isCombo ? (136, 159) : (70, 79)
        self.color = color
        host.bounds = .zero
    }

    func set(text: String, unit u: CGFloat) {
        if text == lastText && u == lastUnit { return }
        lastText = text
        lastUnit = u
        let idx = SlideHUD.indices(text)
        while glyphs.count < idx.count {
            let g = CALayer()
            host.addSublayer(g)
            glyphs.append(g)
        }
        let gw = CGFloat(cell.w * font.glyphScale) * u
        let gh = CGFloat(cell.h * font.glyphScale) * u
        for (i, g) in glyphs.enumerated() {
            if i < idx.count {
                g.isHidden = false
                g.bounds = CGRect(x: 0, y: 0, width: gw, height: gh)
                g.position = CGPoint(x: CGFloat(SlideHUD.glyphCenterX(index: i, count: idx.count, font: font)) * u, y: 0)
                g.contents = isCombo ? SlideSkin.shared.combo(idx[i]) : SlideSkin.shared.number(idx[i], color: color ?? 0xFFFFFF)
            } else {
                g.isHidden = true
            }
        }
    }
}

// MARK: ヒット光

private final class HitFX {
    let light2 = CALayer()
    let light = CALayer()
    var born: Double = 0
    var x: Int = 0                            // 0...255 (判定線の上の位置)
    var loop = false                          // 保持中 (hit-3): ぐるぐる回す
    weak var note: SlideNote?
}

// MARK: GameView

final class GameView: UIView {
    // ---- 調整用 ----
    private static let countIn = 2.0          // 秒: 開始前のカウント
    // ----------------

    private let chart: MalodyChart
    private let slide: SlideChart
    private var engine: SlideEngine
    private let audio: GameAudio?
    private let session: GameSession
    private let startAt: Double               // 譜面時刻(秒): テストを始める位置 (0 = 最初から)
    private let background: UIImage?
    private let bgDim: Double

    private var link: CADisplayLink?
    private var running = false
    private var pausedT = 0.0
    private var silentHost = 0.0              // 無音時の時計: この時刻に譜面時刻 silentChart
    private var silentChart = 0.0
    private var observers: [NSObjectProtocol] = []

    // 幾何
    private var plane = SlidePlane(width: 1, height: 1)
    private var laidOutSize = CGSize.zero

    // 層
    private let bgImageLayer = CALayer()
    private let bgDimLayer = CALayer()
    private let planeLayer = CALayer()
    private let fieldBG = CALayer()
    private let underBG = CALayer()
    private let barL = CALayer()
    private let barR = CALayer()
    private let judgeBar = CALayer()
    private let bandHost = CALayer()
    private let noteHost = CALayer()
    private let judgeText = CALayer()
    private let hitHost2 = CALayer()          // light2 の置き場 (HUD の奥)
    private let hudHost = CALayer()
    private let hitHost1 = CALayer()          // light の置き場 (いちばん手前)
    private let hpFrame = CALayer()
    private let hpFill = CALayer()
    private let scoreRow = GlyphRow(isCombo: false, color: 0x6ECAEE)
    private let comboRow = GlyphRow(isCombo: true, color: nil)
    private let accRow = GlyphRow(isCombo: false, color: 0xC24954)
    private let pauseButton = UIButton(type: .custom)
    private let resultLabel = UILabel()

    private var tapPool: LayerPool!
    private var wipePool: LayerPool!
    private var headPool: LayerPool!
    private var bandPool: LayerPool!

    // 描画の状態
    private var drawHead = 0                  // まだ退場していない先頭のノーツ
    private var fxLive: [HitFX] = []
    private var fxFree: [HitFX] = []
    private var holdFX: [ObjectIdentifier: HitFX] = [:]
    private var judgeGrade = -1
    private var judgeBorn = 0.0
    private var lastCombo = 0
    private var comboBorn = 0.0
    private var scoreFrom = 0.0, scoreTo = 0.0, scoreBorn = 0.0
    private var accFrom = 0.0, accTo = 0.0, accBorn = 0.0

    private var firstTime: Double { startAt - Self.countIn }
    private var startAtMs: Int? { startAt > 0 ? Int(startAt * 1000) : nil }

    init(chart: MalodyChart, audio: GameAudio?, session: GameSession, startAt: Double = 0,
         background: UIImage? = nil, bgDim: Double = 0.7) {
        self.chart = chart
        self.slide = chart.slide
        self.audio = audio
        self.session = session
        self.startAt = startAt
        self.background = background
        self.bgDim = bgDim
        self.engine = SlideEngine(chart: chart.slide, level: session.judgeLevel,
                                  startAtMs: startAt > 0 ? Int(startAt * 1000) : nil)
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        buildLayers()
        attachEngine()
        // 大きい画像のデコードは、先に済ませておく (初めてヒット光が出るときに引っかからないように)
        DispatchQueue.global(qos: .userInitiated).async { SlideSkin.shared.prepare() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func noAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: 層の組み立て

    private func buildLayers() {
        let skin = SlideSkin.shared
        let root = layer

        if let img = background?.cgImage {
            bgImageLayer.contents = img
            bgImageLayer.contentsGravity = .resizeAspectFill
            bgImageLayer.masksToBounds = true
            root.addSublayer(bgImageLayer)
        }
        bgDimLayer.backgroundColor = UIColor.black.withAlphaComponent(CGFloat(bgDim)).cgColor
        if background != nil { root.addSublayer(bgDimLayer) }

        // 板 (3D 傾斜)
        planeLayer.anchorPoint = .zero
        planeLayer.position = .zero
        planeLayer.zPosition = 10
        root.addSublayer(planeLayer)
        let dark = UIColor(red: 0x09 / 255.0, green: 0x09 / 255.0, blue: 0x0C / 255.0, alpha: 0.85).cgColor
        fieldBG.backgroundColor = dark
        fieldBG.zPosition = 1
        underBG.backgroundColor = dark
        underBG.zPosition = 1
        barL.contents = skin.image("bar0")
        barR.contents = skin.image("bar0")
        barR.transform = CATransform3DMakeScale(-1, 1, 1)
        barL.zPosition = 2
        barR.zPosition = 2
        judgeBar.contents = skin.image("judge")
        judgeBar.zPosition = 5
        bandHost.zPosition = 3
        noteHost.zPosition = 4
        judgeText.zPosition = 50
        judgeText.opacity = 0
        for l in [fieldBG, underBG, barL, barR, bandHost, noteHost, judgeBar, judgeText] { planeLayer.addSublayer(l) }

        tapPool = LayerPool(host: noteHost) {
            let l = CALayer()
            l.contents = SlideSkin.shared.image("note0")
            l.contentsCenter = CGRect(x: 80.0 / 243, y: 0, width: 86.0 / 243, height: 1)
            l.contentsScale = 56.0 / 24.0
            return l
        }
        wipePool = LayerPool(host: noteHost) {
            let l = CALayer()
            l.contents = SlideSkin.shared.image("note1")
            l.contentsCenter = CGRect(x: 21.0 / 46, y: 0, width: 4.0 / 46, height: 1)
            l.contentsScale = 46.0 / 16.0
            return l
        }
        headPool = LayerPool(host: noteHost) {
            let l = CALayer()
            l.contents = SlideSkin.shared.image("note3")
            l.contentsCenter = CGRect(x: 89.0 / 205, y: 0, width: 39.0 / 205, height: 1)
            l.contentsScale = 56.0 / 24.0
            return l
        }
        bandPool = LayerPool(host: bandHost) {
            let l = CALayer()
            l.backgroundColor = UIColor(white: 1, alpha: 102.0 / 255).cgColor      // note2.png (一様な白 40%)
            return l
        }

        // ヒット光・HUD (flat)
        hitHost2.zPosition = 20
        hudHost.zPosition = 30
        hitHost1.zPosition = 40
        root.addSublayer(hitHost2)
        root.addSublayer(hudHost)
        root.addSublayer(hitHost1)

        hpFrame.contents = skin.image("hp0")
        hpFill.contents = skin.image("hp1")
        hudHost.addSublayer(hpFrame)
        hudHost.addSublayer(hpFill)
        for r in [scoreRow, comboRow, accRow] { hudHost.addSublayer(r.host) }

        pauseButton.setImage(skin.image("pause").map { UIImage(cgImage: $0) }, for: .normal)
        pauseButton.imageView?.contentMode = .scaleAspectFit
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        addSubview(pauseButton)

        resultLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        resultLabel.textColor = .white
        resultLabel.textAlignment = .center
        resultLabel.numberOfLines = 3
        resultLabel.isHidden = true
        addSubview(resultLabel)
    }

    @objc private func pauseTapped() { pause() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        guard w > 1, h > 1 else { return }
        if CGSize(width: w, height: h) != laidOutSize {
            laidOutSize = CGSize(width: w, height: h)
            plane = SlidePlane(width: Double(w), height: Double(h))
            let fw = CGFloat(plane.fieldWidth)
            let u = CGFloat(plane.unit)
            noAnimation {
                bgImageLayer.frame = bounds
                bgDimLayer.frame = bounds
                planeLayer.bounds = CGRect(x: 0, y: 0, width: fw, height: 1080)
                planeLayer.anchorPoint = .zero
                planeLayer.position = .zero
                planeLayer.transform = GameView.matrix(plane.layerMatrix)
                fieldBG.frame = CGRect(x: 0, y: 0, width: fw, height: 1080)
                underBG.frame = CGRect(x: 0, y: 1080, width: fw, height: 120)
                // 左の縁は右端が x=1、右の縁 (左右反転) は左端が x=fw−1。反転しているので frame ではなく bounds+position で置く
                barL.bounds = CGRect(x: 0, y: 0, width: 62, height: 1080)
                barL.position = CGPoint(x: 1 - 31, y: 540)
                barR.bounds = CGRect(x: 0, y: 0, width: 62, height: 1080)
                barR.position = CGPoint(x: fw - 1 + 31, y: 540)
                judgeBar.frame = CGRect(x: 0, y: 1080 - 14, width: fw, height: 28)
                judgeText.bounds = CGRect(x: 0, y: 0, width: CGFloat(SlideJudgeText.size.w), height: CGFloat(SlideJudgeText.size.h))
                judgeText.position = CGPoint(x: fw / 2, y: 1080 - CGFloat(SlideJudgeText.centerY))
                // HUD
                hpFrame.bounds = CGRect(x: 0, y: 0, width: 538 * u, height: 54 * u)
                hpFrame.position = CGPoint(x: w - 538 * u / 2, y: 10 * u + 27 * u)
                updateHP(animated: false)
                scoreRow.host.position = CGPoint(x: w / 2, y: CGFloat(SlideHUD.scoreY) * u)
                comboRow.host.position = CGPoint(x: w / 2, y: CGFloat(SlideHUD.comboY) * u)
                accRow.host.position = CGPoint(x: w / 2, y: CGFloat(SlideHUD.accY) * u)
                pauseButton.frame = CGRect(x: 0, y: 8 * u, width: 120 * u, height: 100 * u)
                resultLabel.frame = CGRect(x: 0, y: h * 0.42, width: w, height: 110)
            }
            engine.areaWidth = Float(w)
            engine.fieldWidth = Float(w)
            fillHUD(force: true)
        }
    }

    private static func matrix(_ a: [Double]) -> CATransform3D {
        CATransform3D(m11: CGFloat(a[0]), m12: CGFloat(a[1]), m13: CGFloat(a[2]), m14: CGFloat(a[3]),
                      m21: CGFloat(a[4]), m22: CGFloat(a[5]), m23: CGFloat(a[6]), m24: CGFloat(a[7]),
                      m31: CGFloat(a[8]), m32: CGFloat(a[9]), m33: CGFloat(a[10]), m34: CGFloat(a[11]),
                      m41: CGFloat(a[12]), m42: CGFloat(a[13]), m43: CGFloat(a[14]), m44: CGFloat(a[15]))
    }

    /// HP バー: hp1 の右端を固定し、gaugeB の分だけ右側を見せる (左から欠ける。減る向きは本家の収録で確認できず、仮)
    private func updateHP(animated: Bool) {
        let u = CGFloat(plane.unit)
        let full = 469 * u
        let ratio = CGFloat(min(max(engine.score.gaugeB, 0), 1))
        let right = bounds.width - 18 * u
        hpFill.bounds = CGRect(x: 0, y: 0, width: full * ratio, height: 28 * u)
        hpFill.position = CGPoint(x: right - full * ratio / 2, y: (10 + 27) * u)
        hpFill.contentsRect = CGRect(x: 1 - ratio, y: 0, width: ratio, height: 1)
    }

    // MARK: エンジンとの接続

    private func attachEngine() {
        engine.areaWidth = Float(max(bounds.width, 1))
        engine.fieldWidth = Float(max(bounds.width, 1))
        engine.onHitSound = { [weak self] in
            guard let s = self, s.session.hitSound else { return }
            KeySound.shared.playNow()
        }
        engine.onJudge = { [weak self] ev in self?.handle(ev) }
    }

    private func handle(_ ev: SlideJudgeEvent) {
        let wall = uptime()
        switch ev.kind {
        case .head:
            judgeGrade = SlideJudgeText.frame(grade: ev.grade)
            judgeBorn = wall
            if ev.grade != 1 { spawnHit(x: ev.x, loop: false, note: nil, wall: wall) }
        case .wipe:
            spawnHit(x: ev.x, loop: false, note: nil, wall: wall)
        case .tick, .releasePenalty:
            break
        }
    }

    // MARK: 開始・停止・ポーズ

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if link == nil { startGame() }
        } else {
            teardown()
        }
    }

    private func startGame() {
        session.view = self
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in self?.pause() })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] _ in self?.pause() })
        begin(at: firstTime)
    }

    private func teardown() {
        link?.invalidate()
        link = nil
        running = false
        audio?.shutdown()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    /// 譜面時刻 tc から(音も含めて)再生を始める。最初・コンティニュー・リトライ共通。
    /// 毎回「曲のサンプル位置」から時刻を作り直すので、何度繰り返してもズレない
    private func begin(at tc: Double) {
        let off = chart.offset - session.offsetMs / 1000
        if let a = audio {
            a.begin(chartTime: tc, offsetTotal: off)
        } else {
            silentHost = uptime() + 0.05
            silentChart = tc
        }
        engine.setLevel(session.judgeLevel)
        running = true
        link?.isPaused = false
        if session.paused { session.paused = false }
    }

    private func chartTime(at h: Double) -> Double {
        if let a = audio { return a.chartTime(atUptime: h) }
        return silentChart + (h - silentHost)
    }

    func pause() {
        guard running else { return }
        let tStart = uptime()
        pausedT = chartTime(at: tStart)
        running = false
        link?.isPaused = true
        engine.releaseAllTouches()
        let tAudio = uptime()
        audio?.halt()
        let tEnd = uptime()
        session.pauseInfo = String(format: "pause処理 %.1f ms (うち音声停止 %.1f ms)", (tEnd - tStart) * 1000, (tEnd - tAudio) * 1000)
        session.paused = true
    }

    func resume() {
        guard !running else { return }
        begin(at: pausedT)
    }

    func retry() {
        engine.setLevel(session.judgeLevel)         // reset はレベルを引き継ぐので、先に変えておく
        engine.reset(startAtMs: startAtMs)
        drawHead = 0
        clearEffects()
        resultLabel.isHidden = true
        judgeGrade = -1
        lastCombo = 0
        scoreFrom = 0; scoreTo = 0; accFrom = 0; accTo = 0
        noAnimation { judgeText.opacity = 0 }
        fillHUD(force: true)
        begin(at: firstTime)
    }

    private func clearEffects() {
        noAnimation {
            for fx in fxLive + Array(holdFX.values) {
                fx.light.isHidden = true
                fx.light2.isHidden = true
                fxFree.append(fx)
            }
        }
        fxLive.removeAll()
        holdFX.removeAll()
    }

    // MARK: 毎フレーム

    @objc private func tick(_ l: CADisplayLink) {
        guard running else { return }
        audio?.refreshAnchor()
        let now = uptime()
        let tJudge = chartTime(at: now) * 1000
        engine.update(now: tJudge)
        let tView = chartTime(at: l.targetTimestamp) * 1000       // 画面に出る時刻で描く
        noAnimation { render(tViewMs: tView, nowMs: tJudge, wall: now) }
    }

    // MARK: 入力 (タッチが起きた時刻そのもので判定する)

    private func judgeMs(_ tc: UITouch) -> Double { chartTime(at: tc.timestamp) * 1000 }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard running else { return }
        for tc in touches {
            engine.touchBegan(id: ObjectIdentifier(tc).hashValue, x: Float(tc.location(in: self).x), now: judgeMs(tc))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard running else { return }
        for tc in touches {
            engine.touchMoved(id: ObjectIdentifier(tc).hashValue, x: Float(tc.location(in: self).x), now: judgeMs(tc))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for tc in touches {
            engine.touchEnded(id: ObjectIdentifier(tc).hashValue, x: Float(tc.location(in: self).x), now: judgeMs(tc))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: 描画

    private func render(tViewMs: Double, nowMs: Double, wall: Double) {
        let n = session.speedN
        let scale = SlideScroll.planeUnitsPerP(n: n)             // P 1 単位あたりの平面の長さ
        let spawn = SlideScroll.spawnDistance(n: n)
        let pNow = slide.pNow(tViewMs)
        let fw = plane.fieldWidth
        let toLX = fw / 255.0

        tapPool.begin(); wipePool.begin(); headPool.begin(); bandPool.begin()
        var holding = Set<ObjectIdentifier>()
        let notes = slide.notes
        var i = drawHead
        while i < notes.count {
            let note = notes[i]
            let dist = note.pStart - pNow
            // 生成条件: 時間 (開始 − 170ms) か 位置 (窓の内側)。先頭で満たさなければそこで止まる (本家と同じ)
            if !(Double(note.startMs) <= nowMs + 170 || dist <= spawn) { break }
            i += 1
            if note.skipped { if i - 1 == drawHead { drawHead += 1 }; continue }
            // 退場: 開始 < 現在 かつ P_end < P_now − 1000
            if Double(note.startMs) < nowMs && note.pEnd < pNow - 1000 {
                if i - 1 == drawHead { drawHead += 1 }
                continue
            }
            if note.isSlide {
                drawSlide(note, pNow: pNow, scale: scale, fw: fw, toLX: toLX, nowMs: nowMs, holding: &holding)
            } else if note.isType4 {
                if note.hit { if i - 1 == drawHead && note.judged { drawHead += 1 }; continue }
                placeNote(wipePool.next(), x: Double(note.x), h: 16, w: Double(note.w), y: dist * scale, toLX: toLX)
            } else {
                if note.hit { if i - 1 == drawHead && note.judged { drawHead += 1 }; continue }
                placeNote(tapPool.next(), x: Double(note.x), h: 24, w: Double(note.w), y: dist * scale, toLX: toLX)
            }
        }
        tapPool.end(); wipePool.end(); headPool.end(); bandPool.end()

        updateHold(holding: holding, nowMs: nowMs, wall: wall)
        updateEffects(wall: wall)
        updateJudgeText(wall: wall)
        updateHUD(wall: wall)

        if engine.isFinished(now: nowMs) && resultLabel.isHidden {
            let s = engine.score
            let ranks = ["-", "SS", "S", "A", "B", "C"]
            resultLabel.text = "FINISH   RANK \(ranks[min(max(s.rank, 0), 5)])\nSCORE \(s.total)\nACC " +
                String(format: "%.2f%%", Double(s.accPercent)) + "   MAX COMBO \(s.maxCombo)"
            resultLabel.isHidden = false
        }
    }

    /// 通常ノーツ / type 4: 中心を (x, y) に置く。x は 0...255、y は判定線から上向きの距離 (平面の単位)
    private func placeNote(_ l: CALayer, x: Double, h: Double, w: Double, y: Double, toLX: Double) {
        if y < -80 || y > 1080 + 80 { l.isHidden = true; return }
        l.bounds = CGRect(x: 0, y: 0, width: CGFloat(w * toLX), height: CGFloat(h))
        l.position = CGPoint(x: CGFloat(x * toLX), y: CGFloat(1080 - y))
    }

    /// スライド: 頭 + seg 区間ごとの回転した白い長方形 (本家の「帯ボディ」)
    private func drawSlide(_ note: SlideNote, pNow: Double, scale: Double, fw: Double, toLX: Double,
                           nowMs: Double, holding: inout Set<ObjectIdentifier>) {
        // 保持している間、通過した帯は消える (一度消えた所は、離しても戻らない。本家の機構 D)
        if note.state & 4 != 0 && pNow > note.pStart {
            note.cutP = max(note.cutP, min(pNow, note.pEnd))
        }
        if note.completed { note.cutP = max(note.cutP, note.pEnd) }
        if note.state & 4 != 0 && !note.completed { holding.insert(ObjectIdentifier(note)) }
        if note.cutP >= note.pEnd && note.pEnd > note.pStart { return }       // すべて消費した

        let m = note.segRel.count
        let bandW = Double(note.w) * toLX
        func point(_ j: Int) -> (x: Double, p: Double) {
            j == 0 ? (Double(note.x) * toLX, note.pStart)
                   : (Double(note.drawX(segIndex: j - 1)) * toLX, note.segP[j - 1])
        }
        // 見える範囲に絞る (P が単調なら二分探索)
        let pLow = pNow - 160 / scale
        let pHigh = pNow + 1200 / scale
        var k = 0
        if note.pMonotone && m > 16 {
            var lo = 0, hi = m
            while lo < hi {
                let mid = (lo + hi) >> 1
                if note.segP[mid] < pLow { lo = mid + 1 } else { hi = mid }
            }
            k = lo
        }
        // 頭 (キャップ): 保持で帯が消費されているときは、切れた所に留まる (その x は最初に描く区間の始点)
        let cut = note.cutP > note.pStart
        var headX = Double(note.x) * toLX
        let headP = cut ? note.cutP : note.pStart
        var gotHead = !cut
        var drawn = 0
        while k < m && drawn < 2400 {
            var a = point(k)
            let b = point(k + 1)
            if note.pMonotone && a.p > pHigh { break }
            if b.p <= note.cutP && note.cutP > -Double.infinity { k += 1; continue }
            if a.p < note.cutP && b.p > a.p {
                let t = (note.cutP - a.p) / (b.p - a.p)
                a = (a.x + (b.x - a.x) * t, note.cutP)
            }
            if !gotHead { headX = a.x; gotHead = true }
            let yA = (a.p - pNow) * scale, yB = (b.p - pNow) * scale
            k += 1
            // 画面の外なら描かない
            if max(yA, yB) < -160 || min(yA, yB) > 1080 + 160 { continue }
            let dx = b.x - a.x
            let dy = -(yB - yA)                     // レイヤー座標 (下向きが +)
            let len = (dx * dx + dy * dy).squareRoot()
            if len < 0.05 { continue }
            let l = bandPool.next()
            l.bounds = CGRect(x: 0, y: 0, width: CGFloat(bandW), height: CGFloat(len))
            l.position = CGPoint(x: CGFloat((a.x + b.x) / 2), y: CGFloat(1080 - (yA + yB) / 2))
            l.transform = CATransform3DMakeRotation(CGFloat(atan2(-dx, dy)), 0, 0, 1)
            drawn += 1
        }
        // 頭 (キャップ)。切れた所が範囲外 (x が分からない) なら、画面の外なので描かない
        let yH = (headP - pNow) * scale
        if gotHead && yH >= -80 && yH <= 1080 + 80 {
            let l = headPool.next()
            l.bounds = CGRect(x: 0, y: 0, width: CGFloat(bandW), height: 24)
            l.position = CGPoint(x: CGFloat(headX), y: CGFloat(1080 - yH))
        }
    }

    // MARK: ヒット光

    private func makeFX() -> HitFX {
        if let f = fxFree.popLast() {
            f.light.isHidden = false
            f.light2.isHidden = false
            return f
        }
        let f = HitFX()
        f.light2.compositingFilter = "screenBlendMode"
        f.light.compositingFilter = "screenBlendMode"
        hitHost2.addSublayer(f.light2)
        hitHost1.addSublayer(f.light)
        return f
    }

    private func spawnHit(x: Int, loop: Bool, note: SlideNote?, wall: Double) {
        let fx = makeFX()
        fx.born = wall
        fx.x = x
        fx.loop = loop
        fx.note = note
        if loop, let n = note { holdFX[ObjectIdentifier(n)] = fx } else { fxLive.append(fx) }
        place(fx, wall: wall)
    }

    /// 保持中のスライド: 光を出し続け、離したら消す。位置は指ではなく軌跡の上 (本家の判定の位置)
    private func updateHold(holding: Set<ObjectIdentifier>, nowMs: Double, wall: Double) {
        for (id, fx) in holdFX where !holding.contains(id) {
            fx.light.isHidden = true
            fx.light2.isHidden = true
            fxFree.append(fx)
            holdFX[id] = nil
        }
        for note in slide.notes[drawHead...] {
            if Double(note.startMs) > nowMs + 200 { break }
            let id = ObjectIdentifier(note)
            guard note.isSlide, holding.contains(id) else { continue }
            let x = note.trajectoryX(slideTrunc(nowMs))
            if let fx = holdFX[id] {
                fx.x = x
            } else {
                spawnHit(x: x, loop: true, note: note, wall: wall)
            }
        }
    }

    private func updateEffects(wall: Double) {
        var keep: [HitFX] = []
        for fx in fxLive {
            let age = (wall - fx.born) * 1000
            if age >= SlideHitLight.frameMs2 * Double(SlideHitLight.count2) && age >= SlideHitLight.frameMs * Double(SlideHitLight.count) {
                fx.light.isHidden = true
                fx.light2.isHidden = true
                fxFree.append(fx)
            } else {
                place(fx, wall: wall)
                keep.append(fx)
            }
        }
        fxLive = keep
        for fx in holdFX.values { place(fx, wall: wall) }
    }

    private func place(_ fx: HitFX, wall: Double) {
        let age = max(0, (wall - fx.born) * 1000)
        var f2 = Int(age / SlideHitLight.frameMs2)
        var f1 = Int(age / SlideHitLight.frameMs)
        if fx.loop {
            f2 %= SlideHitLight.count2
            let span = SlideHitLight.count - SlideHitLight.holdLoopFrom
            f1 = SlideHitLight.holdLoopFrom + f1 % span
        }
        let u = CGFloat(plane.unit)
        let p = plane.screen(Double(fx.x) * plane.fieldWidth / 255.0, 0)
        let pt = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        let k = CGFloat(SlideHitLight.visualScale)
        if f2 < SlideHitLight.count2 {
            fx.light2.isHidden = false
            fx.light2.contents = SlideSkin.shared.light2(f2)
            fx.light2.bounds = CGRect(x: 0, y: 0, width: CGFloat(SlideHitLight.size2.w) * k * u, height: CGFloat(SlideHitLight.size2.h) * k * u)
            fx.light2.position = pt
        } else {
            fx.light2.isHidden = true
        }
        if f1 < SlideHitLight.count {
            fx.light.isHidden = false
            fx.light.contents = SlideSkin.shared.light(f1)
            fx.light.bounds = CGRect(x: 0, y: 0, width: CGFloat(SlideHitLight.size.w) * k * u, height: CGFloat(SlideHitLight.size.h) * k * u)
            fx.light.position = pt
        } else {
            fx.light.isHidden = true
        }
    }

    // MARK: 判定文字・HUD

    /// 判定文字 (ui-play-score)。出た瞬間に少し大きく → 元の大きさ、しばらく見せて消える (動きは本家の仕様が不明なので仮)
    private func updateJudgeText(wall: Double) {
        guard judgeGrade >= 0 else { return }
        let age = wall - judgeBorn
        judgeText.contents = SlideSkin.shared.judge(judgeGrade)
        let hold = 0.45, fade = 0.15
        judgeText.opacity = age < hold ? 1 : Float(max(0, 1 - (age - hold) / fade))
        let pop = age < 0.08 ? 1.0 + 0.18 * (1 - age / 0.08) : 1.0
        judgeText.transform = CATransform3DMakeScale(CGFloat(pop), CGFloat(pop), 1)
    }

    private func fillHUD(force: Bool) {
        let u = CGFloat(plane.unit)
        scoreRow.set(text: String(Int(scoreTo)), unit: u)
        accRow.set(text: String(format: "%.2f%%", accTo), unit: u)
        comboRow.set(text: engine.score.combo > 0 ? String(engine.score.combo) : "", unit: u)
        updateHP(animated: false)
    }

    private func updateHUD(wall: Double) {
        let s = engine.score
        let u = CGFloat(plane.unit)
        // score / acc は、変わったら 300ms かけて追いつく (レイアウトの interval=300)
        if Double(s.total) != scoreTo { scoreFrom = currentScore(wall); scoreTo = Double(s.total); scoreBorn = wall }
        let acc = Double(s.accPercent)
        if acc != accTo { accFrom = currentAcc(wall); accTo = acc; accBorn = wall }
        scoreRow.set(text: String(Int(currentScore(wall).rounded())), unit: u)
        accRow.set(text: String(format: "%.2f%%", currentAcc(wall)), unit: u)
        // combo: 増えた瞬間に少し大きく → 元の大きさ (interval=150 を、ポップの長さに使う)
        if s.combo != lastCombo {
            if s.combo > lastCombo { comboBorn = wall }
            lastCombo = s.combo
        }
        comboRow.set(text: s.combo > 0 ? String(s.combo) : "", unit: u)
        let age = wall - comboBorn
        let pop = age < 0.15 ? 1.0 + 0.2 * (1 - age / 0.15) : 1.0
        comboRow.host.transform = CATransform3DMakeScale(CGFloat(pop), CGFloat(pop), 1)
        updateHP(animated: false)
    }

    private func currentScore(_ wall: Double) -> Double {
        let t = min(1, max(0, (wall - scoreBorn) / 0.3))
        return scoreFrom + (scoreTo - scoreFrom) * t
    }

    private func currentAcc(_ wall: Double) -> Double {
        let t = min(1, max(0, (wall - accBorn) / 0.3))
        return accFrom + (accTo - accFrom) * t
    }
}
