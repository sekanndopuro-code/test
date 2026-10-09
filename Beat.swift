import Foundation

func gcdInt(_ a: Int, _ b: Int) -> Int {
    var x = abs(a)
    var y = abs(b)
    while y != 0 {
        let t = x % y
        x = y
        y = t
    }
    return x == 0 ? 1 : x
}

/// Malody の beat 表記 [整数部, 分子, 分母] (= 整数部 + 分子/分母)。
/// 表示も保存も mc ファイルと同じ「0拍始まり」。
struct Beat: Comparable, Hashable {
    var m: Int
    var n: Int
    var d: Int

    init(_ m: Int, _ n: Int, _ d: Int) {
        self.m = m
        self.n = n
        self.d = max(1, d)
    }

    static let zero = Beat(0, 0, 1)

    var numerator: Int { m * d + n }
    var value: Double { Double(numerator) / Double(d) }
    /// 保存用の [整数部, 分子, 分母]。
    /// 負の拍は「整数部にマイナスをつけ、分子は 0 以上」にする (例: -11.5 拍 → [-12, 2, 4])。
    /// [0, -2, 4] のように分子にマイナスをつける書き方だと、本家 Malody で不具合になるため、保存のときに直す
    var json: [Int] {
        if n < 0 {
            let t = Beat.ticks(numerator, den: d)
            return [t.m, t.n, t.d]
        }
        return [m, n, d]
    }
    var label: String { "\(m):\(n)/\(d)" }

    init?(json: Any?) {
        guard let arr = json as? [NSNumber], arr.count >= 3 else { return nil }
        self.init(arr[0].intValue, arr[1].intValue, arr[2].intValue)
    }

    /// t/den 拍 (負数も floor で正しく分解)
    static func ticks(_ t: Int, den: Int) -> Beat {
        let dd = max(1, den)
        let q = Int((Double(t) / Double(dd)).rounded(.down))
        return Beat(q, t - q * dd, dd)
    }

    /// 1/den 拍に最も近い Beat
    static func nearest(_ v: Double, den: Int) -> Beat {
        ticks(Int((v * Double(max(1, den))).rounded()), den: den)
    }

    // 比較: 分母が大きい拍 (Lua プラグインが 1/1048576 拍などを持ち込む) どうしでも、掛け算が桁あふれして落ちないようにする。
    // 桁あふれしそうなときだけ、Double で比べる (通常の値では、これまでと同じ整数どうしの比較)
    static func == (a: Beat, b: Beat) -> Bool {
        let l = a.numerator.multipliedReportingOverflow(by: b.d)
        let r = b.numerator.multipliedReportingOverflow(by: a.d)
        if l.overflow || r.overflow { return a.value == b.value }
        return l.partialValue == r.partialValue
    }

    static func < (a: Beat, b: Beat) -> Bool {
        let l = a.numerator.multipliedReportingOverflow(by: b.d)
        let r = b.numerator.multipliedReportingOverflow(by: a.d)
        if l.overflow || r.overflow { return a.value < b.value }
        return l.partialValue < r.partialValue
    }

    func hash(into h: inout Hasher) {
        let g = gcdInt(numerator, d)
        h.combine(numerator / g)
        h.combine(d / g)
    }

    /// 2つの分母の最小公倍数。大きくなりすぎる (2^40 超) ときは nil
    private static func commonDen(_ a: Beat, _ b: Beat) -> Int? {
        let q = (a.d / gcdInt(a.d, b.d)).multipliedReportingOverflow(by: b.d)
        if q.overflow || q.partialValue > (1 << 40) { return nil }
        return q.partialValue
    }

    static func + (a: Beat, b: Beat) -> Beat {
        guard let l = commonDen(a, b) else { return nearest(a.value + b.value, den: 1_048_576) }
        return ticks(a.numerator * (l / a.d) + b.numerator * (l / b.d), den: l)
    }

    static func - (a: Beat, b: Beat) -> Beat {
        guard let l = commonDen(a, b) else { return nearest(a.value - b.value, den: 1_048_576) }
        return ticks(a.numerator * (l / a.d) - b.numerator * (l / b.d), den: l)
    }
}
