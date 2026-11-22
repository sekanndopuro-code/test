// Malody Slide モード (mode 7) の「ゲームの核」。本家 (libmalodycpp.so) の仕様書 SLIDE_SPEC-7.md に合わせた実装。
// UIKit / AVFoundation には依存しない (Foundation だけ)。Linux の swiftc でも単体テストできる。
//
//  ・時刻モデル   : beat 値 = 拍(int) + float32(分子/分母)、タイミング連鎖、beat→ms (fma)、seg の 1/288 拍量子化、整数 ms 化
//  ・判定         : 頭の登録・頭のタイミング判定・追従(20 サンプル平均)・ティック・解放・見逃し・type 4 の自動判定
//  ・スコア       : グレード別の加点 (10 進で最後に 1 回 floor)・コンボ・ゲージ・Acc%・ランク
//  ・スクロール   : TimeCarrier 列 (基準 rate A = 33.3% 点) と P(t)。見た目だけで、判定には使わない
//
// 数字の出どころは仕様書の節番号をコメントに書いてある (§6.1 など)。

import Foundation

// MARK: - 数値変換 (ARM64 の命令と同じ丸め)

@inline(__always)
private func satInt32(_ v: Double) -> Int {
    if v.isNaN { return 0 }
    if v >= 2147483647 { return Int(Int32.max) }
    if v <= -2147483648 { return Int(Int32.min) }
    return Int(v)
}

/// fcvtzs: 0 方向への切り捨て (int32 に飽和)
@inline(__always)
func slideTrunc(_ v: Double) -> Int { satInt32(v.rounded(.towardZero)) }

/// fcvtas: 最も近い整数 (同点は 0 から遠い側。int32 に飽和)
@inline(__always)
func slideRoundAway(_ v: Double) -> Int { satInt32(v.rounded(.toNearestOrAwayFromZero)) }

// MARK: - 拍

/// [拍, 分子, 分母]。分母 0 は 1 として扱う (§3.1)
struct SlideBeat: Equatable {
    var m: Int
    var n: Int
    var d: Int

    init(_ m: Int, _ n: Int = 0, _ d: Int = 1) {
        self.m = m
        self.n = n
        self.d = d == 0 ? 1 : d
    }

    /// 分数は float32 で保持される (§2.3)
    var frac: Float { Float(Double(n) / Double(d)) }
    /// beatValue = (double)拍 + (double)(float32)分数 (§2.3 / 付録 B.2)
    var value: Double { Double(m) + Double(frac) }

    /// 辞書式の大小 (拍 int → 分数のクロス乗算)。本家のノーツ整列・タイミングレコード選択はこれ (§4.1 項目 4)
    static func lexLess(_ a: SlideBeat, _ b: SlideBeat) -> Bool {
        if a.m != b.m { return a.m < b.m }
        return a.n * b.d < b.n * a.d
    }
}

// MARK: - 譜面の生データ (エディタの ChartData から MalodyChartBuilder.swift が作る)

struct SlideRawChart {
    struct Time { var beat: SlideBeat; var bpm: Double; var delay: Double = 0 }
    struct Seg { var beat: SlideBeat; var x: Int }
    struct Note { var beat: SlideBeat; var x: Int; var w: Int; var type: Int?; var segs: [Seg] }
    struct Effect { var beat: SlideBeat; var scroll: Double?; var jump: Double? }

    var title = ""
    var times: [Time] = []
    var notes: [Note] = []
    var effects: [Effect] = []
    var offsetMs: Double = 0        // type 1 (BGM) の offset (ms)
}

// MARK: - タイミング

struct SlideTimingRec {
    var beat: SlideBeat
    var value: Double
    var ms: Double
    var delay: Double
    var rate: Double        // 60000 / bpm (ms / 拍)
}

// MARK: - ノーツ

final class SlideNote {
    static let flagNormal = 0x1
    static let flagSimul = 0x100
    static let flagType4 = 0x400
    static let flagSlide = 0x800

    let flags: Int
    let x: Int                  // 0...255 (uint8)
    let w: Int                  // 0...255 (uint8)
    let startMs: Int
    let endMs: Int
    let segRel: [Int]           // seg ごとの相対 ms (開始 ms からの整数差)
    let segX: [Int]             // seg ごとの x 相対変位 (int16)

    // 見た目 (P 空間。SlideChart が埋める)
    var pStart = 0.0
    var pEnd = 0.0
    var segDeltaP: [Double] = []    // 各 seg 点の「前の点からの P の差」(先頭の点は pStart から)
    var segP: [Double] = []         // 各 seg 点の P (絶対)
    var pMonotone = true            // pStart → seg の P が増え続ける (描く範囲を二分探索できる)
    var judgedSeg: [Bool] = []      // seg ごと: 触れる判定が追う経路の区間か (false = 戻る区間・同じ時刻の区間。見た目だけで、保持しても消費されない)
    var hasDecor = false            // 見た目だけの区間が、高さを持って 1 つでもある
    var cutP = -Double.infinity     // 保持で消費した帯の P (ここより手前は描かない。一度進んだら戻らない)

