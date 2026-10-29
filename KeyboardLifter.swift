import SwiftUI
import UIKit

/// キーボードが出たとき、画面全体を「そのまま」(拡大縮小せず) 上へ持ち上げて、入力中の欄を見えるようにする。
///
/// - 前提: RootView の DesignCanvas に `.ignoresSafeArea(.all, ...)` を付けて、キーボード分の縮みを無視させる。
///   (縮むと DesignCanvas の倍率 = 画面の高さ ÷ 820 が下がって、画面全体が押し潰されていた)
/// - 持ち上げは UIKit 側 (ルート view の transform) で行う。transform は同期で読めるので、
///   欄を Beat → Value のように切り替えたときも、持ち上げ済みの量を足し戻して計算できる
/// - 入力中の欄がエディタ (ルート view) の中にあるときだけ持ち上げる。「分割」のアラートなど、別の画面の入力欄では何もしない
final class KeyboardLifter {
    static let shared = KeyboardLifter()

    /// 入力欄の下に、最低でもこれだけ見せる (設計画面 = 高さ 820pt 基準の pt)。
    /// Beat / Value の下の Add / Remove までキーボードの上に出すための値。大きいほど高く持ち上がる
    var extraBelow: CGFloat = 110
    /// 入力欄の上端を、画面の上から最低これだけ空ける (pt)。持ち上げすぎて欄が画面の外へ出るのを防ぐ
    var topMargin: CGFloat = 20

    private var started = false
    private var keyboardFrame: CGRect = .zero // 画面座標。キーボードが隠れているときは .zero

    private init() {}

    /// RootView の onAppear から1回呼ぶ (何度呼んでも安全)
    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            self?.keyboardChanged(n, hidden: false)
        }
        nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] n in
            self?.keyboardChanged(n, hidden: true)
        }
        // 欄を切り替えたとき (キーボードは出たまま) も、持ち上げ量を取り直す
        nc.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.focusChanged()
        }
        nc.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.focusChanged()
        }
    }

    // MARK: - 通知

    private func keyboardChanged(_ n: Notification, hidden: Bool) {
        if hidden {
            keyboardFrame = .zero
        } else if let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            keyboardFrame = end
        }
        let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        update(duration: duration)
    }

    private func focusChanged() {
        // 欄が first responder になってから読む
        DispatchQueue.main.async { [weak self] in
            self?.update(duration: 0.25)
        }
    }

    // MARK: - 持ち上げ

    private func update(duration: Double) {
        guard let window = Self.keyWindow, let root = window.rootViewController?.view else { return }
        let current = -root.transform.ty // いま掛かっている持ち上げ量
        let target = targetLift(window: window, root: root, current: current)
        guard abs(target - current) > 0.5 else { return }
        window.backgroundColor = .black // 持ち上げて空いた下端が、キーボードの隙間から白く見えないように
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]) {
            root.transform = CGAffineTransform(translationX: 0, y: -target)
        }
    }

    /// 持ち上げる量 (pt)。0 〜 キーボードの高さ
    private func targetLift(window: UIWindow, root: UIView, current: CGFloat) -> CGFloat {
        // キーボードが無い / 浮いている (画面の下に付いていない) ときは持ち上げない
        let kb = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
        let H = window.bounds.height
        guard keyboardFrame.height > 1, kb.minY < H - 1, kb.maxY >= H - 1 else { return 0 }

        // 入力中の欄が、エディタの中にあるときだけ
        guard let field = UIResponder.kl_currentFirstResponder as? UIView,
              field.isDescendant(of: root) else { return 0 }

        let r = field.convert(field.bounds, to: window) // 持ち上げ込みの、いまの位置
        let top0 = r.minY + current                      // 持ち上げる前の位置 (掛かっている分を足し戻す)
        let bottom0 = r.maxY + current
        let s = H / 820                                  // 設計画面 (高さ 820pt) との倍率

        let wanted = bottom0 + extraBelow * s - kb.minY  // 欄の下のボタンまで見せるのに要る量
        let atLeast = bottom0 + 12 - kb.minY             // 欄そのものを見せるのに最低限要る量
        let atMost = top0 - topMargin                    // これ以上持ち上げると、欄の上端が画面の外へ出る
        let lift = min(wanted, max(atLeast, atMost))
        return max(0, min(lift, H - kb.minY))
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

// MARK: - 入力中の欄 (first responder) を探す

extension UIResponder {
    fileprivate static weak var kl_found: UIResponder?

    /// いま入力中の UIResponder (UITextField など)。無ければ nil
    static var kl_currentFirstResponder: UIResponder? {
        kl_found = nil
        // 宛先を nil にして送ると、first responder だけがこのメソッドを受け取る
        _ = UIApplication.shared.sendAction(#selector(UIResponder.kl_capture), to: nil, from: nil, for: nil)
        return kl_found
    }

    @objc fileprivate func kl_capture() {
        UIResponder.kl_found = self
    }
}
