import SwiftUI
import UIKit

// MARK: - META (Back / Information / More / Review / Quit)
//
// 本家は、META を押すとアイコンが 5〜6 個 (Back / Information / Delete all / Upload / More / Quit) 出て、
// More の先にもう一段メニューがある。ここでは使う 4 つだけにして、階層は作らない:
//   ・Information … 右ウィンドウ (BPM list / Effect list と同じ滑って入る窓) で曲名・作者・オフセットなどを編集
//   ・More (•••)  … 押した瞬間に mcz を作って、共有シートを出す (「譜面をパッケージ化してエクスポート」)
//   ・Review      … 通常ノーツ (tap) 同士の重なり / 近すぎ (同じ拍で、端と端の間隔が座標 1 マス未満。座標は 0...255 の 256 分割) を探して、いちばん早い拍へ飛ぶ。無ければ「0 issue found」
//   ・Quit        … 押した瞬間に保存して、エディタを閉じてファイル選択へ戻る
// 右ボタン列の入れ替わり・名前 (Back / Information / ...) の出方は EDIT と同じ (EditorView.swift の RightPanel)。

extension EditorState {
    /// META を押す。右ボタン列が META 用の 5 つ (Back / Information / More / Review / Quit) に入れ替わる
    func openMetaMenu() {
        popup = .none
        metaOpen = true
    }

    /// META の列から、いつもの列に戻る
    func closeMetaMenu() {
        metaOpen = false
    }

    /// More (•••): mcz を作って、すぐ共有シート (保存 / AirDrop / ファイルなど) を出す
    func shareMCZNow() {
        do {
            let url = try exportPackage()
            MCZSharer.present(url: url)
        } catch {
            showToast("エクスポートに失敗しました: \(error.localizedDescription)")
        }
    }

    /// Review: 通常ノーツ (tap) 同士の「重なり / 近すぎ」を探す。
    ///   ・同じ拍にある tap と tap で、端と端の間隔が 1 マス未満のものが対象。「1 マス」は Grid lines ではなく、
    ///     レーンの座標 (0...255) の 1 単位 (256 分割の 1 マス)。
    ///     完全に重なっている・一部だけ重なっている・ぴったり接している (間隔 0)・1 マスに届かず空いている、のどれも見つける
    ///   ・調べるのは tap どうしだけ。wipe やスライド (始点・seg) は、tap と重なっていても、wipe 同士・スライド同士でも調べない
    ///   ・見つかったら、いちばん早い拍へ飛ぶ (再生中なら止めてから飛ぶ)。複数あっても、時系列で最初の 1 か所だけ
    ///   ・見つからなければ、画面の上に「0 issue found」が一瞬だけ出る (`reviewNoticeTick` を進める。表示は ReviewNotice.swift)
    func reviewChart() {
        if let beat = firstOverlapBeat() {
            if isPlaying { pause() }
            setViewBeat(beat.value)
        } else {
            reviewNoticeTick &+= 1
        }
    }

    /// レーンの枠 (x: 0...255) から端がはみ出しているノーツを探す (SETTING の「はみ出しノーツを数える」用)。
    /// 判定は描画 (Renderers) と同じ: 端 = 中心 x ± w/2。スライドは始点と各 seg の絶対 x (始点 + 相対 x) で判定する。
    /// 描画はデータに忠実なので、データが範囲内に収まっていれば、ノーツが枠の外に描かれることはない
    func overflowNotes() -> (count: Int, firstBeat: Beat?) {
        var count = 0
        var first: Beat? = nil
        for n in chart.notes {
            let half = Double(n.w) / 2
            var bad = Double(n.x) - half < 0 || Double(n.x) + half > 255
            if !bad {
                for s in n.segs {
                    let ax = Double(n.x + s.x)
                    if ax - half < 0 || ax + half > 255 { bad = true; break }
                }
            }
            if bad {
                count += 1
                if first == nil || n.beat < first! { first = n.beat }
            }
        }
        return (count, first)
    }