    // 判定の状態 (§8)
    var state = 0               // bit0 判定済み / bit2 保持中 / bit3 完了
    var nextTick = Int(Int32.max)
    var slot = -1               // スライドが追っているタッチのスロット (-1 = なし)
    var skipped = false         // 「途中から始める」ときに最初から飛ばしたノーツ
    var hit = false             // ミス以外で判定された (tap / type 4 のスプライトを消す合図。本家の toggle=1)
    var index = 0               // 整列後の番号

    // 追従誤差のリング (直近 20 回の評価)
    private var ring = [Float](repeating: 0, count: 20)
    private var ringHead = 0
    private var ringCount = 0
    private var ringSum = 0.0

    var isSlide: Bool { flags & SlideNote.flagSlide != 0 }
    var isType4: Bool { flags & SlideNote.flagType4 != 0 }
    var isNormal: Bool { flags & SlideNote.flagNormal != 0 }
    var holding: Bool { state & 4 != 0 }
    var completed: Bool { state & 8 != 0 }
    var judged: Bool { state & 1 != 0 }

    /// 追従の「切れる」しきい値: max(18, w>>1) (整数。§6.1)
    var threshold: Int { max(18, w >> 1) }

    init(flags: Int, x: Int, w: Int, startMs: Int, endMs: Int, segRel: [Int], segX: [Int]) {
        self.flags = flags
        self.x = x & 0xFF
        self.w = w & 0xFF
        self.startMs = startMs
        self.endMs = endMs
        self.segRel = segRel
        self.segX = segX
    }

    func pushSample(_ s: Float) -> Int {
        if ringCount == 20 {
            ringSum -= Double(ring[ringHead])
            ring[ringHead] = s
            ringHead = (ringHead + 1) % 20
        } else {
            ring[(ringHead + ringCount) % 20] = s
            ringCount += 1
        }
        ringSum += Double(s)
        // 平均 = 合計 / 現在のサンプル数 を 0 方向へ切り捨て (§6.3)
        return slideTrunc(ringSum / Double(ringCount))
    }

    func resetSamples() {
        ringHead = 0
        ringCount = 0
        ringSum = 0
    }

    func resetState() {
        state = 0
        nextTick = Int(Int32.max)
        slot = -1
        skipped = false
        hit = false
        cutP = -Double.infinity
        resetSamples()
    }

    /// seg の絶対 x を描画するときの値 (§10.1: 各点で先に byte 化してから float 化)
    func drawX(segIndex i: Int) -> Int {
        (x + (segX[i] & 0xFF)) & 0xFF
    }

    /// 軌跡 X(t) (§4.2 / 付録 B.5)。tAbs は絶対 ms (整数)
    func trajectoryX(_ tAbs: Int) -> Int {
        if tAbs < startMs { return x }
        if tAbs > endMs {
            guard let last = segX.last else { return x }
            return (x + (last & 0xFF)) & 0xFF
        }
        let rel = tAbs - startMs
        var i = 0
        while i < segRel.count {
            if rel <= segRel[i] { break }
            i += 1
        }
        if i >= segRel.count { return x }
        let rel0 = i == 0 ? 0 : segRel[i - 1]
        let x0 = i == 0 ? x : x + segX[i - 1]
        let rel1 = segRel[i]
        let x1 = x + segX[i]
        let r = Float(rel - rel0) / Float(rel1 - rel0)             // float32 の除算 (0/0 は NaN)
        let v = Double(x0).addingProduct(Double(x1 - x0), Double(r))   // fmadd
        // fcvtau: 最も近い整数 (同点は 0 から遠い側)、負と NaN は 0 → uxtb
        if v.isNaN || v <= 0 { return 0 }
        if v >= 4294967295 { return 0xFF }
        return Int(v.rounded(.toNearestOrAwayFromZero)) & 0xFF
    }
}

// MARK: - スクロール (TimeCarrier)

struct SlideCarrier {
    var startMs: Double
    var startPos: Double
    var rate: Float         // 位置 / ms
}

// MARK: - 譜面 (変換パス済み)

final class SlideChart {
    let title: String
    let offsetMs: Double
    let timing: [SlideTimingRec]
    let notes: [SlideNote]          // 整列済み (§4.1)
    let carriers: [SlideCarrier]
    let baseRate: Double            // A (§9.3)
    let lengthMs: Int               // 最後のノーツの終了 ms (最大)

