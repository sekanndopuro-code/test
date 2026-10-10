import SwiftUI

// Adv. メニューからプラグインを実行・停止する

extension EditorState {

    /// プラグインの Run() を実行する。
    /// 実行中は別スレッドで動き、譜面の変更は Undo 1回分にまとまる (↶ で丸ごと戻せる)
    func runPlugin(_ item: PluginItem) {
        guard !pluginRunning else { return }
        guard item.isRunnable else {
            showToast("このプラグインは実行できません")
            return
        }
        if isPlaying { pause() }
        popup = .none
        pluginRunning = true
        pluginLog = ""
        let title = item.title
        let bridge = PluginBridge(state: self, pluginName: title, assetDir: item.baseDir)
        pluginBridge = bridge
        LuaEngine.run(source: item.source, name: item.fileName, bridge: bridge) { [weak self] result in
            guard let self = self else { return }
            bridge.flushMain()
            self.pluginRunning = false
            self.pluginBridge = nil
            var log = bridge.takeLog()
            let unsupported = bridge.takeUnsupported()
            let notified = bridge.wasNotified()
            switch result {
            case .ok:
                // OK を押させるダイアログは出さない (作譜の邪魔になる)。画面の下の知らせだけにして、詳細は Adv. の「出力」欄に残す
                if unsupported.isEmpty {
                    // プラグイン自身が ShowMessage / ShowTip で知らせた後は、「実行しました」で上書きしない
                    if !notified { self.showToast("「\(title)」を実行しました") }
                } else {
                    let names = unsupported.joined(separator: ", ")
                    if !log.isEmpty && !log.hasSuffix("\n") { log += "\n" }
                    log += "[未対応] まだ対応していない関数が呼ばれたので、何もせずに通過しました: " + names + "\n"
                    if !notified { self.showPluginNotice("「\(title)」を実行しました (未対応の関数を通過: \(names))") }
                }
            case .aborted:
                self.showToast("「\(title)」を中断しました")
            case .failed(let msg):
                self.pluginDialog = PluginDialog(kind: .message, title: title + " — エラー", message: msg)
            }
            self.pluginLog = log
        }
    }

    /// 実行中のプラグインを止める (Lua のループの途中で止まる。ダイアログを出して待っているときは、閉じて再開する)
    func stopPlugin() {
        pluginBridge?.cancel.cancel()
        resolvePluginDialog(nil)
    }

    /// プラグインのダイアログに答える (OK / キャンセル)。nil = キャンセル
    func resolvePluginDialog(_ text: String?) {
        guard let d = pluginDialog else { return }
        pluginDialog = nil
        d.finish(text)
    }

    // MARK: - 「順番に選択」(Order ボタン)

    /// 「順番に選択」ツールでレーンをタップしたとき。
    /// ・スライドをタップ: 番号 (1, 2, 3…) を付けて、順番に加える。結合系プラグインが、この順番を使う
    /// ・すでに順番に入れたスライドは当たり判定から外す。重なっているスライドは、同じ場所をもう一度タップすると下のものが選べる
    /// ・スライドの無い所をタップ: 順番を全部リセットする (ほかのツールの「何も無い所をタップで選択解除」と同じ)
    func orderTap(at p: CGPoint, g: LaneGeo) {
        var hitAny = false
        for i in chart.notes.indices.reversed() {
            let n = chart.notes[i]
            if !n.isSlide || !noteHit(n, at: p, g: g) { continue }
            hitAny = true
            if orderIDs.contains(n.id) { continue }
            orderIDs.append(n.id)
            showToast(orderIDs.count == 1 ? "1 番目を選択 (本体)" : "\(orderIDs.count) 番目を追加")
            return
        }
        if hitAny {
            showToast("このスライドは選択済みです")
        } else if !orderIDs.isEmpty {
            orderIDs = []
            showToast("順番に選択をリセットしました")
        }
    }

    // MARK: - 操作型プラグイン (PluginType 2。例: GizaSlide)

    /// Adv. メニューで操作型プラグインを押したとき。アクティブにする (OnActive)。すでにアクティブなら、終わらせる (OnDeactive)
    /// アクティブの間、レーンのタッチは、そのプラグインの OnClick / OnDragStart / OnDragMove / OnDragEnd に渡る
    func toggleInteractivePlugin(_ item: PluginItem) {
        if activePluginID == item.id {
            stopInteractivePlugin()
            if tool == .plugin { tool = .unselected }
            return
        }
        stopInteractivePlugin()
        if isPlaying { pause() }
        popup = .none
        pluginSprites = []
        let session = PluginSession(item: item, state: self)
        pluginSession = session
        activePluginID = item.id
        tool = .plugin
        if !session.start() {
            stopInteractivePlugin()
            if tool == .plugin { tool = .unselected }
        }
    }

    /// 動いている操作型プラグインを終わらせる (OnDeactive を呼んで、プラグインが出した画像を消す)
    func stopInteractivePlugin() {
        guard let s = pluginSession else { return }
        pluginSession = nil
        activePluginID = nil
        s.stop()
        pluginSprites = []
        pluginDragStarted = false
    }

    /// 操作型プラグインのツールでのタッチ。Malody のイベントに合わせて呼び分ける:
    ///   ・動かさずに離した → OnClick
    ///   ・動かした → OnDragStart (指を置いた位置で1回) → OnDragMove (動くたび) → OnDragEnd (離したとき)
    /// プラグインは GetClickX / GetClickBeat / GetClickBeatFree で、そのときの位置を読む
    func pluginTouch(start: CGPoint, current: CGPoint, g: LaneGeo, phase: LanePhase) {
        guard let session = pluginSession else { return }
        if phase == .began { pluginDragStarted = false }
        if !pluginDragStarted && dragMoved {
            pluginDragStarted = true
            session.setClick(start, g: g, state: self)         // OnDragStart は、指を置いた位置
            session.bridge.beginGesture()
            session.call("OnDragStart")
        }
        if pluginDragStarted {
            session.setClick(current, g: g, state: self)
            session.call("OnDragMove")
        }
        if phase == .ended {
            if pluginDragStarted {
                session.call("OnDragEnd")
            } else {
                session.setClick(current, g: g, state: self)
                session.bridge.beginGesture()
                session.call("OnClick")
            }
            pluginDragStarted = false
        }
    }
}
