import Foundation

// MARK: - effect (scroll / jump) のぶんだけ譜面の流れ方を変える「表示位置」の関数
//
// ノーツが画面のどこにいるかは、「その時刻の表示位置 P(t) − 今の表示位置 P(now)」で決まる (単位は秒。
// effect が無ければ P(t) = t で、従来どおり「判定までの残り秒」がそのまま画面の高さになる)。
//
//   ・scroll: その時刻から、P の進み方が scroll 倍になる (初期値 1.0)。0 で止まり、マイナスで逆走する
//   ・jump:   その時刻のノーツ (と「今」) の表示位置が、一気に先へ飛ぶ。飛ぶ距離は
//               jump (ms) ÷ 1000 × その時の scroll  [秒ぶんの距離]
//             (jump 1000 = 「1 秒間に scroll で進む距離」ぶん。scroll が 0 なら飛ばない / 2 なら 2 倍飛ぶ)。
//             時刻がその手前にあるノーツとの間が、画面上で大きく離れる (=「中継点を画面の外へ飛ばす」使い方ができる)
//
// 判定は時刻で決まる (core は effect を知らない)。変わるのは見た目だけ。
// 本家の挙動を、noteの解説と、実際の仕様 (jump は ms 単位で scroll の値に比例する) のとおりに再現している。

struct EffectMap: Sendable {
    /// 区間 k は、時刻 starts[k] から次の starts[k+1] の手前まで (最初の effect より前は scroll 1.0 で P(t) = t)
    let starts: [Double]
    let bases: [Double]         // 区間の頭の P (その時刻の jump を足したあと)
    let slopes: [Double]        // 区間の scroll
    /// 最初に P が減る (scroll < 0 / jump < 0) 時刻。減らないなら +infinity。
    /// 減らない譜面では、「判定を過ぎたものは必ず判定バーより下」なので、時刻による描画の打ち切りは要らない
    let negFrom: Double

    static let none = EffectMap(starts: [], bases: [], slopes: [], negFrom: .infinity)

    var isEmpty: Bool { starts.isEmpty }

    /// effect 1 つぶん。t は秒、jumpMs は mc に書かれた jump の値 (ms)
    struct Event {
        var t: Double
        var scroll: Double?
        var jumpMs: Double
    }

    static func make(_ events: [Event]) -> EffectMap {
        if events.isEmpty { return .none }
        let sorted = events.sorted { $0.t < $1.t }
        // 同じ時刻の effect は 1 つにまとめる (scroll は後に書かれたもの、jump は合計)。
        // 同じ時刻に scroll と jump があるときは、scroll を先に変えてから、その値で jump する
        var merged: [Event] = []
        for e in sorted {
            if var last = merged.last, abs(last.t - e.t) < 1e-9 {
                if let s = e.scroll { last.scroll = s }
                last.jumpMs += e.jumpMs
                merged[merged.count - 1] = last
            } else {
                merged.append(e)
            }
        }
        var starts: [Double] = []
        var bases: [Double] = []
        var slopes: [Double] = []
        var slope = 1.0
        var neg = Double.infinity
        for e in merged {
            let pHere: Double
            if let ls = starts.last, let lb = bases.last, let lk = slopes.last {
                pHere = lb + lk * (e.t - ls)
            } else {
                pHere = e.t                              // 最初の effect より前は P(t) = t
            }
            if let s = e.scroll { slope = s }
            let jumpSec = e.jumpMs / 1000 * slope             // jump は scroll に比例する (scroll 0 なら飛ばない)
            if slope < 0 || jumpSec < 0 { neg = min(neg, e.t) }
            starts.append(e.t)
            bases.append(pHere + jumpSec)
            slopes.append(slope)
        }
        return EffectMap(starts: starts, bases: bases, slopes: slopes, negFrom: neg)
    }

    /// 時刻 t の表示位置
    func p(_ t: Double) -> Double {
        guard let first = starts.first, t >= first else { return t }
        // t 以下で最後の区間を二分探索
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return bases[lo] + slopes[lo] * (t - starts[lo])
    }

    /// 表示位置が lo...hi に入る時刻の範囲 (区間ごとに高々 1 つ。互いに重ならない)。
    /// 画面に見えているノーツだけを拾うのに使う (scroll / jump で、時刻の順と画面の順は一致しないので)
    func timeRanges(p lo: Double, _ hi: Double) -> [(lo: Double, hi: Double)] {
        guard let first = starts.first else { return [(lo: lo, hi: hi)] }
        var out: [(lo: Double, hi: Double)] = []
        if lo < first { out.append((lo: lo, hi: min(hi, first))) }          // 最初の effect より前: P(t) = t
        for k in 0..<starts.count {
            let ts = starts[k]
            let te = k + 1 < starts.count ? starts[k + 1] : Double.infinity
            let s = slopes[k]
            let b = bases[k]
            if s == 0 {
                if b >= lo && b <= hi { out.append((lo: ts, hi: te)) }      // 止まっている間は、全部が同じ位置に重なる
                continue
            }
            var t1 = ts + (lo - b) / s
            var t2 = ts + (hi - b) / s
            if s < 0 { swap(&t1, &t2) }
            let a = max(t1, ts)
            let c = min(t2, te)
            if a <= c { out.append((lo: a, hi: c)) }
        }
        return out
    }
}