    init?(raw: SlideRawChart) {
        // ---- タイミング (§2) ----
        // rate は読み込み順に求める (bpm <= 1e-6 は直前の rate を引き継ぐ)
        var parsed: [(rec: SlideTimingRec, order: Int)] = []
        var prevRate = 0.0
        for (i, t) in raw.times.enumerated() {
            if 1e-6 < t.bpm { prevRate = 60000.0 / t.bpm }
            parsed.append((SlideTimingRec(beat: t.beat, value: t.beat.value, ms: 0, delay: t.delay, rate: prevRate), i))
        }
        guard !parsed.isEmpty else { return nil }
        parsed.sort { a, b in
            if SlideBeat.lexLess(a.rec.beat, b.rec.beat) { return true }
            if SlideBeat.lexLess(b.rec.beat, a.rec.beat) { return false }
            return a.order < b.order
        }
        var recs = parsed.map { $0.rec }
        // ms の連鎖 (§2.2 / 付録 B.2。FUN_0036a084 を逆アセンブルして確認:
        //   先頭   : ms = beat値 × rate
        //   2 番目以降: ms = delay + fma(rate_前, beat値 − beat値_前, ms_前) )
        recs[0].ms = recs[0].value * recs[0].rate
        if recs.count > 1 {
            for i in 1..<recs.count {
                let p = recs[i - 1]
                let delta = recs[i].value - p.value
                recs[i].ms = recs[i].delay + p.ms.addingProduct(p.rate, delta)
            }
        }
        timing = recs
        title = raw.title
        offsetMs = raw.offsetMs

        // beat → ms (§2.3): 「拍がそれ以下で最後のレコード」を辞書式の順序で二分探索。最初より前は先頭で外挿
        func recordIndex(_ b: SlideBeat) -> Int {
            var lo = 0, hi = recs.count          // [lo, hi) のうち b 以下の最後を探す
            while lo < hi {
                let mid = (lo + hi) >> 1
                if SlideBeat.lexLess(b, recs[mid].beat) { hi = mid } else { lo = mid + 1 }
            }
            return max(0, lo - 1)
        }
        func beatToMs(_ b: SlideBeat, value: Double) -> Double {
            let r = recs[recordIndex(b)]
            return r.ms.addingProduct(r.rate, value - r.value)      // fmadd
        }

        // ---- ノーツ (§3, §4) ----
        struct Pending { var raw: SlideRawChart.Note; var order: Int }
        var pend: [Pending] = []
        for (i, n) in raw.notes.enumerated() where n.type != 1 { pend.append(Pending(raw: n, order: i)) }
        pend.sort { a, b in
            if SlideBeat.lexLess(a.raw.beat, b.raw.beat) { return true }
            if SlideBeat.lexLess(b.raw.beat, a.raw.beat) { return false }
            return a.order < b.order
        }
        var list: [SlideNote] = []
        list.reserveCapacity(pend.count)
        for p in pend {
            let n = p.raw
            let startMs = slideTrunc(beatToMs(n.beat, value: n.beat.value))        // fcvtzs
            if n.segs.isEmpty {
                let f = n.type == 4 ? SlideNote.flagType4 : SlideNote.flagNormal
                list.append(SlideNote(flags: f, x: n.x, w: n.w, startMs: startMs, endMs: startMs, segRel: [], segX: []))
            } else {
                var rel: [Int] = []
                var xs: [Int] = []
                rel.reserveCapacity(n.segs.count)
                xs.reserveCapacity(n.segs.count)
                for s in n.segs {
                    // 絶対 beat = ノーツ + seg (double 加算) を 1/288 拍に 2 段で量子化 (§4.1, 付録 B.3)
                    let sum = n.beat.value + s.beat.value
                    var bar = slideRoundAway(sum)
                    let frac = sum - Double(bar)
                    var cell = slideRoundAway(frac * 288.0)
                    if cell < 0 { bar -= 1; cell += 288 }
                    let qb = SlideBeat(bar, cell, 288)
                    let absMs = beatToMs(qb, value: Double(bar) + Double(Float(Double(cell) / 288.0)))
                    rel.append(slideTrunc(absMs) - startMs)                          // 整数同士の引き算
                    xs.append(Int(Int16(truncatingIfNeeded: s.x)))
                }
                let endMs = rel[rel.count - 1] + startMs                             // 最後の seg 基準 (最大ではない)
                list.append(SlideNote(flags: SlideNote.flagSlide, x: n.x, w: n.w, startMs: startMs, endMs: endMs,
                                      segRel: rel, segX: xs))
            }
        }
        for (i, n) in list.enumerated() { n.index = i }
        notes = list
        lengthMs = list.map { $0.endMs }.max() ?? 0

        // ---- 基準 rate A (§9.3) ----
        var a = recs[0].rate
        if let first = list.first, let last = list.last {
            let lo = Double(first.startMs)
            let hi = Double(last.endMs)           // ソート済みノーツ列の末尾要素 (最大ではない)
            var pairs: [(rate: Double, len: Double, order: Int)] = []
            var total = 0.0
            for i in recs.indices {
                let s = min(max(recs[i].ms, lo), hi)
                let e = min(max(i + 1 < recs.count ? recs[i + 1].ms : hi, lo), hi)
                let len = max(0, e - s)
                pairs.append((recs[i].rate, len, i))
                total += len
            }
            pairs.sort { $0.rate != $1.rate ? $0.rate < $1.rate : $0.order < $1.order }
            let thr = 0.33299999999999996 * total
            var cum = 0.0
            a = pairs[pairs.count - 1].rate
            for p in pairs {
                cum += p.len
                if cum > thr { a = p.rate; break }          // 「超えた」点 (ちょうど等しいだけでは進む)
            }
        }
        baseRate = a

        // ---- TimeCarrier (§9.4) ----
        // effect: 同じ拍の scroll と jump は 1 つのレコードにまとめる (エディタは 2 つに分けて持っているため)
        struct Fx { var ms: Double; var scroll: Double?; var jump: Double? }
        var fxList: [(fx: Fx, beat: SlideBeat, order: Int)] = []
        var lastBeat: SlideBeat?
        for (i, e) in raw.effects.enumerated() {
            if e.scroll == nil && e.jump == nil { continue }
            let ms = beatToMs(e.beat, value: e.beat.value)
            if let lb = lastBeat, lb == e.beat, !fxList.isEmpty {
                var f = fxList[fxList.count - 1].fx
                if e.scroll != nil { f.scroll = e.scroll }
                if e.jump != nil { f.jump = e.jump }
                fxList[fxList.count - 1].fx = f
            } else {
                fxList.append((Fx(ms: ms, scroll: e.scroll, jump: e.jump), e.beat, i))
            }
            lastBeat = e.beat
        }
        fxList.sort { a, b in
            if a.fx.ms != b.fx.ms { return a.fx.ms < b.fx.ms }
            return a.order < b.order
        }
        let fx = fxList.map { $0.fx }

        func rateFor(_ scroll: Double, _ timingRate: Double) -> Float {
            timingRate > 0 ? Float(scroll * a / timingRate) : 0
        }
        var out: [SlideCarrier] = []
        let t0 = recs[0]
        var scroll = 1.0
        var curTiming = t0
        let r0 = rateFor(scroll, t0.rate)
        var cur = SlideCarrier(startMs: t0.ms, startPos: t0.ms * Double(r0), rate: r0)
        var ei = 0
        var ti = 1
        func effectStep(_ e: Fx) {
            let pos = cur.startPos + Double(cur.rate) * (e.ms - cur.startMs)
            if let s = e.scroll { scroll = s }
            let r = rateFor(scroll, curTiming.rate)
            var sp = pos
            if let j = e.jump { sp += Double(r) * j }          // 更新後の rate で飛ぶ
            cur = SlideCarrier(startMs: e.ms, startPos: sp, rate: r)
            out.append(cur)
        }
        func timingStep(_ t: SlideTimingRec) {
            let pos = cur.startPos + Double(cur.rate) * (t.ms - cur.startMs)
            curTiming = t
            let r = rateFor(scroll, t.rate)
            cur = SlideCarrier(startMs: t.ms, startPos: pos, rate: r)
            out.append(cur)
        }
        var preEffects = false
        while ei < fx.count && fx[ei].ms < t0.ms {          // 先頭のタイミング点より前の effect は過去へ外挿
            effectStep(fx[ei])
            ei += 1
            preEffects = true
        }
        if preEffects { timingStep(t0) } else { out.append(cur) }
        while ti < recs.count || ei < fx.count {
            if ti < recs.count && (ei >= fx.count || recs[ti].ms <= fx[ei].ms) {    // 同じ ms はタイミングが先
                timingStep(recs[ti])
                ti += 1
            } else {
                effectStep(fx[ei])
                ei += 1
            }
        }
        // 開始 ms 順 (安定)
        carriers = out.enumerated().sorted { a, b in
            a.element.startMs != b.element.startMs ? a.element.startMs < b.element.startMs : a.offset < b.offset
        }.map { $0.element }

        // ---- ノーツの P_start / P_end / seg 点ごとの P の差 (§9.5) ----
        for n in notes {
            n.pStart = pStatic(n.startMs)
            n.pEnd = pStatic(n.endMs)
            var prev = n.pStart
            var d: [Double] = []
            var ps: [Double] = []
            d.reserveCapacity(n.segRel.count)
            ps.reserveCapacity(n.segRel.count)
            var mono = true
            var prefixMax = Int.min
            var judged: [Bool] = []
            var decor = false
            judged.reserveCapacity(n.segRel.count)
            for (idx, r) in n.segRel.enumerated() {
                let p = pStatic(n.startMs + r)
                d.append(p - prev)
                ps.append(p)
                if p < prev { mono = false }
                // 触れる判定が追う経路 (trajectoryX) は「それまでの最大より後ろへ進む seg」だけ。
                // 時間が戻る seg と同じ時刻の seg は、見た目だけの区間 (触れる判定がない)
                let onPath = idx == 0 || r > prefixMax
                judged.append(onPath)
                if !onPath && abs(p - prev) > 1e-9 { decor = true }
                prefixMax = max(prefixMax, r)
                prev = p
            }
            n.segDeltaP = d
            n.segP = ps
            n.pMonotone = mono
            n.judgedSeg = judged
            n.hasDecor = decor
        }
    }

