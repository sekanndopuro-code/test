import SwiftUI
import UIKit
import JavaScriptCore

// 操作型プラグイン (PluginType = 2。例: GizaSlide) の実行。
//   ・Run() を1回実行する型と違って、Adv. メニューで押すと「アクティブ」になり、もう一度押す (または別のツールを選ぶ) まで動き続ける
//   ・アクティブの間、レーンのタッチが、プラグインの OnClick / OnDragStart / OnDragMove / OnDragEnd に渡される
//   ・始まりは OnActive、終わりは OnDeactive
//   ・プラグインが AddSprite で出した画像 (つまみなど) は、レーンの上に表示される
// イベントは短く終わるので、メインスレッドで、タッチ処理の中でそのまま実行する
//   (画面の更新と同期するので、書き換えの途中が一瞬映ることがない。1つのイベントは 2 秒まで)

/// プラグインがレーンの上に出している画像 (AddSprite)
struct PluginSprite: Identifiable {
    let id: String               // AddSprite に渡した名前
    var image: String            // 画像のファイル名
    var dir: URL?                // 画像のあるフォルダ
    var beat: Double = 0         // 縦の位置 (中心)
    var x: Double = 50           // 横の位置 (中心。レーン幅に対する %)
    var width: Double = 10       // 幅 (レーン幅に対する %)。高さは画像の縦横比のまま
    var visible: Bool = true
}

/// プラグインのフォルダにある画像の読み込み (読み込んだものは覚えておく)
final class PluginImageCache {
    static let shared = PluginImageCache()

    private var cache: [String: UIImage] = [:]
    private var missing = Set<String>()

    func image(dir: URL?, name: String) -> UIImage? {
        guard let dir = dir, !name.isEmpty else { return nil }
        let file = (name as NSString).lastPathComponent          // フォルダをさかのぼる指定 (../) は使わせない
        let path = dir.appendingPathComponent(file).path
        if let c = cache[path] { return c }
        if missing.contains(path) { return nil }
        if let ui = UIImage(contentsOfFile: path) {
            cache[path] = ui
            return ui
        }
        missing.insert(path)
        return nil
    }
}

final class PluginSession {
    let item: PluginItem
    let bridge: PluginBridge
    private weak var state: EditorState?
    private var ctx: JSContext?
    private let box = ExceptionBox()
    private var lastError = ""

    init(item: PluginItem, state: EditorState) {
        self.item = item
        self.state = state
        self.bridge = PluginBridge(state: state, pluginName: item.title, assetDir: item.baseDir)
    }

    /// プラグインを読み込んで、OnActive を呼ぶ。読み込めなければ false
    func start() -> Bool {
        guard let c = LuaEngine.makeContext(bridge: bridge, box: box) else {
            report("JavaScript エンジンを起動できませんでした")
            return false
        }
        ctx = c
        bridge.setDeadline(Date().addingTimeInterval(3.0))
        let res = c.objectForKeyedSubscript("LuaHost")?.objectForKeyedSubscript("start")?
            .call(withArguments: [item.source, item.fileName])
        bridge.setDeadline(nil)
        let r = parse(res)
        if !r.ok {
            report(r.error.isEmpty ? "プラグインを読み込めませんでした" : r.error)
            ctx = nil
            return false
        }
        call("OnActive")
        return true
    }

    /// イベントを1つ呼ぶ (OnClick / OnDragStart / OnDragMove / OnDragEnd / OnActive / OnDeactive)。プラグインに無いイベントは何もしない
    func call(_ name: String) {
        guard let c = ctx else { return }
        box.text = ""
        bridge.setDeadline(Date().addingTimeInterval(2.0))
        let res = c.objectForKeyedSubscript("LuaHost")?.objectForKeyedSubscript("call")?.call(withArguments: [name])
        bridge.setDeadline(nil)
        bridge.flushMain()                                     // 書き換えを画面に反映する (1イベント = 1回)
        let r = parse(res)
        if r.ok {
            lastError = ""
            return
        }
        if name == "OnDeactive" { return }                      // 終わるときのエラーは、気にしない
        if r.aborted {
            report(name + " に時間が掛かりすぎたので止めました")
        } else {
            report(name + ": " + r.error)
        }
    }

    /// 終了。OnDeactive を呼んで、エンジンを手放す
    func stop() {
        call("OnDeactive")
        bridge.cancel.cancel()
        ctx = nil
    }

    /// 触れている位置 (レーン上) を、プラグインの GetClickX / GetClickBeat / GetClickBeatFree に渡す
    func setClick(_ p: CGPoint, g: LaneGeo, state st: EditorState) {
        let x = max(0.0, min(255.0, g.xOf(p.x)))
        let free = max(0.0, g.beatOf(p.y))
        bridge.setClick(x: x, snapped: st.snapBeat(free), free: free)
    }

    private func parse(_ v: JSValue?) -> (ok: Bool, called: Bool, aborted: Bool, error: String) {
        guard let s = v?.toString(),
              let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (false, false, false, box.text.isEmpty ? "実行結果を読み取れませんでした" : box.text)
        }
        return ((obj["ok"] as? Bool) ?? false,
                (obj["called"] as? Bool) ?? false,
                (obj["aborted"] as? Bool) ?? false,
                (obj["error"] as? String) ?? "")
    }

    /// エラーを画面に出す (同じメッセージが続けて出るときは、1回だけ)
    private func report(_ msg: String) {
        if msg == lastError { return }
        lastError = msg
        state?.showToast("「" + item.title + "」: " + msg)
    }
}
