import SwiftUI

// MARK: - FX 表示 (擬似テストプレイ)
//
// 左上のズームボタンの下の「FX」ボタンで切り替える。ON のあいだ、レーンは次のように描かれる (描画は RenderersFX.swift の `drawFX`)。
//   ・slide の点 (seg の丸) を出さない
//   ・effect (scroll / jump) を反映する。ノーツの高さは、テストプレイと同じ「表示位置 P(t) − P(今)」で決まる
//     (jump がマイナスなら、その時刻で、奥側へぴょいんと戻る。計算は Effects.swift の `EffectMap` をテストプレイと共有)
//   ・判定を過ぎたノーツ (時刻が今より前) は出さない (テストプレイでは、叩いたノーツが消えるのと同じ)
// 見るだけの表示で、編集はできない (編集ツールを使うときは FX を切る)。再生中も、そのまま流れる。
// 保存はしない (開くたびに OFF)。

extension EditorState {
    /// FX 表示で使う EffectMap。effect か BPM を触ったときだけ作り直し、それ以外は使い回す
    /// (毎フレーム呼ばれるので、中身が同じかどうかは軽いハッシュで調べる。件数は多くても数千)
    var fxEffectMap: EffectMap {
        var h = Hasher()
        for e in chart.effects {
            h.combine(e.beat)
            h.combine(e.kind == .scroll)
            h.combine(e.value)
        }
        for t in chart.times {
            h.combine(t.beat)
            h.combine(t.bpm)
        }
        let key = h.finalize()
        if fxKey == key { return fxCache }

        var events: [EffectMap.Event] = []
        events.reserveCapacity(chart.effects.count)
        for e in chart.effects.sorted(by: { $0.beat < $1.beat }) {
            // テストプレイ (MalodyChartBuilder) と同じ作り方。jump は ms の単位で、scroll との掛け算は EffectMap 側でする
            events.append(EffectMap.Event(t: timeMap.sec(atBeat: e.beat.value),
                                          scroll: e.kind == .scroll ? e.value : nil,
                                          jumpMs: e.kind == .jump ? e.value : 0))
        }
        fxCache = EffectMap.make(events)
        fxKey = key
        return fxCache
    }

    func toggleFX() { setFX(!fxMode) }

    /// FX 表示の ON / OFF。ON にするときは、編集モードを抜ける (FX 表示のあいだは編集ツールが使えないため)
    func setFX(_ on: Bool) {
        if fxMode == on { return }
        if on {
            if editing { leaveEdit() }
            popup = .none
            showToast("FX: scroll / jump を反映して表示します (見るだけ。編集するときは FX を切ってください)")
        }
        fxMode = on
    }

    /// 編集モードを抜ける (右ボタン列の Back と同じ後始末)
    func leaveEdit() {
        advOpen = false
        stopInteractivePlugin()
        if tool == .plugin { tool = .unselected }
        editing = false
        tool = .unselected
        selectedIDs = []
        ghost = nil
        popup = .none
    }
}