    /// 静的な P(t) (§9.5): 開始 ms が (double)t + 1.0 以下で最大のキャリア (なければ先頭) を使う
    func pStatic(_ t: Int) -> Double {
        let key = Double(t) + 1.0
        let c = carriers[carrierIndex { $0 <= key }]
        return c.startPos + Double(c.rate) * (Double(t) - c.startMs)
    }

    /// 動的な P_now (§6.9 手順 2〜3): 開始 ms が t 以下 (許容なし) で最大のキャリア
    func pNow(_ t: Double) -> Double {
        let c = carriers[carrierIndex { $0 <= t }]
        return c.startPos + Double(c.rate) * (t - c.startMs)
    }

    private func carrierIndex(_ ok: (Double) -> Bool) -> Int {
        var lo = 0, hi = carriers.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if ok(carriers[mid].startMs) { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }
}

// MARK: - スコア (§7)

struct SlideScore {
    static let noCode: UInt32 = 0x4000_0000
    /// 判定レベル 0...4 の倍率 (百分率)
    static let levelPercent = [78, 85, 100, 110, 120]

    var level = 2                   // k
    var total = 0                   // スコア
    var combo = 0
    var maxCombo = 0
    var gaugeA = 100                // int 0...100
    var gaugeB: Float = 1.0         // 0...1 (HP バーの表示比率)
    var n2 = 0, n4 = 0, n8 = 0, n1 = 0

