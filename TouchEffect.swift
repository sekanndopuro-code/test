import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - タッチエフェクト (SETTING の「タッチエフェクト」)
//
// 指を置いた位置に出す演出。エディタの画面と、テストプレイ中 (TestPlayScreen が同じものを取り付ける) の両方で、
// SETTING の「タッチエフェクト」のチェックに合わせてオン / オフする。
//   - 指を置いた瞬間: 白い輪 (直径 90pt・線 3pt) が、0.5 倍 → 1.5 倍に広がりながら 0.3 秒で透明になる
//   - 触れている間:   赤い半透明の丸 (直径 56pt) が、指についてくる
//
// 仕組み (軽くするための作り):
//   - 画面 (UIWindow) に「触れたことを見るだけ」のジェスチャ (TouchObserver) を付ける。
//     他のジェスチャを止めない・遅らせない・タッチを奪わないので、レーンの操作やピンチには影響しない。
//     複数の指も全部見える (SwiftUI の DragGesture は 1 本ぶんしか見えない)
//   - 描くのは CALayer だけ。SwiftUI の再描画 (FrameCanvas など) は 1 回も起こさない。
//     白い輪は Core Animation に任せる (アプリ側は毎フレーム何もしない)。赤い丸は、指が動いたときに位置を置き換えるだけ
//   - 層は使い回す (指を置くたびに作り直さない)
//   - オフのときは、ジェスチャも層も画面から外す (何も動かない)
//   - テストプレイの画面 (fullScreenCover) が出ている間は、テストプレイ側が自分で同じものを出すので、エディタ側は外す (EditorView の .background を参照)

/// EditorView の `.background` に置く。`enabled` が true の間だけ、画面にタッチエフェクトを出す
struct TouchEffectInstaller: UIViewRepresentable {
    var enabled: Bool

    func makeUIView(context: Context) -> TouchEffectInstallerView {
        let v = TouchEffectInstallerView()
        v.isUserInteractionEnabled = false
        v.enabled = enabled
        return v
    }

    func updateUIView(_ uiView: TouchEffectInstallerView, context: Context) {
        uiView.enabled = enabled
    }

    static func dismantleUIView(_ uiView: TouchEffectInstallerView, coordinator: Void) {
        uiView.teardown()
    }
}

/// 画面 (UIWindow) に載ったときに、タッチエフェクトを取り付ける (オフ / 画面から外れたときは取り外す)
final class TouchEffectInstallerView: UIView {
    var enabled = false {
        didSet { if enabled != oldValue { sync() } }
    }
    private var overlay: TouchEffectOverlay?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sync()
    }

    func teardown() {
        overlay?.remove()
        overlay = nil
    }

    private func sync() {
        guard enabled, let w = window else {
            teardown()
            return
        }
        if let o = overlay, o.window === w { return }
        overlay?.remove()
        overlay = TouchEffectOverlay(window: w)
    }
}

/// 白い輪と赤い丸を描く層 (画面の最前面) と、タッチを見るジェスチャ
private final class TouchEffectOverlay {
    let window: UIWindow

    private let canvas = UIView()                   // 画面全体を覆う、タッチを通す透明な層
    private let observer = TouchObserver(target: nil, action: nil)

    private var dots: [ObjectIdentifier: CALayer] = [:]     // 触れている指ごとの赤い丸
    private var freeDots: [CALayer] = []                    // 使い回し用
    private var freeRings: [CALayer] = []
    private var liveRings = 0

    private static let dotSize: CGFloat = 56
    private static let ringSize: CGFloat = 90
    private static let ringTime: CFTimeInterval = 0.3
    private static let maxRings = 32                        // 連打しても、同時に出す輪はこの数まで

    init(window: UIWindow) {
        self.window = window
        canvas.isUserInteractionEnabled = false
        canvas.frame = window.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(canvas)

        observer.onBegan = { [weak self] t in self?.began(t) }
        observer.onMoved = { [weak self] t in self?.moved(t) }
        observer.onEnded = { [weak self] t in self?.ended(t) }
        window.addGestureRecognizer(observer)
    }