    /// はみ出しているノーツを、幅 (w) は変えずに中心を内側へ寄せて、枠に収める (SETTING の「はみ出しを枠に収める」用)。
    /// スライドは seg の相対位置を保ったまま始点ごとずらす。Undo で戻せる。
    /// 幅 + seg の広がりが 255 を超えるノーツは、寄せても収まりきらない (その場合は数え直して残数を伝える)
    func fixOverflowNotes() {
        let (count, _) = overflowNotes()
        if count == 0 {
            showToast("はみ出しているノーツはありません", seconds: 2.6)
            return
        }
        pushUndo()
        for i in chart.notes.indices {
            let n = chart.notes[i]
            var relMin = 0
            var relMax = 0
            for s in n.segs {
                relMin = min(relMin, s.x)
                relMax = max(relMax, s.x)
            }
            chart.notes[i].x = laneFittedHead(n.x, width: n.w, relMin: relMin, relMax: relMax, origHead: nil)
        }
        chartChanged()
        let (rest, _) = overflowNotes()
        if rest == 0 {
            showToast("\(count) 個のノーツを枠に収めました (Undo で戻せます)", seconds: 2.6)
        } else {
            showToast("\(count) 個を内側へ寄せました。幅が広すぎて収まりきらないものが \(rest) 個あります", seconds: 3.2)
        }
    }

    /// 同じ拍の tap 同士で、端と端の間隔が 1 マス未満のところのうち、いちばん早い拍。無ければ nil。
    /// 数え方は、描画 (Renderers) と同じ: スライド以外で、wipe でないものは tap。ノーツの両端は x ± w / 2。
    /// 「1 マス」は、Grid lines の 1 マスではなく、レーンの座標 (0...255) の 1 単位 (256 分割の 1 マス)。
    /// w が奇数のときは端が .5 になるが、Double で正確に表せるので、そのまま比べてよい (間隔 0.5 は 1 未満なので見つかる)
    private func firstOverlapBeat() -> Beat? {
        let minGap = 1.0
        struct Tap {
            let beat: Beat
            let left: Double
            let right: Double
        }
        var taps: [Tap] = []
        taps.reserveCapacity(chart.notes.count)
        for n in chart.notes where !n.isSlide && !n.isWipe {
            let half = Double(n.w) / 2
            taps.append(Tap(beat: n.beat, left: Double(n.x) - half, right: Double(n.x) + half))
        }
        // 拍の順に並べ、同じ拍の中では左端の順に並べる。すると、同じ拍の中で「それまでの右端のいちばん大きい値」と
        // 次の左端を比べるだけで、どの 2 つの組も調べたことになる (一方が他方を丸ごと含んでいる場合も、間隔がマイナスになって見つかる)。
        // 拍の順なので、最初に見つかった拍がいちばん早い拍
        taps.sort { $0.beat != $1.beat ? $0.beat < $1.beat : $0.left < $1.left }
        var i = 0
        while i < taps.count {
            let beat = taps[i].beat
            var maxRight = taps[i].right
            var j = i + 1
            while j < taps.count, taps[j].beat == beat {
                if taps[j].left - maxRight < minGap { return beat }
                maxRight = max(maxRight, taps[j].right)
                j += 1
            }
            i = j
        }
        return nil
    }

    /// Quit: 再生を止めて、保存して、エディタを閉じる (確認ダイアログなし)
    func quitEditor() {
        if isPlaying { pause() }
        saveNow()
        if diskConflict { return }     // Malody 側が書き換えていて保存を止めたとき: 確認ダイアログの返事を待つ (閉じると、このエディタの編集が消える)
        onClose?()
    }
}

// MARK: - 共有シートを、いちばん手前の画面から直接出す

/// mcz の共有シート。SwiftUI の ShareLink は「もう 1 回タップ」が要るので、UIKit の UIActivityViewController を直接出す。
/// iPad ではポップオーバーの基準 (sourceView) が無いとクラッシュするので、右ボタン列の More のあたりを基準にしている
enum MCZSharer {
    static func present(url: URL) {
        guard let top = topViewController() else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            let b = top.view.bounds
            pop.sourceView = top.view
            // META の列の 3 番目 (More) の中心
            // 右ボタン列の寸法は設計画面 (高さ 820pt) の値なので、実際の画面の倍率をかける (DesignCanvas)
            let s = DesignScreen.scale(forHeight: b.height)
            pop.sourceRect = CGRect(x: b.maxX - RightPanel.width * s / 2,
                                    y: (RightPanel.edgeInset + RightPanel.slotPitch * 2.5) * s,
                                    width: 1, height: 1)
            pop.permittedArrowDirections = [.right]
        }
        top.present(vc, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