    var judgedCount: Int { n2 + n4 + n8 + n1 }

    /// Acc% (float32 のパイプライン。§7.1)
    var accPercent: Float {
        let num = 1000 * n2 + 750 * n4 + 400 * n8
        let den = 1000 * judgedCount
        if den == 0 { return 0 }
        return Float(UInt32(truncatingIfNeeded: num)) * 100.0 / Float(UInt32(truncatingIfNeeded: den))
    }

    /// ランク (0 = なし, 1...5)。§7.1
    var rank: Int {
        let t = judgedCount
        if t == 0 { return 0 }
        if n2 == t { return 1 }
        let a = accPercent
        if a > 95.0 && n1 == 0 { return 2 }
        if a > 90.0 { return 3 }
        if a > 80.0 { return 4 }
        if a > 70.0 { return 5 }
        return 0
    }

    private static func gradeOf(_ code: UInt32) -> Int {
        if code & 2 != 0 { return 2 }
        if code & 4 != 0 { return 4 }
        if code & 8 != 0 { return 8 }
        return 1
    }

    /// 頭のグレードを持つコードか (bit 0〜3 のどれか)
    static func isGradedHead(_ code: UInt32) -> Bool { code & 0xF != 0 && code < 0x100 }

    mutating func apply(_ code: UInt32) {
        if code == SlideScore.noCode { return }
        if SlideScore.isGradedHead(code) {
            let grade = SlideScore.gradeOf(code)
            let dA = grade == 2 ? 1 : grade == 4 ? -2 : grade == 8 ? -8 : -32
            let a2 = min(max(gaugeA + dA, 0), 100)
            gaugeA = a2
            let amount = grade == 2 ? 1000 : grade == 4 ? 750 : grade == 8 ? 400 : 0
            // 金額 × 倍率 × (A' + 100) / 100 を 10 進で厳密に計算し、最後に 1 回だけ切り捨て
            // (倍率は 0.01 刻みなので、百分率の整数で割り算なしに計算できる)
            let mul = SlideScore.levelPercent[min(max(level, 0), 4)]
            total += amount * mul * (a2 + 100) / 10000
            let k = Float(level + 1)
            let dB: Float = grade == 2 ? 0.012 : grade == 4 ? 0.004 : grade == 8 ? -0.02 * k : -0.05 * k
            gaugeB = min(max(gaugeB + dB, 0), 1)
            if grade == 1 { combo = 0 } else { combo += 1 }
            switch grade {
            case 2: n2 += 1
            case 4: n4 += 1
            case 8: n8 += 1
            default: n1 += 1
            }
        } else if code == 0x400 {                        // ティック
            total += 200
            combo += 1
        } else if code == 0x40000 {                      // 早期解放 (カウントなし)
            gaugeA = min(max(gaugeA - 32, 0), 100)
            combo = 0
        } else if code == 0x400000 {                     // type 4 成功
            total += 100
            combo += 1
            gaugeB = min(max(gaugeB + 0.001, 0), 1)
        }
        maxCombo = max(maxCombo, combo)
    }
}

// MARK: - 判定エンジン

/// 画面に出す判定の知らせ (判定文字・ヒット光・コンボの表示用)
struct SlideJudgeEvent {
    enum Kind { case head, tick, releasePenalty, wipe }
    var kind: Kind
    var grade: Int          // head: 2 / 4 / 8 / 1 (1 = ミス)。それ以外は 0
    var early: Bool         // 方向 (早押し = true)
    var note: SlideNote
    var x: Int              // 表示する x (0...255。ミラー反映後)
    var now: Double
}

final class SlideEngine {
    static let noCode = SlideScore.noCode
    /// 判定レベル → 窓のオフセット L (§6.2)
    static let levelOffset = [20, 10, 0, -8, -16]

