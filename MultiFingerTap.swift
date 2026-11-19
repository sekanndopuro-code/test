import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - 2 本指タップで Undo / 3 本指タップで Redo (SETTING の「Undo / Redo を 2 点 / 3 点同時押しで行う」)
//
// お絵描きソフトと同じ操作。EDIT 中に、画面のどこでも:
//   ・2 本の指でちょんと触れて離す → Undo
//   ・3 本の指でちょんと触れて離す → Redo
// 「ちょんと」の条件 (どれか 1 つでも外れたらタップではなく、何もしない):
//   ・最初の指から最後の指が触れるまでが 0.35 秒以内 (指 1 本を置いたまま、あとから別の指を置いたときは対象外)
//   ・どの指も、触れた場所から 20pt 以上動かない (ピンチ・2 本指のスクロールは対象外)
//   ・最初の指が触れてから、全部の指が離れるまでが 0.7 秒以内
//   ・同時に触れた指の数が、ちょうど 2 本か 3 本 (4 本以上は対象外)
// 全部の指が離れた瞬間に実行する。
//
// 仕組みは TouchEffect.swift と同じ: 画面 (UIWindow) に「触れたことを見るだけ」のジェスチャを付ける。
// 他のジェスチャを止めない・遅らせない・タッチを奪わないので、レーンの操作やピンチには影響しない。
// 複数の指は SwiftUI の DragGesture では見えないので、UIKit 側で数える。
// EDIT 中で、右ウィンドウ (BPM / SETTING など)・Grid のダイアログ・UI調整モード・テストプレイが出ていないときだけ働く (`multiFingerTapEnabled`)

extension EditorState {
    /// いま、2 本 / 3 本指のタップを受けつけるか
    var multiFingerTapEnabled: Bool {
        twoFingerUndoRedo && editing && sidePanel == nil && !showGridDialog && !uiAdjustMode && testLaunch == nil
    }

    /// 新しいタッチ (指が 0 本から 1 本になった) が始まった
    func multiFingerSequenceBegan() {
        multiFingerTouchActive = false
    }

    /// 2 本目の指が (タップの条件に合う早さで) 触れた。レーンが、1 本目の指の操作 (置く・選択を変える) を取り消せるように印を付ける
    func multiFingerSecondFingerLanded() {
        if multiFingerTapEnabled { multiFingerTouchActive = true }
    }

    /// 全部の指が離れて、2 本 / 3 本指のタップと分かった。2 本 = Undo、3 本 = Redo
    func multiFingerTapped(fingers: Int) {
        guard multiFingerTapEnabled else { return }
        // 1 本目の指がレーンで始めていた操作 (指を離したときにノーツを置く・選択を変える、など) は、先に取り消す。
        // (レーンの onEnded が、タップより先に届いていたときは、そちらで取り消し済み)
        _ = cancelLaneTouchForMultiFinger()
        switch fingers {
        case 2:
            if undoCount > 0 {
                undo()
                showToast("Undo", seconds: 0.8)
            } else {
                showToast("戻せる操作がありません", seconds: 0.8)
            }
        case 3:
            if redoCount > 0 {
                redo()
                showToast("Redo", seconds: 0.8)
            } else {
                showToast("やり直せる操作がありません", seconds: 0.8)
            }
        default:
            break
        }
    }
}

/// EditorView の `.background` に置く。`enabled` が true の間だけ、画面に 2 本 / 3 本指のタップを見るジェスチャを付ける
struct MultiFingerTapInstaller: UIViewRepresentable {
    var enabled: Bool
    var onSequenceBegan: () -> Void
    var onSecondFinger: () -> Void
    var onTap: (Int) -> Void

    func makeUIView(context: Context) -> MultiFingerTapInstallerView {
        let v = MultiFingerTapInstallerView()
        v.isUserInteractionEnabled = false
        apply(to: v)
        return v
    }

    func updateUIView(_ uiView: MultiFingerTapInstallerView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to v: MultiFingerTapInstallerView) {
        v.onSequenceBegan = onSequenceBegan
        v.onSecondFinger = onSecondFinger
        v.onTap = onTap
        v.enabled = enabled
    }