    func remove() {
        window.removeGestureRecognizer(observer)
        observer.onBegan = nil
        observer.onMoved = nil
        observer.onEnded = nil
        canvas.removeFromSuperview()
        dots.removeAll()
        freeDots.removeAll()
        freeRings.removeAll()
    }

    // MARK: タッチ

    private func began(_ t: UITouch) {
        window.bringSubviewToFront(canvas)          // シートなどが後から載っても、いちばん手前に見えるように (すでに手前なら何も起きない)
        let p = t.location(in: window)
        let d = freeDots.popLast() ?? makeDot()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        d.position = p
        d.isHidden = false
        CATransaction.commit()
        dots[ObjectIdentifier(t)] = d
        spawnRing(at: p)
    }

    private func moved(_ t: UITouch) {
        guard let d = dots[ObjectIdentifier(t)] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        d.position = t.location(in: window)
        CATransaction.commit()
    }

    private func ended(_ t: UITouch) {
        guard let d = dots.removeValue(forKey: ObjectIdentifier(t)) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        d.isHidden = true
        CATransaction.commit()
        freeDots.append(d)
    }

    // MARK: 層

    private func makeDot() -> CALayer {
        let d = CALayer()
        d.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        d.cornerRadius = Self.dotSize / 2
        d.backgroundColor = UIColor(red: 1, green: 0.3, blue: 0.35, alpha: 0.45).cgColor     // テストプレイと同じ色
        d.zPosition = 3
        d.isHidden = true
        canvas.layer.addSublayer(d)
        return d
    }

    private func makeRing() -> CALayer {
        let r = CALayer()
        r.bounds = CGRect(x: 0, y: 0, width: Self.ringSize, height: Self.ringSize)
        r.cornerRadius = Self.ringSize / 2
        r.borderWidth = 3
        r.borderColor = UIColor.white.cgColor
        r.zPosition = 4
        r.isHidden = true
        canvas.layer.addSublayer(r)
        return r
    }

    /// 白い輪: 0.5 倍 → 1.5 倍、不透明 → 透明 (0.3 秒、一定の速さ)。動きは Core Animation が描くので、アプリ側は毎フレーム何もしない
    private func spawnRing(at p: CGPoint) {
        guard liveRings < Self.maxRings else { return }
        let r = freeRings.popLast() ?? makeRing()
        liveRings += 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        r.position = p
        r.isHidden = false
        r.opacity = 0                                       // アニメーションが終わったあとの状態 (消えている)
        r.transform = CATransform3DMakeScale(1.5, 1.5, 1)
        CATransaction.commit()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.5
        scale.toValue = 1.5
        scale.duration = Self.ringTime
        scale.timingFunction = CAMediaTimingFunction(name: .linear)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = Self.ringTime
        fade.timingFunction = CAMediaTimingFunction(name: .linear)

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Self.ringTime
        r.add(group, forKey: "touchRing")

        // 終わったら隠して、使い回しに戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringTime + 0.05) { [weak self, weak r] in
            guard let self = self, let r = r else { return }
            r.removeAllAnimations()
            r.isHidden = true
            self.liveRings = max(0, self.liveRings - 1)
            self.freeRings.append(r)
        }
    }
}

/// 触れた指を見るだけのジェスチャ。どのジェスチャにも止められず、どのジェスチャも止めず、タッチも奪わない。
/// 認識 (began / recognized) には入らず、指が全部離れたら failed にして、次のタッチに備える
private final class TouchObserver: UIGestureRecognizer {
    var onBegan: ((UITouch) -> Void)?
    var onMoved: ((UITouch) -> Void)?
    var onEnded: ((UITouch) -> Void)?
    private var live = Set<ObjectIdentifier>()

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
            live.insert(ObjectIdentifier(t))
            onBegan?(t)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches { onMoved?(t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            live.remove(ObjectIdentifier(t))
            onEnded?(t)
        }
        if live.isEmpty && state == .possible { state = .failed }
    }

    override func reset() {
        live.removeAll()
    }
}