    let chart: SlideChart
    let notes: [SlideNote]
    private(set) var score = SlideScore()
    private(set) var head = 0                 // 判定列 (deque) の先頭
    var mirror = false                        // FLIP (ノーツ側だけを反転。§5)
    var level: Int { score.level }
    var windowOffset: Int { SlideEngine.levelOffset[min(max(score.level, 0), 4)] }

    // タッチ (§5): 10 スロット。値は x (0...255) か空き (-1)
    private var slots = [Int](repeating: -1, count: 10)
    private var idToSlot: [Int: Int] = [:]
    private(set) var activeTouches = 0
    /// 領域幅 (ビューの幅) とフィールド幅 (標準スキンでは同じ)。タッチ x の変換に使う
    var areaWidth: Float = 1
    var fieldWidth: Float = 1

    // 通知
    var onJudge: ((SlideJudgeEvent) -> Void)?
    /// ヒット音: グレード 2/4/8 の頭判定と type 4 成功のとき (ミス・ティック・解放ペナルティでは鳴らない。ユーザー確認済み)
    var onHitSound: (() -> Void)?

    /// startAtMs: この ms より前に始まるノーツは最初から処理済みにする (エディタの途中からテストするとき)
    init(chart: SlideChart, level: Int = 2, startAtMs: Int? = nil) {
        self.chart = chart
        self.notes = chart.notes
        score.level = min(max(level, 0), 4)
        reset(startAtMs: startAtMs)
    }

    func reset(startAtMs: Int? = nil) {
        score = SlideScore(level: score.level)
        head = 0
        slots = [Int](repeating: -1, count: 10)
        idToSlot.removeAll()
        activeTouches = 0
        for n in notes {
            n.resetState()
            if let s = startAtMs, n.startMs < s {
                n.state = n.isSlide ? 0x9 : 0x1
                n.skipped = true
            }
        }
        while head < notes.count, notes[head].skipped { head += 1 }
    }

    func setLevel(_ k: Int) { score.level = min(max(k, 0), 4) }

    // MARK: 入力

    private func now32(_ now: Double) -> Int { slideTrunc(now) }

    /// 押した / 動かした / 離した (§5, 付録 B.6)。x は画面上の x (ビュー座標)
    func touchBegan(id: Int, x: Float, now: Double) {
        guard let slot = allocateSlot(id) else { return }
        onTouch(slot: slot, x: x, phase: 0, now: now)
    }

    func touchMoved(id: Int, x: Float, now: Double) {
        guard let slot = idToSlot[id] else { return }
        onTouch(slot: slot, x: x, phase: 1, now: now)
    }

    func touchEnded(id: Int, x: Float, now: Double) {
        guard let slot = idToSlot[id] else { return }
        idToSlot[id] = nil
        onTouch(slot: slot, x: x, phase: 2, now: now)
    }

    /// ポーズ・リトライ: 押さえている指を全部なかったことにする
    func releaseAllTouches() {
        slots = [Int](repeating: -1, count: 10)
        idToSlot.removeAll()
        activeTouches = 0
        for n in notes[head...] where n.slot >= 0 { n.slot = -1 }
    }

    private func allocateSlot(_ id: Int) -> Int? {
        if let s = idToSlot[id] { return s }
        let used = Set(idToSlot.values)
        for i in 0..<slots.count where !used.contains(i) {
            idToSlot[id] = i
            return i
        }
        return nil
    }