    static func dismantleUIView(_ uiView: MultiFingerTapInstallerView, coordinator: Void) {
        uiView.teardown()
    }
}

/// 画面 (UIWindow) に載ったときに、ジェスチャを取り付ける (オフ / 画面から外れたときは取り外す)
final class MultiFingerTapInstallerView: UIView {
    var onSequenceBegan: () -> Void = {}
    var onSecondFinger: () -> Void = {}
    var onTap: (Int) -> Void = { _ in }
    var enabled = false {
        didSet { if enabled != oldValue { sync() } }
    }
    private var observer: MultiFingerTapObserver?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sync()
    }

    func teardown() {
        if let o = observer {
            o.view?.removeGestureRecognizer(o)
            o.onSequenceBegan = nil
            o.onSecondFinger = nil
            o.onTap = nil
        }
        observer = nil
    }

    private func sync() {
        guard enabled, let w = window else {
            teardown()
            return
        }
        if let o = observer, o.view === w { return }
        teardown()
        let o = MultiFingerTapObserver(target: nil, action: nil)
        // 呼び出しは、その時点の最新のクロージャへ (updateUIView で差し替わる)
        o.onSequenceBegan = { [weak self] in self?.onSequenceBegan() }
        o.onSecondFinger = { [weak self] in self?.onSecondFinger() }
        o.onTap = { [weak self] n in self?.onTap(n) }
        w.addGestureRecognizer(o)
        observer = o
    }
}

/// 指の数と動きを数えるだけのジェスチャ。どのジェスチャにも止められず、どのジェスチャも止めず、タッチも奪わない。
/// 認識 (began / recognized) には入らず、指が全部離れたら failed にして、次のタッチに備える
final class MultiFingerTapObserver: UIGestureRecognizer {
    var onSequenceBegan: (() -> Void)?
    var onSecondFinger: (() -> Void)?
    var onTap: ((Int) -> Void)?

    /// 最初の指が触れてから、最後の指が触れるまでの許容 (秒)
    static let landWindow: TimeInterval = 0.35
    /// 最初の指が触れてから、全部の指が離れるまでの許容 (秒)
    static let maxDuration: TimeInterval = 0.7
    /// 指が触れた場所から動いてよい距離 (pt)。これを超えたらタップではない (ピンチ・スクロール)
    static let moveTolerance: CGFloat = 20

    private var live: [ObjectIdentifier: CGPoint] = [:]     // 触れている指と、触れた場所
    private var maxCount = 0                                // このタッチの中で、同時に触れた指の最大数
    private var firstTime: TimeInterval = 0                 // 最初の指が触れた時刻
    private var valid = true                                // ここまで、タップの条件から外れていないか
    private var secondReported = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            if live.isEmpty {
                // 指が 0 本から 1 本になった = 新しいタッチの始まり
                maxCount = 0
                valid = true
                secondReported = false
                firstTime = t.timestamp
                onSequenceBegan?()
            }
            live[ObjectIdentifier(t)] = t.location(in: view)
            maxCount = max(maxCount, live.count)
            if t.timestamp - firstTime > Self.landWindow || maxCount > 3 {
                valid = false           // あとから触れた指 / 4 本以上は、タップの対象外
            }
            if valid && live.count >= 2 && !secondReported {
                secondReported = true
                onSecondFinger?()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard valid else { return }
        for t in touches {
            guard let p0 = live[ObjectIdentifier(t)] else { continue }
            let p = t.location(in: view)
            if hypot(p.x - p0.x, p.y - p0.y) > Self.moveTolerance {
                valid = false
                return
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        var lastTime: TimeInterval = firstTime
        for t in touches {
            live.removeValue(forKey: ObjectIdentifier(t))
            lastTime = max(lastTime, t.timestamp)
        }
        if cancelled { valid = false }
        guard live.isEmpty else { return }
        if valid && (maxCount == 2 || maxCount == 3) && lastTime - firstTime <= Self.maxDuration {
            onTap?(maxCount)
        }
        if state == .possible { state = .failed }
    }

    override func reset() {
        live.removeAll()
        maxCount = 0
        valid = true
        secondReported = false
    }
}
