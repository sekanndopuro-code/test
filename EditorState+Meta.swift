import SwiftUI
import UIKit

// MARK: - META (Back / Information / More / Review / Quit)
//
// 本家は、META を押すとアイコンが 5〜6 個 (Back / Information / Delete all / Upload / More / Quit) 出て、
// More の先にもう一段メニューがある。ここでは使う 4 つだけにして、階層は作らない:
//   ・Information … 右ウィンドウ (BPM list / Effect list と同じ滑って入る窓) で曲名・作者・オフセットなどを編集
//   ・More (•••)  … 押した瞬間に mcz を作って、共有シートを出す (「譜面をパッケージ化してエクスポート」)
//   ・Review      … 多重ノーツ (同じ拍・同じ中心 x に、tap と tap / tap と wipe が重なっているところ) を探して、いちばん早い拍へ飛ぶ。無ければ「0 issue found」
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

    /// Review: 多重ノーツ (拍も中心 x も全く同じ位置に重なっている tap と tap / tap と wipe) を探す。
    ///   ・見つかったら、いちばん早い拍へ飛ぶ (再生中なら止めてから飛ぶ)。複数あっても、時系列で最初の 1 か所だけ
    ///   ・見つからなければ、画面の上に「0 issue found」が一瞬だけ出る (`reviewNoticeTick` を進める。表示は ReviewNotice.swift)
    ///   ・スライド (seg のあるノーツ) は、始点も seg も調べない。wipe と wipe の重なりも調べない
    func reviewChart() {
        if let beat = firstOverlapBeat() {
            if isPlaying { pause() }
            setViewBeat(beat.value)
        } else {
            reviewNoticeTick &+= 1
        }
    }

    /// 同じ (拍, 中心 x) に、tap が 1 つ以上あり、tap + wipe が合わせて 2 つ以上あるところのうち、いちばん早い拍。無ければ nil。
    /// 数え方は、描画 (Renderers) と同じ: スライド以外で、wipe でないものは tap
    private func firstOverlapBeat() -> Beat? {
        struct Spot: Hashable {
            let beat: Beat
            let x: Int
        }
        var taps: [Spot: Int] = [:]
        var wipes: [Spot: Int] = [:]
        for n in chart.notes where !n.isSlide {
            let spot = Spot(beat: n.beat, x: n.x)
            if n.isWipe {
                wipes[spot, default: 0] += 1
            } else {
                taps[spot, default: 0] += 1
            }
        }
        var best: Beat? = nil
        for (spot, tapCount) in taps {
            // tap が 2 つ以上 (tap と tap)、または tap のところに wipe が 1 つ以上 (tap と wipe)
            guard tapCount >= 2 || (wipes[spot] ?? 0) >= 1 else { continue }
            if let b = best, b <= spot.beat { continue }
            best = spot.beat
        }
        return best
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