    private func onTouch(slot: Int, x: Float, phase: Int, now: Double) {
        let xf = x - (areaWidth - fieldWidth) * 0.5                  // float32
        if xf < 0 || xf > fieldWidth { return }                      // 場外のイベントは丸ごと無視
        let val = Int((xf * 255.0 / fieldWidth).rounded(.toNearestOrAwayFromZero)) & 0xFF
        if phase == 2 || phase == 3 {
            if slots[slot] != -1 { activeTouches -= 1 }
            slots[slot] = -1
        } else {
            if slots[slot] == -1 { activeTouches += 1 }
            slots[slot] = val
            if phase == 0 { headRegister(touchX: val, now: now) }
        }
        follow(now: now)
    }

    // MARK: 頭の登録 (§6.1 / 付録 B.7)

    private func headRegister(touchX: Int, now: Double) {
        let nowI = now32(now)
        var i = head
        while i < notes.count {
            let n = notes[i]
            i += 1
            if Double(n.startMs) > now + 170.0 { break }
            if n.flags & 0x401 != 0, n.state & 1 != 0 { continue }
            if n.isType4, Double(n.startMs) > now + 45.0 { continue }
            if n.isSlide, n.state & 8 != 0 { continue }
            let target = displayX(n.isSlide ? n.trajectoryX(nowI) : n.x)
            if abs(touchX - target) < n.threshold {
                let code = judgeHead(n, nowI)
                emit(code, n, now)
                if n.isSlide { n.slot = slots.firstIndex(of: touchX) ?? -1 }
                return
            }
        }
    }

    // MARK: 追従評価 (§6.3 / 付録 B.9)

    /// 毎フレームと、場内のタッチイベントごとに呼ぶ
    func follow(now: Double) {
        let nowI = now32(now)
        // 「保持できる」スライドの数 (開始 ms <= 現在 + 50 < 終了 ms)。2 で頭打ち
        var active = 0
        var j = head
        while j < notes.count && active < 2 {
            let n = notes[j]
            j += 1
            if Double(n.startMs) > now + 50.0 { break }
            if n.isSlide && now + 50.0 < Double(n.endMs) { active += 1 }
        }
        var i = head
        while i < notes.count {
            let n = notes[i]
            i += 1
            if Double(n.startMs) > now { break }
            if n.flags & 0x1 != 0 { continue }
            if n.isSlide {
                if n.state & 8 != 0 { continue }
                if Double(n.endMs) < now && n.state & 4 != 0 {
                    emit(judgeRelease(n, nowI), n, now)
                    continue
                }
                let tx = displayX(n.trajectoryX(nowI))
                var foundX = -1
                if active < 2 && n.state & 4 != 0 && n.slot >= 0 && slots[n.slot] != -1 {
                    foundX = slots[n.slot]                       // 紐付いたタッチが生きている
                } else {
                    let (s, fx) = nearest(to: tx)
                    n.slot = s                                   // 最も近いタッチを探し直し、対応も差し替える
                    foundX = fx
                }
                let sample: Float = foundX < 0 ? Float(10000 - tx) : Float(foundX - tx)
                let mean = abs(n.pushSample(sample))
                if mean > n.threshold {                          // 切れた (厳密 >。ちょうどは継続)
                    if n.state & 4 != 0 { emit(judgeRelease(n, nowI), n, now) }
                    n.resetSamples()
                    continue
                }
                emit(judgeTick(n, nowI), n, now)
            } else if n.isType4 && n.state & 1 == 0 {
                if nowI >= n.startMs {
                    let (_, fx) = nearest(to: displayX(n.x))
                    let err = fx < 0 ? 10000 : abs(fx - displayX(n.x))
                    if err < n.threshold { emit(judgeHead(n, nowI), n, now) }
                }
            }
        }
    }

    /// 場内で最も近いタッチ (単純な argmin。使用中の印は見ない)。なければ (-1, -1)
    private func nearest(to tx: Int) -> (slot: Int, x: Int) {
        var bestSlot = -1, bestX = -1, bestD = Int.max
        for (i, v) in slots.enumerated() where v != -1 {
            let d = abs(v - tx)
            if d < bestD { bestD = d; bestSlot = i; bestX = v }
        }
        return (bestSlot, bestX)
    }

    private func displayX(_ x: Int) -> Int { mirror ? 255 - x : x }

    // MARK: 頭・ティック・解放 (§6.2, §6.4, §6.5 / 付録 B.8, B.10)

