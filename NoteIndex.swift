import Foundation

// ノーツを「拍の範囲」で素早く探すための索引。
//
// 以前は、描画 (毎フレーム)・タッチの当たり判定・重複チェックなどが、全ノーツを先頭から順に調べていた。
// この索引は、各ノーツが占める拍の範囲 [lo, hi] (スライドは seg も含む) を lo の昇順に並べ、
// 二分探索で「いま見えている範囲に掛かるノーツ」だけを取り出す。
//
//  ・探す時間は O(log N + 見つかった数)。譜面が大きくなっても、画面に見える分しか調べない
//  ・スライドの seg が時系列でなく並んでいても (バグスライド・逆走・マイナス beat) 正しく見つかる
//    (範囲は seg の最小〜最大で持つので、始点より前に伸びるスライドも拾える)
//  ・譜面が書き換わったら、この索引は捨てて新しいものを作る (EditorState が chart.notesRevision を見て入れ替える)。
//    中身 (並べ替え・ID の辞書) は、探すときまで作らない。編集のたびには作らない
//  ・ノーツの配列は持たない (持つと、編集のたびに配列全体のコピーが起きてしまうため)。
//    探すときに、その譜面の配列を渡す (索引を作ったときと同じ譜面であること)

final class NoteIndex {
    // lo の昇順に並べたもの (添字 k = 並び順の k 番目)
    private var los: [Double] = []
    private var his: [Double] = []
    private var order: [Int32] = []        // k 番目が、元の配列の何番目のノーツか
    private var maxHi: [Double] = []       // 二分木 (添字 = 中央の位置) の部分木の hi の最大値
    private var spatialBuilt = false
    private var builtCount = -1

    private var idMap: [NoteID: Int]? = nil

    init() {}

    private func buildSpatial(_ notes: [Note]) {
        spatialBuilt = true
        builtCount = notes.count
        struct Ent {
            var lo: Double
            var hi: Double
            var idx: Int32
        }
        var ents: [Ent] = []
        ents.reserveCapacity(notes.count)
        for i in notes.indices {
            let n = notes[i]
            let s = n.beat.value
            var lo = s
            var hi = s
            if !n.segs.isEmpty {
                for g in n.segs {
                    let v = s + g.beat.value
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            ents.append(Ent(lo: lo, hi: hi, idx: Int32(truncatingIfNeeded: i)))
        }
        // lo が同じなら、元の並びの順 (結果が毎回同じになるように)
        ents.sort { $0.lo != $1.lo ? $0.lo < $1.lo : $0.idx < $1.idx }
        los.reserveCapacity(ents.count)
        his.reserveCapacity(ents.count)
        order.reserveCapacity(ents.count)
        for e in ents {
            los.append(e.lo)
            his.append(e.hi)
            order.append(e.idx)
        }
        maxHi = [Double](repeating: -Double.infinity, count: ents.count)
        _ = build(0, ents.count)
    }

    /// 区間 [l, r) の木を作り、その hi の最大値を返す
    private func build(_ l: Int, _ r: Int) -> Double {
        if l >= r { return -Double.infinity }
        let m = (l + r) >> 1
        let a = build(l, m)
        let b = build(m + 1, r)
        let v = max(his[m], max(a, b))
        maxHi[m] = v
        return v
    }

    /// 範囲 [lo, hi] (拍) に掛かるノーツの、元の配列での添字を、小さい順に返す。
    /// 「掛かる」= そのノーツの範囲 [始点〜seg の最小・最大] が [lo, hi] と重なる。
    func indices(lo: Double, hi: Double, in notes: [Note]) -> [Int] {
        var out: [Int] = []
        if notes.isEmpty || hi < lo || lo.isNaN || hi.isNaN { return out }
        if !spatialBuilt || builtCount != notes.count { buildSpatial(notes) }
        collect(0, notes.count, lo, hi, &out)
        out.sort()
        return out
    }

    private func collect(_ l: Int, _ r: Int, _ qLo: Double, _ qHi: Double, _ out: inout [Int]) {
        if l >= r { return }
        let m = (l + r) >> 1
        if maxHi[m] < qLo { return }                    // この部分木は、どれも範囲より手前で終わる
        collect(l, m, qLo, qHi, &out)
        if los[m] > qHi { return }                      // 右の部分木は、どれも範囲より後ろで始まる
        if his[m] >= qLo { out.append(Int(order[m])) }
        collect(m + 1, r, qLo, qHi, &out)
    }

    /// ノーツ ID → 元の配列での添字。初めて使うときに辞書を作る
    func position(ofID id: NoteID, in notes: [Note]) -> Int? {
        if idMap == nil {
            var m: [NoteID: Int] = [:]
            m.reserveCapacity(notes.count)
            for i in notes.indices.reversed() { m[notes[i].id] = i }     // 同じ ID があれば、前にある方 (firstIndex と同じ)
            idMap = m
        }
        return idMap?[id]
    }
}