    private func judgeHead(_ n: SlideNote, _ now: Int) -> UInt32 {
        if n.isSlide && (n.state & 9) == 1 {                 // すでに頭が当たっているスライドの掴み直し
            n.nextTick = now + 100
            n.state |= 4
            return SlideEngine.noCode
        }
        if n.isType4 {
            if n.startMs <= now {
                n.state |= 1
                return 0x400000
            }
            return SlideEngine.noCode
        }
        let L = windowOffset
        let dt = n.startMs - now
        if dt > L + 170 { return SlideEngine.noCode }
        let a = abs(dt)
        let grade: UInt32 = a <= L + 45 ? 2 : a <= L + 85 ? 4 : a <= L + 130 ? 8 : 1
        let code = grade | (dt >= 1 ? 0x40 : 0x20)
        if n.isSlide {
            n.state |= 5
            if grade != 1 { n.nextTick = max(now, n.startMs) + 100 }
        } else {
            n.state |= 1
        }
        return code
    }

    private func judgeTick(_ n: SlideNote, _ now: Int) -> UInt32 {
        if !n.isSlide { return SlideEngine.noCode }
        if n.state & 1 == 0 { n.state |= 1 }
        if n.state & 8 != 0 { return SlideEngine.noCode }
        if n.endMs <= now { n.state = (n.state & ~4) | 8 }   // 完了。ここでは戻らず、下の「拾い」へ落ちる
        var nt: Int
        if n.state & 4 == 0 {
            n.state |= 4
            nt = max(n.startMs, now) + 100
            n.nextTick = nt
        } else {
            nt = n.nextTick
        }
        if nt <= now {
            n.nextTick = n.endMs < nt + 100 ? Int(Int32.max) : nt + 100
            return 0x400
        }
        return SlideEngine.noCode
    }

    private func judgeRelease(_ n: SlideNote, _ now: Int) -> UInt32 {
        if n.isSlide && (n.state & 9) == 1 {
            n.state &= ~4
            n.nextTick = Int(Int32.max)
            if now >= n.endMs - 130 {
                n.state |= 8
                return SlideEngine.noCode
            }
            return 0x40000
        }
        return SlideEngine.noCode
    }

    // MARK: スコアへ

    private func emit(_ code: UInt32, _ n: SlideNote, _ now: Double) {
        if code == SlideEngine.noCode { return }
        score.apply(code)
        if (SlideScore.isGradedHead(code) && code & 1 == 0) || code == 0x400000 { n.hit = true }
        let early = code & 0x40 != 0
        var ev: SlideJudgeEvent?
        if SlideScore.isGradedHead(code) {
            let g: Int = code & 2 != 0 ? 2 : code & 4 != 0 ? 4 : code & 8 != 0 ? 8 : 1
            ev = SlideJudgeEvent(kind: .head, grade: g, early: early, note: n, x: displayX(n.x), now: now)
            if g != 1 { onHitSound?() }
        } else if code == 0x400000 {
            ev = SlideJudgeEvent(kind: .wipe, grade: 0, early: false, note: n, x: displayX(n.x), now: now)
            onHitSound?()
        } else if code == 0x400 {
            ev = SlideJudgeEvent(kind: .tick, grade: 0, early: false, note: n, x: displayX(n.trajectoryX(now32(now))), now: now)
        } else if code == 0x40000 {
            ev = SlideJudgeEvent(kind: .releasePenalty, grade: 0, early: true, note: n, x: displayX(n.trajectoryX(now32(now))), now: now)
        }
        if let e = ev { onJudge?(e) }
    }

    // MARK: 毎フレーム (§6.9 手順 5, 6, 8)

    /// now: 判定時計 t_judge (ms)。見逃し → 追従評価 → 先頭の整理 の順
    func update(now: Double) {
        // 見逃し (§6.7): 開始 < 現在 − 170 (固定) で、まだ判定されていないもの。type 4 は何も出さず判定済みになる
        var i = head
        while i < notes.count {
            let n = notes[i]
            if !(Double(n.startMs) < now - 170.0) { break }
            i += 1
            if n.state & 1 == 0 {
                n.state |= 1
                if !n.isType4 {
                    score.apply(0x21)
                    onJudge?(SlideJudgeEvent(kind: .head, grade: 1, early: false, note: n, x: displayX(n.x), now: now))
                }
            }
        }
        follow(now: now)
        // 先頭の整理: 判定済みで、(通常ノーツ or 終了を過ぎたスライド)
        while head < notes.count {
            let n = notes[head]
            if n.state & 1 != 0 && (!n.isSlide || Double(n.endMs) < now) { head += 1 } else { break }
        }
    }

    // MARK: 参照用

    /// 完了条件 (§6.9): 譜面の長さ + 1000 ms を過ぎたら終わり
    func isFinished(now: Double) -> Bool { now >= Double(chart.lengthMs + 1000) }

    /// 今押さえているタッチの x (0...255)。ヒット光・タッチ表示用
    var touchXs: [Int] { slots.filter { $0 != -1 } }
}
