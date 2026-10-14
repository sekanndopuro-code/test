// テストプレイ機能 (MalodySlideTestplayer の中身をエディタ用に組み込んだもの)
// 元: MalodySlideTestplayer / ContentView.swift
//  - 判定・ACC・音声(自前oggデコーダー)・UIKit描画/マルチタッチ はそのまま流用
//  - エディタの Note / ChartError と名前が衝突するので PlayNote / PlayChartError に改名
//  - 「エディタの現在位置から始める」ための startAt を GameCore / GameView に追加
//  - 内蔵サンプル譜面・ファイル選択メニュー(ContentView)は不要なので削除

import SwiftUI
import UIKit
import AVFoundation

// MARK: - ルール(判定・ACCはPC版C判定)

enum Rule {
    static let best = 0.036          // 秒
    static let cool = 0.076
    static let good = 0.110
    static let miss = 0.150
    static let xMargin = 6.0         // レーン座標での横の余裕
    static let comboInterval = 0.1   // スライド中は100msごとに+1コンボ
    static let slideWindow = 20      // 符号付き誤差の移動平均のサンプル数
    static let sampleRate = 60.0     // そのサンプリング周波数(フレームレートに依存させない)
    static let freeTail = 0.2        // 終点の200ms前からはなぞらなくても繋がる
}

enum Judge {
    case best, cool, good, miss
    
    init(dt: Double) {
        let a = abs(dt)
        if a <= Rule.best { self = .best }
        else if a <= Rule.cool { self = .cool }
        else if a <= Rule.good { self = .good }
        else { self = .miss }
    }
    
    var weight: Double {
        switch self {
        case .best: return 100
        case .cool: return 75
        case .good: return 40
        case .miss: return 0
        }
    }
    
    var name: String {
        switch self {
        case .best: return "BEST"
        case .cool: return "COOL"
        case .good: return "GOOD"
        case .miss: return "MISS"
        }
    }
}

// MARK: - 譜面データ

final class PlayNote {
    enum Kind { case tap, wipe, slide }
    enum State { case waiting, active, done }
    
    let kind: Kind
    let t: Double                          // 判定時刻(秒, beat 0 = 0)
    let x: Double                          // 中心のレーン座標(0...255)
    let w: Double                          // 幅
    let path: [(t: Double, x: Double)]     // slideのみ: 判定のある区間(始点〜最初に時間が巻き戻る手前まで。xは絶対座標)
    let ribbon: [(t: Double, x: Double)]   // slideのみ: 描画用。始点を含む全点を mc に書かれた順のまま(巻き戻り・負のbeatもそのまま)
    
    var state = State.waiting
    var connected = false
    var errs: [Double] = []
    var nextSample = 0.0
    var lastTick = 0.0
    
    init(kind: Kind, t: Double, x: Double, w: Double,
         path: [(t: Double, x: Double)] = [], ribbon: [(t: Double, x: Double)] = []) {
        self.kind = kind
        self.t = t
        self.x = x
        self.w = w
        self.path = path
        self.ribbon = ribbon
    }
    
    var endT: Double { path.last?.t ?? t }
    
    func reset() {
        state = .waiting
        connected = false
        errs = []
        nextSample = 0
        lastTick = 0
    }
    
    /// スライド中心線のx(区間ごとに線形補間)
    func centerX(at time: Double) -> Double {
        guard path.count > 1 else { return x }
        if time <= path[0].t { return path[0].x }
        if time > path[path.count - 1].t { return path[path.count - 1].x }
        // path は時刻が昇順なので二分探索(segが何万個あっても毎回全部は舐めない)。
        // time <= path[i].t となる最初の i を探す
        var lo = 1, hi = path.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if time <= path[mid].t { hi = mid } else { lo = mid + 1 }
        }
        let a = path[lo - 1], b = path[lo]
        let span = b.t - a.t
        return span <= 0 ? b.x : a.x + (b.x - a.x) * (time - a.t) / span
    }
}

private struct RawChart: Decodable {
    struct Meta: Decodable {
        struct Song: Decodable { let title: String? }
        let song: Song?
    }
    struct Time: Decodable { let beat: [Double]; let bpm: Double }
    struct Seg: Decodable { let beat: [Double]; let x: Double }
    struct RawNote: Decodable {
        let beat: [Double]
        let x: Double?
        let w: Double?
        let type: Int?
        let seg: [Seg]?
        let offset: Double?
    }
    let meta: Meta?
    let time: [Time]
    let note: [RawNote]
}

/// effect (scroll / jump) は譜面本体とは別に読む (形が想定と違っても、譜面全体が読めなくならないように)
private struct RawEffects: Decodable {
    struct Item: Decodable {
        let beat: [Double]?
        let scroll: Double?
        let jump: Double?
        enum Keys: String, CodingKey { case beat, scroll, jump }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            beat = try? c.decode([Double].self, forKey: .beat)
            scroll = try? c.decode(Double.self, forKey: .scroll)
            jump = try? c.decode(Double.self, forKey: .jump)
        }
    }
    let effect: [Item]?
    enum Keys: String, CodingKey { case effect }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        effect = try? c.decode([Item].self, forKey: .effect)
    }
}

enum PlayChartError: Error { case noTiming }

struct MalodyChart {
    let title: String
    let offset: Double      // 秒。曲の頭が来る譜面時刻(大きいほど曲の開始が遅れる)
    let notes: [PlayNote]
    let effects: EffectMap  // scroll / jump (見た目だけが変わる。判定は notes の時刻のまま)
    
    private static func beat(_ v: [Double]) -> Double {
        guard v.count == 3, v[2] != 0 else { return 0 }
        return v[0] + v[1] / v[2]
    }
    
    static func load(_ data: Data) throws -> MalodyChart {
        let raw = try JSONDecoder().decode(RawChart.self, from: data)
        
        let timing = raw.time
            .map { (beat: beat($0.beat), bpm: $0.bpm) }
            .filter { $0.bpm > 0 }
            .sorted { $0.beat < $1.beat }
        guard let head = timing.first else { throw PlayChartError.noTiming }
        
        // beat -> 秒(BPM変化対応)
        func sec(_ b: Double) -> Double {
            var t = 0.0, pb = head.beat, bpm = head.bpm
            for e in timing.dropFirst() {
                if b <= e.beat { break }
                t += (e.beat - pb) * 60 / bpm
                pb = e.beat
                bpm = e.bpm
            }
            return t + (b - pb) * 60 / bpm
        }
        
        var notes: [PlayNote] = []
        var offset = 0.0
        for n in raw.note {
            if n.type == 1 { offset = (n.offset ?? 0) / 1000; continue }   // 音源ノート
            guard let x = n.x else { continue }
            let w = n.w ?? 32
            let b = beat(n.beat)
            let t0 = sec(b)
            if n.type == 4 {
                notes.append(PlayNote(kind: .wipe, t: t0, x: x, w: w))
            } else if let segs = n.seg, !segs.isEmpty {
                // segのbeatとxは始点からの相対値
                var all: [(t: Double, x: Double)] = [(t: t0, x: x)]
                for s in segs { all.append((t: sec(b + beat(s.beat)), x: x + s.x)) }
                // 判定があるのは「最初に時系列順に並んでいる所」だけ。最初に時間が巻き戻った所から先は
                // 装飾(リボンの描画だけ)で、判定には使わない。
                var path = [all[0]]
                for p in all.dropFirst() {
                    if p.t < path[path.count - 1].t - 0.000001 { break }
                    path.append(p)
                }
                notes.append(PlayNote(kind: .slide, t: t0, x: x, w: w, path: path, ribbon: all))
            } else {
                notes.append(PlayNote(kind: .tap, t: t0, x: x, w: w))
            }
        }
        notes.sort { $0.t < $1.t }
        
        // effect (scroll / jump)。jump は ms の単位 (1000 = 1 秒間に scroll で進む距離)。scroll との掛け算は EffectMap 側でする
        var events: [EffectMap.Event] = []
        for e in (try? JSONDecoder().decode(RawEffects.self, from: data))?.effect ?? [] {
            guard let bv = e.beat, bv.count == 3, bv[2] != 0, e.scroll != nil || e.jump != nil else { continue }
            let b = beat(bv)
            events.append(EffectMap.Event(t: sec(b), scroll: e.scroll, jumpMs: e.jump ?? 0))
        }
        return MalodyChart(title: raw.meta?.song?.title ?? "", offset: offset, notes: notes,
                           effects: EffectMap.make(events))
    }
}

// MARK: - ゲームの核(UI非依存: 入力イベント + 時刻 -> 判定・スコア)

final class GameCore {
    let notes: [PlayNote]
    let endTime: Double
    private(set) var firstIndex = 0          // 未処理の先頭ノーツ
    private(set) var combo = 0
    private(set) var maxCombo = 0
    private(set) var score = 0
    private(set) var lastJudge: Judge?
    private(set) var lastJudgeAt = 0.0
    private(set) var fingers: [Int: Double] = [:]   // 指ID -> レーンx
    private var accSum = 0.0
    private var accCount = 0
    var onHit: (() -> Void)? = nil               // ノーツを捌いた瞬間(キー音用。エディタ追加分)
    
    var accuracy: Double { accCount == 0 ? 0 : accSum / Double(accCount) }
    var isFinished: Bool { firstIndex >= notes.count }
    
    /// startTime: この譜面時刻より前のノーツは最初から処理済み扱い(エディタの途中からテストするため)
    init(notes: [PlayNote], startTime: Double = -.infinity) {
        self.notes = notes
        notes.forEach { $0.reset() }
        self.endTime = notes.map { $0.endT }.max() ?? 0
        var i = 0
        while i < notes.count && notes[i].t < startTime {
            notes[i].state = .done
            i += 1
        }
        firstIndex = i
    }
    
    // ---- 入力 ----
    
    func touchBegan(id: Int, x: Double, at t: Double) {
        fingers[id] = x
        // tapと、スライド始点を「叩いた」場合: 最も時刻が近い1つを判定する
        var target: PlayNote?
        var bestGap = Double.infinity
        var i = firstIndex
        while i < notes.count {
            let n = notes[i]
            i += 1
            if n.t - t > Rule.miss { break }
            guard n.state == .waiting, n.kind != .wipe else { continue }
            let gap = abs(t - n.t)
            if gap <= Rule.miss, gap < bestGap, abs(x - n.x) <= n.w / 2 + Rule.xMargin {
                target = n
                bestGap = gap
            }
        }
        if let n = target {
            onHit?()
            register(Judge(dt: t - n.t), at: t)
            if n.kind == .tap { n.state = .done } else { activate(n, at: t) }
        }
        trace(at: t)
    }
    
    func touchMoved(id: Int, x: Double, at t: Double) {
        fingers[id] = x
        trace(at: t)
    }
    
    func touchEnded(id: Int) {
        fingers[id] = nil
    }
    
    /// ポーズ時: 押さえている指をすべて離した扱いにする
    func releaseFingers() {
        fingers.removeAll()
    }
    
    // ---- 毎フレーム ----
    
    func update(to t: Double) {
        var i = firstIndex
        while i < notes.count {
            let n = notes[i]
            i += 1
            if n.t - t > Rule.miss { break }
            switch n.kind {
            case .tap:
                if n.state == .waiting && t > n.t + Rule.miss {
                    n.state = .done
                    register(.miss, at: t)
                }
            case .wipe:
                if n.state == .waiting && t >= n.t {
                    if covered(n) { n.state = .done; onHit?(); gain(100) }
                    else if t > n.t + Rule.cool { n.state = .done }     // 取り逃しはノーペナルティ
                }
            case .slide:
                if n.state == .waiting {
                    if t >= n.t && t <= n.t + Rule.cool && covered(n) {
                        onHit?()
                        gain(100)                                       // なぞり始点: ACCは動かない
                        activate(n, at: t)
                    } else if t > n.t + Rule.miss {
                        register(.miss, at: t)                          // 始点を取り逃し
                        activate(n, at: t)
                    }
                }
                if n.state == .active { follow(n, at: t) }
            }
        }
        while firstIndex < notes.count && notes[firstIndex].state == .done { firstIndex += 1 }
    }
    
    // ---- 内部 ----
    
    /// wipe と「なぞり始点」: 判定バー到達後、COOLのlate幅までに指が乗っていれば捌ける
    private func trace(at t: Double) {
        var i = firstIndex
        while i < notes.count {
            let n = notes[i]
            i += 1
            if n.t > t { break }
            guard n.kind != .tap, n.state == .waiting, t <= n.t + Rule.cool, covered(n) else { continue }
            onHit?()
            gain(100)
            if n.kind == .wipe { n.state = .done } else { activate(n, at: t) }
        }
    }
    
    private func activate(_ n: PlayNote, at t: Double) {
        n.state = .active
        n.nextSample = max(t, n.t)
        n.lastTick = max(t, n.t)
    }
    
    /// スライドの追従: 符号付き誤差の20サンプル移動平均が幅内なら「繋がっている」
    private func follow(_ n: PlayNote, at t: Double) {
        if t > n.endT {
            n.state = .done
            n.connected = false
            return
        }
        if t - n.nextSample > 0.5 { n.nextSample = t }       // 長時間止まった後の追い付き防止
        let step = 1.0 / Rule.sampleRate
        while n.nextSample <= t {
            if let e = nearestError(to: n.centerX(at: n.nextSample)) {
                n.errs.append(e)
                if n.errs.count > Rule.slideWindow { n.errs.removeFirst() }
            } else {
                n.errs.removeAll()
            }
            n.nextSample += step
        }
        if n.errs.isEmpty {
            n.connected = false
        } else {
            let mean = n.errs.reduce(0, +) / Double(n.errs.count)
            n.connected = abs(mean) <= n.w / 2 + Rule.xMargin
        }
        if t >= n.endT - Rule.freeTail { n.connected = true }
        if n.connected {
            while t - n.lastTick >= Rule.comboInterval {
                n.lastTick += Rule.comboInterval
                gain(50)
            }
        } else {
            n.lastTick = t
        }
    }
    
    private func covered(_ n: PlayNote) -> Bool {
        fingers.values.contains { abs($0 - n.x) <= n.w / 2 + Rule.xMargin }
    }
    
    private func nearestError(to cx: Double) -> Double? {
        var best: Double?
        for f in fingers.values {
            let e = f - cx
            if best == nil || abs(e) < abs(best!) { best = e }
        }
        return best
    }
    
    /// tap(とスライド始点を叩いた時)だけがACCに関与する
    private func register(_ j: Judge, at t: Double) {
        accSum += j.weight
        accCount += 1
        if j == .miss {
            combo = 0
        } else {
            combo += 1
            maxCombo = max(maxCombo, combo)
            score += Int(j.weight) * 10
        }
        lastJudge = j
        lastJudgeAt = t
    }
    
    /// wipe・なぞり始点・スライド中の100msごと: コンボとスコアだけ増える
    private func gain(_ s: Int) {
        combo += 1
        maxCombo = max(maxCombo, combo)
        score += s
    }
}

// MARK: - Ogg Vorbis デコーダー(自前実装・ストリーミング対応)
// 変換不要でoggをそのまま読めるようにする部分。ファイルはメモリマップで開き、
// 必要な分だけ少しずつデコードするので、長い曲でもメモリはほとんど増えない。

struct AudioLoadError: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private func ilog(_ x: Int) -> Int {
    var n = 0, v = x
    while v > 0 { n += 1; v >>= 1 }
    return n
}

private func ipow(_ b: Int, _ e: Int) -> Int {
    var r = 1
    for _ in 0..<e {
        r *= b
        if r > (1 << 40) { return r }
    }
    return r
}

/// LSBファースト(Vorbis方式)のビット読み出し
private final class BitReader {
    private let b: [UInt8]
    private var p = 0
    private let nbits: Int
    
    init(_ data: [UInt8]) {
        b = data
        nbits = data.count * 8
    }
    
    var eop: Bool { p > nbits }
    
    func bit() -> Int {
        let i = p >> 3
        let r = i < b.count ? (Int(b[i]) >> (p & 7)) & 1 : 0
        p += 1
        return r
    }
    
    func read(_ n: Int) -> Int {
        if n == 0 { return 0 }
        var v = 0, got = 0
        while got < n {
            let i = p >> 3, sh = p & 7
            let take = min(8 - sh, n - got)
            let byte = i < b.count ? Int(b[i]) : 0
            v |= ((byte >> sh) & ((1 << take) - 1)) << got
            got += take
            p += take
        }
        return v
    }
}

private final class Codebook {
    let dim: Int
    let entries: Int
    private(set) var tree: [Int32] = [0, 0]     // 正=内部ノード, 負=葉(-(entry+1)), 0=なし
    private(set) var vec: [Float] = []          // entries * dim (lookupなしなら空)
    
    init(_ br: BitReader) throws {
        guard br.read(24) == 0x564342 else { throw AudioLoadError(text: "oggのcodebookが不正です") }
        let d = br.read(16)
        let e = br.read(24)
        dim = d
        entries = e
        guard d > 0, e > 0 else { throw AudioLoadError(text: "oggのcodebookが空です") }
        
        var lens = [Int](repeating: 0, count: e)
        if br.read(1) == 0 {
            let sparse = br.read(1)
            for i in 0..<e {
                if sparse == 1 {
                    if br.read(1) == 1 { lens[i] = br.read(5) + 1 }
                } else {
                    lens[i] = br.read(5) + 1
                }
            }
        } else {
            var cur = 0
            var len = br.read(5) + 1
            while cur < e {
                if len > 32 { throw AudioLoadError(text: "oggのcodebookが不正です") }
                let num = br.read(ilog(e - cur))
                var i = cur
                while i < min(cur + num, e) { lens[i] = len; i += 1 }
                cur += num
                len += 1
            }
        }
        
        // 符号語の割り当て(仕様どおり、エントリ順に最小の空き符号を取る)
        var t: [Int32] = [0, 0]
        func add(_ code: UInt64, _ entry: Int, _ length: Int) {
            var node = 0
            var b = length - 1
            while b >= 0 {
                let bit = Int((code >> UInt64(b)) & 1)
                if b == 0 {
                    t[node * 2 + bit] = Int32(-(entry + 1))
                } else {
                    var nxt = Int(t[node * 2 + bit])
                    if nxt < 0 { return }
                    if nxt == 0 {
                        t.append(0)
                        t.append(0)
                        nxt = t.count / 2 - 1
                        t[node * 2 + bit] = Int32(nxt)
                    }
                    node = nxt
                }
                b -= 1
            }
        }
        var avail = [UInt64](repeating: 0, count: 34)
        var k = 0
        while k < e && lens[k] == 0 { k += 1 }
        if k < e {
            add(0, k, lens[k])
            for i in 1...lens[k] { avail[i] = UInt64(1) << UInt64(32 - i) }
            var j = k + 1
            while j < e {
                var z = lens[j]
                if z != 0 {
                    while z > 0 && avail[z] == 0 { z -= 1 }
                    if z == 0 { break }
                    let res = avail[z]
                    avail[z] = 0
                    add(res >> UInt64(32 - lens[j]), j, lens[j])
                    if z != lens[j] {
                        var y = lens[j]
                        while y > z {
                            avail[y] = res + (UInt64(1) << UInt64(32 - y))
                            y -= 1
                        }
                    }
                }
                j += 1
            }
        }
        tree = t
        
        // 値のテーブル(VQ)
        let lt = br.read(4)
        if lt == 1 || lt == 2 {
            let mn = Codebook.unpack(br.read(32))
            let delta = Codebook.unpack(br.read(32))
            let vb = br.read(4) + 1
            let seq = br.read(1) == 1
            var nv = e * d
            if lt == 1 {
                var r = Int(floor(pow(Double(e), 1.0 / Double(d))))
                while ipow(r + 1, d) <= e { r += 1 }
                while r > 0 && ipow(r, d) > e { r -= 1 }
                nv = r
            }
            guard nv > 0, nv <= (1 << 24) else { throw AudioLoadError(text: "oggのcodebookが不正です") }
            var mult = [Int](repeating: 0, count: nv)
            for i in 0..<nv { mult[i] = br.read(vb) }
            var v = [Float](repeating: 0, count: e * d)
            for ent in 0..<e {
                var last = 0.0
                var idiv = 1
                for i in 0..<d {
                    var off = ent * d + i
                    if lt == 1 {
                        off = (ent / idiv) % nv
                        idiv *= nv
                    }
                    let val = Double(mult[off]) * delta + mn + last
                    if seq { last = val }
                    v[ent * d + i] = Float(val)
                }
            }
            vec = v
        } else if lt != 0 {
            throw AudioLoadError(text: "oggのcodebookが不正です")
        }
    }
    
    private static func unpack(_ x: Int) -> Double {
        var m = Double(x & 0x1fffff)
        let e = (x & 0x7fe00000) >> 21
        if x & 0x80000000 != 0 { m = -m }
        return m * pow(2.0, Double(e - 788))
    }
    
    /// 1エントリ読む。失敗は -1
    func scalar(_ br: BitReader) -> Int {
        var node = 0
        while true {
            node = Int(tree[node * 2 + br.bit()])
            if node < 0 { return -node - 1 }
            if node == 0 { return -1 }
        }
    }
}

private final class Floor1 {
    let plist: [Int]
    let dims: [Int]
    let subs: [Int]
    let master: [Int]
    let books: [[Int]]
    let mult: Int
    let xs: [Int]
    let order: [Int]
    let lo: [Int]
    let hi: [Int]
    
    static let rangeTable = [256, 128, 86, 64]
    static let db: [Float] = {
        var t = [Float](repeating: 0, count: 256)
        let k = log(1.0 / 1.0649863e-07) / 255.0
        for i in 0..<256 { t[i] = Float(exp(-Double(255 - i) * k)) }
        return t
    }()
    
    init(_ br: BitReader) throws {
        let np = br.read(5)
        var pl = [Int]()
        for _ in 0..<np { pl.append(br.read(4)) }
        let mc = (pl.max() ?? -1) + 1
        var dm = [Int](repeating: 0, count: mc)
        var sb = [Int](repeating: 0, count: mc)
        var ms = [Int](repeating: 0, count: mc)
        var bk = [[Int]](repeating: [], count: mc)
        for i in 0..<mc {
            dm[i] = br.read(3) + 1
            sb[i] = br.read(2)
            if sb[i] != 0 { ms[i] = br.read(8) }
            var arr = [Int]()
            for _ in 0..<(1 << sb[i]) { arr.append(br.read(8) - 1) }
            bk[i] = arr
        }
        let m = br.read(2) + 1
        let rb = br.read(4)
        var x = [0, 1 << rb]
        for p in pl {
            for _ in 0..<dm[p] { x.append(br.read(rb)) }
        }
        let n = x.count
        let ord = (0..<n).sorted { x[$0] < x[$1] }
        var lw = [Int](repeating: 0, count: n)
        var hg = [Int](repeating: 0, count: n)
        if n > 2 {
            for i in 2..<n {
                var l = 0, h = 1
                for j in 0..<i {
                    if x[j] < x[i] && x[j] > x[l] { l = j }
                    if x[j] > x[i] && x[j] < x[h] { h = j }
                }
                lw[i] = l
                hg[i] = h
            }
        }
        plist = pl; dims = dm; subs = sb; master = ms; books = bk
        mult = m; xs = x; order = ord; lo = lw; hi = hg
    }
    
    /// 戻り値: このチャンネルでフロアが使われているか。curveにM点の振幅を書く
    func decode(_ br: BitReader, _ cbs: [Codebook], _ M: Int, _ curve: UnsafeMutablePointer<Float>) -> Bool {
        if br.read(1) == 0 { return false }
        let rng = Floor1.rangeTable[mult - 1]
        let n = xs.count
        var y = [Int](repeating: 0, count: n)
        y[0] = br.read(ilog(rng - 1))
        y[1] = br.read(ilog(rng - 1))
        var off = 2
        for p in plist {
            let cd = dims[p], cb = subs[p], cs = (1 << cb) - 1
            var cv = 0
            if cb != 0 {
                cv = cbs[master[p]].scalar(br)
                if cv < 0 { return false }
            }
            for j in 0..<cd {
                let bk = books[p][cv & cs]
                cv >>= cb
                if bk >= 0 {
                    let e = cbs[bk].scalar(br)
                    if e < 0 { return false }
                    y[off + j] = e
                } else {
                    y[off + j] = 0
                }
            }
            off += cd
        }
        if br.eop { return false }
        
        var f = [Int](repeating: 0, count: n)
        var flag = [Bool](repeating: false, count: n)
        f[0] = y[0]; f[1] = y[1]
        flag[0] = true; flag[1] = true
        if n > 2 {
            for i in 2..<n {
                let l = lo[i], h = hi[i]
                let x0 = xs[l], x1 = xs[h], y0 = f[l], y1 = f[h]
                let dy = y1 - y0, adx = x1 - x0
                let o = adx > 0 ? abs(dy) * (xs[i] - x0) / adx : 0
                let pred = dy < 0 ? y0 - o : y0 + o
                let val = y[i]
                let high = rng - pred, low = pred
                let room = high < low ? high * 2 : low * 2
                if val != 0 {
                    flag[l] = true; flag[h] = true; flag[i] = true
                    if val >= room {
                        f[i] = high > low ? val - low + pred : pred - val + high - 1
                    } else {
                        f[i] = (val & 1) != 0 ? pred - ((val + 1) >> 1) : pred + (val >> 1)
                    }
                } else {
                    f[i] = pred
                }
            }
        }
        
        var line = [Int](repeating: 0, count: M)
        var hx = 0, lx = 0
        var ly = f[order[0]] * mult
        var hy = ly
        for k in 1..<n {
            let idx = order[k]
            if !flag[idx] { continue }
            hy = f[idx] * mult
            hx = xs[idx]
            let adx = hx - lx
            if adx > 0 {
                let dy = hy - ly
                let base = dy / adx
                let sy = dy < 0 ? base - 1 : base + 1
                let ady = abs(dy) - abs(base) * adx
                var yy = ly, e = 0
                if lx < M { line[lx] = yy }
                var x = lx + 1
                let end = min(hx, M)
                while x < end {
                    e += ady
                    if e >= adx { e -= adx; yy += sy } else { yy += base }
                    line[x] = yy
                    x += 1
                }
            }
            lx = hx
            ly = hy
        }
        var x = hx
        while x < M { line[x] = hy; x += 1 }
        for i in 0..<M {
            curve[i] = Floor1.db[min(max(line[i], 0), 255)]
        }
        return true
    }
}

private final class Residue {
    let type: Int
    let begin: Int
    let end: Int
    let psize: Int
    let ncls: Int
    let classbook: Int
    let books: [[Int]]
    
    init(_ br: BitReader, type t: Int) throws {
        guard t <= 2 else { throw AudioLoadError(text: "oggのresidueが未対応です") }
        type = t
        begin = br.read(24)
        end = br.read(24)
        psize = br.read(24) + 1
        ncls = br.read(6) + 1
        classbook = br.read(8)
        var cas = [Int]()
        for _ in 0..<ncls {
            let low = br.read(3)
            let high = br.read(1) == 1 ? br.read(5) : 0
            cas.append(high * 8 + low)
        }
        var bk = [[Int]]()
        for i in 0..<ncls {
            var row = [Int]()
            for j in 0..<8 { row.append((cas[i] & (1 << j)) != 0 ? br.read(8) : -1) }
            bk.append(row)
        }
        books = bk
    }
    
    func decode(_ br: BitReader, _ cbs: [Codebook], _ vecs: [UnsafeMutablePointer<Float>],
                _ dnd: [Bool], _ M: Int, _ tmp: UnsafeMutablePointer<Float>) {
        let ch = vecs.count
        if type == 2 {
            if !dnd.contains(false) { return }
            let size = M * ch
            tmp.initialize(repeating: 0, count: size)
            run(br, cbs, [tmp], [false], size)
            for c in 0..<ch {
                let dst = vecs[c]
                for i in 0..<M { dst[i] = tmp[i * ch + c] }
            }
        } else {
            run(br, cbs, vecs, dnd, M)
        }
    }
    
    private func run(_ br: BitReader, _ cbs: [Codebook], _ v: [UnsafeMutablePointer<Float>],
                     _ dnd: [Bool], _ size: Int) {
        let lb = min(begin, size), le = min(end, size)
        let n = le - lb
        if n <= 0 { return }
        let cbk = cbs[classbook]
        let cw = cbk.dim
        let nparts = n / psize
        if nparts <= 0 { return }
        let nch = v.count
        let stride = nparts + cw
        var cls = [Int](repeating: 0, count: nch * stride)
        for pass in 0..<8 {
            var pc = 0
            while pc < nparts {
                if pass == 0 {
                    for j in 0..<nch where !dnd[j] {
                        var t = cbk.scalar(br)
                        if t < 0 || br.eop { return }
                        var i = cw - 1
                        while i >= 0 {
                            cls[j * stride + pc + i] = t % ncls
                            t /= ncls
                            i -= 1
                        }
                    }
                }
                var i = 0
                while i < cw && pc < nparts {
                    for j in 0..<nch where !dnd[j] {
                        let bk = books[cls[j * stride + pc]][pass]
                        if bk < 0 { continue }
                        let book = cbs[bk]
                        let vv = book.vec
                        let dim = book.dim
                        if vv.isEmpty { return }
                        let off = lb + pc * psize
                        let dst = v[j]
                        if type == 0 {
                            let step = psize / dim
                            for ii in 0..<step {
                                let e = book.scalar(br)
                                if e < 0 || br.eop { return }
                                for jj in 0..<dim { dst[off + ii + jj * step] += vv[e * dim + jj] }
                            }
                        } else {
                            var ii = 0
                            while ii < psize {
                                let e = book.scalar(br)
                                if e < 0 || br.eop { return }
                                for jj in 0..<dim where off + ii + jj < size { dst[off + ii + jj] += vv[e * dim + jj] }
                                ii += dim
                            }
                        }
                    }
                    pc += 1
                    i += 1
                }
            }
        }
    }
}

private struct VMapping {
    var coupling: [(Int, Int)] = []
    var mux: [Int] = []
    var floor: [Int] = []
    var residue: [Int] = []
    var subs = 1
    
    init(_ br: BitReader, channels: Int) throws {
        guard br.read(16) == 0 else { throw AudioLoadError(text: "oggのmappingが未対応です") }
        subs = br.read(1) == 1 ? br.read(4) + 1 : 1
        if br.read(1) == 1 {
            let steps = br.read(8) + 1
            for _ in 0..<steps {
                let m = br.read(ilog(channels - 1))
                let a = br.read(ilog(channels - 1))
                coupling.append((m, a))
            }
        }
        _ = br.read(2)
        if subs > 1 {
            for _ in 0..<channels { mux.append(br.read(4)) }
        } else {
            mux = [Int](repeating: 0, count: channels)
        }
        for _ in 0..<subs {
            _ = br.read(8)
            floor.append(br.read(8))
            residue.append(br.read(8))
        }
    }
}

/// IMDCT(DCT-IVをN/4点の複素FFTで計算。O(N log N))
private final class IMDCTPlan {
    let n: Int
    private let M: Int
    private let h: Int
    private var preC: [Float] = [], preS: [Float] = [], postC: [Float] = [], postS: [Float] = []
    private var fftC: [Float] = [], fftS: [Float] = []
    private var rev: [Int] = []
    private let re: UnsafeMutablePointer<Float>
    private let im: UnsafeMutablePointer<Float>
    private let d: UnsafeMutablePointer<Float>
    
    init(n: Int) {
        self.n = n
        let mm = n / 2, hh = n / 4
        M = mm
        h = hh
        re = UnsafeMutablePointer<Float>.allocate(capacity: hh)
        im = UnsafeMutablePointer<Float>.allocate(capacity: hh)
        d = UnsafeMutablePointer<Float>.allocate(capacity: mm)
        for k in 0..<hh {
            let a = -Double.pi * Double(4 * k + 1) / Double(4 * mm)
            preC.append(Float(cos(a))); preS.append(Float(sin(a)))
            let b = -Double.pi * Double(k) / Double(mm)
            postC.append(Float(cos(b))); postS.append(Float(sin(b)))
        }
        for j in 0..<max(1, hh / 2) {
            let a = -2.0 * Double.pi * Double(j) / Double(hh)
            fftC.append(Float(cos(a))); fftS.append(Float(sin(a)))
        }
        rev = [Int](repeating: 0, count: hh)
        var j = 0
        for i in 1..<hh {
            var bit = hh >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            rev[i] = j
        }
    }
    
    deinit {
        re.deallocate(); im.deallocate(); d.deallocate()
    }
    
    /// x: M点の係数 -> y: n点の時間信号(窓掛け前)
    func run(_ x: UnsafePointer<Float>, _ y: UnsafeMutablePointer<Float>) {
        for k in 0..<h {
            let a = x[2 * k], b = x[M - 1 - 2 * k]
            let r = rev[k]
            re[r] = a * preC[k] - b * preS[k]
            im[r] = a * preS[k] + b * preC[k]
        }
        var len = 2
        while len <= h {
            let half = len / 2, stride = h / len
            var s = 0
            while s < h {
                for k in 0..<half {
                    let wr = fftC[k * stride], wi = fftS[k * stride]
                    let a = s + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                s += len
            }
            len <<= 1
        }
        for k in 0..<h {
            let yr = re[k] * postC[k] - im[k] * postS[k]
            let yi = re[k] * postS[k] + im[k] * postC[k]
            d[2 * k] = yr
            d[M - 1 - 2 * k] = -yi
        }
        let q = M / 2
        for i in 0..<q { y[i] = d[i + q] }
        for i in q..<(3 * q) { y[i] = -d[3 * q - 1 - i] }
        for i in (3 * q)..<(4 * q) { y[i] = -d[i - 3 * q] }
    }
}

final class VorbisDecoder {
    let channels: Int
    let sampleRate: Int
    let maxSegment: Int                         // 1回のdecodeで返る最大フレーム数
    let segment: UnsafeMutablePointer<Float>    // 出力: channels × maxSegment
    
    private let bs: [Int]
    private let cbs: [Codebook]
    private let floors: [Floor1]
    private let residues: [Residue]
    private let mappings: [VMapping]
    private let modes: [(flag: Int, mapping: Int)]
    private let plans: [IMDCTPlan]
    private let windows: [[Float]]
    private let vec: UnsafeMutablePointer<Float>
    private let tmp: UnsafeMutablePointer<Float>
    private let curve: UnsafeMutablePointer<Float>
    private var cur: UnsafeMutablePointer<Float>
    private var prev: UnsafeMutablePointer<Float>
    private var prevN = 0
    
    init(identification id: [UInt8], setup st: [UInt8]) throws {
        guard id.count >= 30, id[0] == 1, st.count > 7, st[0] == 5 else {
            throw AudioLoadError(text: "oggのヘッダーが不正です")
        }
        var br = BitReader(Array(id[7...]))
        guard br.read(32) == 0 else { throw AudioLoadError(text: "oggのバージョン未対応") }
        let ch = br.read(8)
        let rate = br.read(32)
        _ = br.read(32); _ = br.read(32); _ = br.read(32)
        let b0 = 1 << br.read(4), b1 = 1 << br.read(4)
        guard ch >= 1, rate > 0, b0 >= 64, b1 >= b0 else { throw AudioLoadError(text: "oggのヘッダーが不正です") }
        channels = ch
        sampleRate = rate
        bs = [b0, b1]
        
        br = BitReader(Array(st[7...]))
        var cb = [Codebook]()
        for _ in 0..<(br.read(8) + 1) { cb.append(try Codebook(br)) }
        for _ in 0..<(br.read(6) + 1) { _ = br.read(16) }
        var fl = [Floor1]()
        for _ in 0..<(br.read(6) + 1) {
            guard br.read(16) == 1 else { throw AudioLoadError(text: "oggのfloorが未対応です") }
            fl.append(try Floor1(br))
        }
        var rs = [Residue]()
        for _ in 0..<(br.read(6) + 1) {
            let t = br.read(16)
            rs.append(try Residue(br, type: t))
        }
        var mp = [VMapping]()
        for _ in 0..<(br.read(6) + 1) { mp.append(try VMapping(br, channels: ch)) }
        var md = [(flag: Int, mapping: Int)]()
        for _ in 0..<(br.read(6) + 1) {
            let f = br.read(1)
            _ = br.read(16); _ = br.read(16)
            md.append((flag: f, mapping: br.read(8)))
        }
        cbs = cb; floors = fl; residues = rs; mappings = mp; modes = md
        plans = [IMDCTPlan(n: b0), IMDCTPlan(n: b1)]
        
        var w = [[Float]]()
        w.append(VorbisDecoder.makeWindow(b0, b1, flag: 0, pf: 0, nf: 0))
        for pf in 0..<2 {
            for nf in 0..<2 { w.append(VorbisDecoder.makeWindow(b0, b1, flag: 1, pf: pf, nf: nf)) }
        }
        windows = w
        
        let m1 = b1 / 2
        maxSegment = b1 / 2
        vec = UnsafeMutablePointer<Float>.allocate(capacity: ch * m1)
        tmp = UnsafeMutablePointer<Float>.allocate(capacity: ch * m1)
        curve = UnsafeMutablePointer<Float>.allocate(capacity: ch * m1)
        cur = UnsafeMutablePointer<Float>.allocate(capacity: ch * b1)
        prev = UnsafeMutablePointer<Float>.allocate(capacity: ch * b1)
        segment = UnsafeMutablePointer<Float>.allocate(capacity: ch * (b1 / 2))
        cur.initialize(repeating: 0, count: ch * b1)
        prev.initialize(repeating: 0, count: ch * b1)
        segment.initialize(repeating: 0, count: ch * (b1 / 2))
    }
    
    deinit {
        vec.deallocate(); tmp.deallocate(); curve.deallocate()
        cur.deallocate(); prev.deallocate(); segment.deallocate()
    }
    
    private static func makeWindow(_ b0: Int, _ b1: Int, flag: Int, pf: Int, nf: Int) -> [Float] {
        let n = flag == 0 ? b0 : b1
        var w = [Float](repeating: 0, count: n)
        func slope(_ len: Int) -> [Float] {
            var s = [Float](repeating: 0, count: len)
            for i in 0..<len {
                let a = sin((Double(i) + 0.5) / Double(len) * Double.pi / 2)
                s[i] = Float(sin(Double.pi / 2 * a * a))
            }
            return s
        }
        var ls = 0, le = n / 2
        var lsl = slope(n / 2)
        if flag == 1 && pf == 0 {
            ls = n / 4 - b0 / 4
            le = n / 4 + b0 / 4
            lsl = slope(b0 / 2)
        }
        for i in ls..<le { w[i] = lsl[i - ls] }
        for i in le..<(n / 2) { w[i] = 1 }
        var rs = n / 2, re = n
        var rsl = slope(n / 2)
        if flag == 1 && nf == 0 {
            rs = 3 * n / 4 - b0 / 4
            re = 3 * n / 4 + b0 / 4
            rsl = slope(b0 / 2)
        }
        for i in (n / 2)..<rs { w[i] = 1 }
        for i in rs..<re { w[i] = rsl[re - 1 - i] }
        return w
    }
    
    /// シーク後に必ず呼ぶ(前のブロックとの重ね合わせを捨てる)
    func reset() { prevN = 0 }
    
    /// 1パケットをデコード。segmentに出力されたフレーム数を返す(0なら出力なし)
    func decode(_ pkt: [UInt8]) -> Int {
        let br = BitReader(pkt)
        if br.read(1) != 0 { return 0 }
        let mi = br.read(ilog(modes.count - 1))
        guard mi < modes.count else { return 0 }
        let mode = modes[mi]
        let bf = mode.flag
        var pf = 0, nf = 0
        if bf == 1 { pf = br.read(1); nf = br.read(1) }
        let n = bs[bf], M = n / 2, M1 = bs[1] / 2, S = bs[1]
        let mp = mappings[mode.mapping]
        
        var used = [Bool](repeating: false, count: channels)
        for c in 0..<channels {
            used[c] = floors[mp.floor[mp.mux[c]]].decode(br, cbs, M, curve + c * M1)
        }
        var nz = used
        for (m, a) in mp.coupling where nz[m] || nz[a] {
            nz[m] = true
            nz[a] = true
        }
        vec.initialize(repeating: 0, count: channels * M1)
        for sm in 0..<mp.subs {
            var ptrs = [UnsafeMutablePointer<Float>]()
            var dnd = [Bool]()
            for c in 0..<channels where mp.mux[c] == sm {
                ptrs.append(vec + c * M1)
                dnd.append(!nz[c])
            }
            if ptrs.isEmpty { continue }
            residues[mp.residue[sm]].decode(br, cbs, ptrs, dnd, M, tmp)
        }
        var k = mp.coupling.count - 1
        while k >= 0 {
            let (mc, ac) = mp.coupling[k]
            let mv = vec + mc * M1, av = vec + ac * M1
            for j in 0..<M {
                let m = mv[j], a = av[j]
                var nm: Float, na: Float
                if m > 0 {
                    if a > 0 { nm = m; na = m - a } else { na = m; nm = m + a }
                } else {
                    if a > 0 { nm = m; na = m + a } else { na = m; nm = m - a }
                }
                mv[j] = nm
                av[j] = na
            }
            k -= 1
        }
        
        let w = windows[bf == 0 ? 0 : 1 + pf * 2 + nf]
        let plan = plans[bf]
        for c in 0..<channels {
            let out = cur + c * S
            if !used[c] {
                out.initialize(repeating: 0, count: n)
                continue
            }
            let v = vec + c * M1, cu = curve + c * M1
            for j in 0..<M { v[j] *= cu[j] }
            plan.run(v, out)
            for i in 0..<n { out[i] *= w[i] }
        }
        
        var L = 0
        if prevN > 0 {
            L = prevN / 4 + n / 4
            for c in 0..<channels {
                let p = prev + c * S, q = cur + c * S, s = segment + c * maxSegment
                for u in 0..<L {
                    var x: Float = 0
                    let pi = prevN / 2 + u
                    if pi < prevN { x += p[pi] }
                    let ci = n / 2 - L + u
                    if ci >= 0 { x += q[ci] }
                    s[u] = x
                }
            }
        }
        let t = cur
        cur = prev
        prev = t
        prevN = n
        return L
    }
}

// MARK: - Oggコンテナ

final class OggFile {
    struct Page {
        var headerType: UInt8
        var granule: Int64
        var body: Int
        var nseg: Int
        var lastEnd: Int      // このページで終わる最後のパケットのlacing番号(なければ-1)
    }
    
    private let data: NSData
    let base: UnsafePointer<UInt8>
    private(set) var pages: [Page] = []
    
    init(url: URL) throws {
        let d = try NSData(contentsOf: url, options: .alwaysMapped)
        data = d
        base = d.bytes.assumingMemoryBound(to: UInt8.self)
        let size = d.length
        var pos = 0
        while pos + 27 <= size {
            guard base[pos] == 0x4F, base[pos + 1] == 0x67, base[pos + 2] == 0x67, base[pos + 3] == 0x53 else { break }
            var g: UInt64 = 0
            for k in 0..<8 { g |= UInt64(base[pos + 6 + k]) << UInt64(8 * k) }
            let ns = Int(base[pos + 26])
            if pos + 27 + ns > size { break }
            var total = 0, last = -1
            for k in 0..<ns {
                let l = Int(base[pos + 27 + k])
                total += l
                if l < 255 { last = k }
            }
            let body = pos + 27 + ns
            if body + total > size { break }
            pages.append(Page(headerType: base[pos + 5], granule: Int64(bitPattern: g),
                              body: body, nseg: ns, lastEnd: last))
            pos = body + total
        }
        if pages.isEmpty { throw AudioLoadError(text: "oggとして読めません") }
    }
}

final class OggPacketReader {
    struct Packet {
        var bytes: [UInt8]
        var page: Int
        var lastInPage: Bool
    }
    
    private let file: OggFile
    private var pi: Int
    private var li = 0
    private var pos: Int
    private var cur: [UInt8] = []
    private var skipping: Bool
    
    init(file: OggFile, start: Int) {
        self.file = file
        pi = start
        pos = file.pages[start].body
        skipping = (file.pages[start].headerType & 1) != 0     // 前ページから続くパケットの残りは捨てる
    }
    
    func next() -> Packet? {
        while pi < file.pages.count {
            let pg = file.pages[pi]
            while li < pg.nseg {
                let l = Int(file.base[pg.body - pg.nseg + li])
                if !skipping && l > 0 {
                    cur.append(contentsOf: UnsafeBufferPointer(start: file.base + pos, count: l))
                }
                pos += l
                let thisLi = li
                li += 1
                if l < 255 {
                    if skipping {
                        skipping = false
                        cur.removeAll()
                        continue
                    }
                    let out = cur
                    cur = []
                    return Packet(bytes: out, page: pi, lastInPage: thisLi == pg.lastEnd)
                }
            }
            pi += 1
            li = 0
            if pi < file.pages.count { pos = file.pages[pi].body }
        }
        return nil
    }
}

// MARK: - PCMソース
// 曲は、開くときに 1 回だけ SongPCM (AudioController.swift) へ展開して、再生はそれを SongPCMSource 経由で読む。
// OggPCMSource (自前の ogg デコーダー) と FilePCMSource (AVAudioFile) は、その「展開」の中で使う予備:
//   ・OggPCMSource : ipa 以外 (Swift Playgrounds) の ogg / stb_vorbis が読めなかった ogg
//   ・FilePCMSource : ogg 以外 (mp3 / wav / m4a など)
// あとは、伸ばした音 (RubberBandPCMSource / StretchedPCMSource) も PCMSource の約束で作ってある。

protocol PCMSource: AnyObject {
    var sampleRate: Double { get }
    func seek(to frame: Int64)
    /// 最大 frames フレームを左右の配列に書く。返り値は書いたフレーム数(0=終端)
    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int
}

final class OggPCMSource: PCMSource {
    let sampleRate: Double
    private let file: OggFile
    private let dec: VorbisDecoder
    private let audioStart: Int
    private var reader: OggPacketReader?
    private var known = true
    private var skip = 0
    private var target: Int64 = 0
    private var pl: [Float] = []
    private var pr: [Float] = []
    private var head = 0
    
    init(url: URL) throws {
        let f = try OggFile(url: url)
        let rd = OggPacketReader(file: f, start: 0)
        guard let p1 = rd.next(), rd.next() != nil, let p3 = rd.next() else {
            throw AudioLoadError(text: "oggのヘッダーを読めません")
        }
        let d = try VorbisDecoder(identification: p1.bytes, setup: p3.bytes)
        file = f
        dec = d
        audioStart = p3.page + 1
        sampleRate = Double(d.sampleRate)
        if audioStart >= f.pages.count { throw AudioLoadError(text: "oggに音声データがありません") }
        seek(to: 0)
    }
    
    /// 目標位置より前の最後のページから読み始め、ページ末尾の granule position で位置を確定させる。
    /// 位置が確定するまでの出力は捨て、その後 target までを読み飛ばす(サンプル単位で正確)
    func seek(to frame: Int64) {
        let pages = file.pages
        var start = audioStart
        var isKnown = true
        var best = -1
        var i = audioStart
        while i < pages.count {
            let g = pages[i].granule
            if g > frame { break }
            if g >= 0 { best = i }
            i += 1
        }
        if best >= 0 {
            start = best
            isKnown = false
        }
        reader = OggPacketReader(file: file, start: start)
        known = isKnown
        target = max(0, frame)
        skip = isKnown ? Int(target) : 0
        dec.reset()
        pl.removeAll()
        pr.removeAll()
        head = 0
    }
    
    private func fill(_ need: Int) {
        while pl.count - head < need {
            guard let rd = reader, let pkt = rd.next() else { return }
            let n = dec.decode(pkt.bytes)
            if !known {
                let g = file.pages[pkt.page].granule
                if pkt.lastInPage && g >= 0 {
                    known = true
                    skip = max(0, Int(target - g))
                }
                continue
            }
            if n == 0 { continue }
            let seg = dec.segment
            pl.append(contentsOf: UnsafeBufferPointer(start: seg, count: n))
            if dec.channels > 1 {
                pr.append(contentsOf: UnsafeBufferPointer(start: seg + dec.maxSegment, count: n))
            } else {
                pr.append(contentsOf: UnsafeBufferPointer(start: seg, count: n))
            }
            if skip > 0 {
                let k = min(skip, pl.count - head)
                head += k
                skip -= k
            }
        }
    }
    
    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        fill(frames)
        let n = min(frames, pl.count - head)
        if n <= 0 { return 0 }
        let bytes = n * MemoryLayout<Float>.size
        pl.withUnsafeBufferPointer { _ = memcpy(l, $0.baseAddress! + head, bytes) }
        pr.withUnsafeBufferPointer { _ = memcpy(r, $0.baseAddress! + head, bytes) }
        head += n
        if head >= 1 << 16 {
            pl.removeFirst(head)
            pr.removeFirst(head)
            head = 0
        }
        return n
    }
}

final class FilePCMSource: PCMSource {
    let sampleRate: Double
    private let file: AVAudioFile
    private let buf: AVAudioPCMBuffer
    
    init(url: URL) throws {
        let f = try AVAudioFile(forReading: url)
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 8192) else {
            throw AudioLoadError(text: "音源のバッファを作れません")
        }
        file = f
        buf = b
        sampleRate = f.processingFormat.sampleRate
    }
    
    func seek(to frame: Int64) {
        file.framePosition = max(0, min(frame, file.length))
    }
    
    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let want = AVAudioFrameCount(min(frames, Int(buf.frameCapacity)))
        do { try file.read(into: buf, frameCount: want) } catch { return 0 }
        let n = Int(buf.frameLength)
        guard n > 0, let cd = buf.floatChannelData else { return 0 }
        let bytes = n * MemoryLayout<Float>.size
        memcpy(l, cd[0], bytes)
        memcpy(r, buf.format.channelCount > 1 ? cd[1] : cd[0], bytes)
        return n
    }
}

// MARK: - 音声システム(AVAudioEngine + 時計)
// 譜面時刻は「実際に再生されている音のサンプル位置」から作る。別のタイマーを持たないので、
// ポーズ・リトライを何度繰り返してもズレが蓄積しない(毎回、サンプル位置を基準に再計算される)。

final class GameAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let source: PCMSource             // 展開済みの曲 (SongPCMSource)。メモリを読むだけなので、シークも最初の buffer 作りも一瞬
    private let format: AVAudioFormat
    private let sr: Double
    
    // デコード用(decodeQueue上でのみ触る)
    private let decodeQueue = DispatchQueue(label: "malody.decode", qos: .userInteractive)
    private let genLock = NSLock()
    private var _generation = 0
    private var generation: Int {                // どのスレッドからでも読める
        genLock.lock(); defer { genLock.unlock() }
        return _generation
    }
    @discardableResult
    private func bumpGeneration() -> Int {      // 古い世代のデコードを「無効」にする(待たない)
        genLock.lock(); defer { genLock.unlock() }
        _generation += 1
        return _generation
    }
    private var queued = 0
    private var eof = false
    private let chunk = 8192
    private let normalQueued = 10               // 再生中に先に積んでおく buffer の数 (ふつうの速度)
    private let stretchedQueued = 24            // 伸ばした音は作るのが重いので、再生中は多めに先に作っておく (約4.5秒ぶん)
    private let idleQueued = 4                  // 停止中 (先読み) に積んでおく数。再生ボタンを待たせないよう最小限にして、再生が始まってから runQueued まで増やす
    private var runQueued = 10                  // 再生中の目標 (速度に応じる。decodeQueue 上でだけ変える)
    private var targetQueued = 4                // 今の目標 (decodeQueue 上でだけ変える)
    private var rampDone = false                // 再生が始まってから、積んだ数が目標に届いたか (診断用。decodeQueue 上でだけ触る)
    // 診断: 再生中に「先に積んだ buffer の残り」がいちばん少なくなった値 (0 に近いほど、作成が間に合っていない)
    private let diagLock = NSLock()
    private var _minQueued = Int.max
    
    // 時計(メインスレッドでのみ触る)
    private var baseFrame: Int64 = 0         // 再生を始めたソース上のフレーム
    private var audioStartHost = 0.0         // そのフレームが鳴るはずのホスト時刻(秒)
    private var offsetTotal = 0.0            // 譜面時刻 = 曲の位置 + offsetTotal
    private var latency = 0.0                // 出力遅延(出力バッファ+機器)
    private var anchorHost = 0.0
    private var anchorPos = 0.0
    private var hasAnchor = false
    private(set) var running = false
    private var warmFrame: Int64 = -1        // warm() で先に積んでおいたソース上のフレーム (-1 = 用意なし)
    private var warmGroup: DispatchGroup?    // warm() の「シーク + 最初のバッファ投入」が終わるまでを待つための印 (メインスレッドでのみ触る)
    private(set) var lastBeginMs = 0.0       // 直近の begin() に掛かった時間 (診断用)
    private(set) var lastBeginWarm = false   // 直近の begin() が先読み済みだったか (診断用)
    
    // 再生速度 (エディタの 0.5倍未満の再生用)。遅いときは、伸ばした音を自前で作って (StretchedPCMSource) 流す。
    // 流れる音は常に「ふつうの速度の PCM」なので、player → mixer の直結のまま。速度 1.0 と同じ時計・同じ補正の仕組みで動く。
    // (以前の AVAudioUnitTimePitch は、内部の遅延を正しく知る方法がなく、0.5倍未満で曲と譜面が大きくズレた)
    private var stretched: PCMSource?                   // rate < 1.0 のときだけ持つ。decodeQueue 上でだけ触る (差し替えも decodeQueue.sync の中)
    private(set) var stretchEngine = ""                 // 今使っている時間伸縮の名前 (診断表示用。「Rubber Band R3」/「自前(窓1024)」)
    private(set) var stretchSize = 1024                 // 時間伸縮の窓の大きさ。1024 = 標準 / 512 = 立ち上がりがはっきり (低い音は少しぼやける)
    private(set) var rate = 1.0              // 再生速度 (0.1...1.0)
    private var activeSource: PCMSource { stretched ?? source }   // 今のデコード元 (decodeQueue 上でだけ使う)
    
    /// song: 展開済みの曲 (AudioController.swift の SongPCM)。エディタの再生もテストプレイも、同じものを共有する (読むだけ)。
    /// デコードはここでは行わない (SongPCM を作るときに 1 回だけ済んでいる)
    init(song: SongPCM) throws {
        let src = SongPCMSource(song)
        let rate = src.sampleRate
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else {
            throw AudioLoadError(text: "音声フォーマットを作れません")
        }
        source = src
        sr = rate
        format = f
        
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: f)
        engine.prepare()
        try engine.start()
    }
    
    private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    
    /// 譜面時刻 chartTime から再生を始める(最初でもポーズ復帰でもリトライでも同じ処理)。
    /// warm() で同じ位置を先に用意してあれば、シーク・デコード・停止を全部省いて、再生の予約だけで済む
    func begin(chartTime tc: Double, offsetTotal off: Double) {
        let t0 = uptime()
        resetQueueStats()
        let warmed = running ? -1 : warmFrame            // 鳴っている最中の呼び直しは、先読みを使わず作り直す
        if running { halt() }                            // 止まっているときは halt 済み (prepare も古いバッファを捨てる)
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(true)
        if !engine.isRunning {                              // イヤホン抜き差し・割り込み後でも復帰できるように
            engine.prepare()
            try? engine.start()
        }
        latency = totalLatency()
        offsetTotal = off - latency * rate                  // 出力遅延ぶん、譜面時刻を音の「聞こえる位置」に合わせる (速度が遅いほど、曲の位置では短い)
        let m0 = tc - offsetTotal                           // 鳴らしたい曲内の位置(秒)
        let want: Int64 = m0 >= 0 ? Int64((m0 * sr).rounded()) : 0
        warmFrame = -1
        if warmed >= 0 && abs(warmed - want) <= Int64(0.02 * rate * sr) {
            // 先に積んだバッファをそのまま使う。実時間 20ms 以内のずれ (曲の位置では 20ms × 速度) は、下の audioStartHost の補正で時刻が正確に合う
            warmGroup?.wait()                               // 先読みの「最初のバッファ投入」が途中なら、ここで終わるのを待つ (残りの補充は待たない)
            baseFrame = warmed
            lastBeginWarm = true
        } else {
            baseFrame = want
            bumpGeneration()                                // 先読みなどの補充中のデコードを先に無効にして、prepare が待たされないようにする
            prepare(from: baseFrame)                        // シーク + 最初のバッファ投入
            lastBeginWarm = false
        }
        warmGroup = nil
        let startHost = uptime() + 0.05                     // この時刻に譜面時刻 tc になる
        // フレームの丸め誤差も含めて補正(サンプル位置と譜面時刻を厳密に対応づける)
        audioStartHost = startHost + (Double(baseFrame) / sr - m0) / rate
        player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: audioStartHost)))
        hasAnchor = false
        running = true
        // 再生が始まったので、先に積む数を再生中の目標まで増やす (停止中は最小限だけ積んであった)
        let gRun = generation
        decodeQueue.async { [weak self] in
            guard let self = self, self.generation == gRun else { return }
            self.rampDone = false
            self.targetQueued = self.runQueued
            self.refill(gRun)
        }
        lastBeginMs = (uptime() - t0) * 1000
    }
    
    /// 停止中に、次の再生位置 (譜面時刻 tc) を先に用意しておく。シーク・デコードは別スレッドで行うので、メインを止めない。
    /// 位置が変わるたびに呼び直してよい (古い用意は捨てられる)
    func warm(chartTime tc: Double, offsetTotal off: Double) {
        guard !running, engine.isRunning else { return }
        let lat = totalLatency()
        let m0 = tc - (off - lat * rate)
        let want: Int64 = m0 >= 0 ? Int64((m0 * sr).rounded()) : 0
        if want == warmFrame { return }                  // すでに用意済み
        let g = bumpGeneration()                         // これまでのデコード・用意を無効にする (待たない)
        warmFrame = want
        let grp = DispatchGroup()
        grp.enter()
        warmGroup = grp
        decodeQueue.async { [weak self] in
            guard let self = self, self.generation == g else { grp.leave(); return }
            self.player.stop()                           // 古い用意のバッファを捨てる
            self.queued = 0
            self.eof = false
            self.targetQueued = min(self.idleQueued, self.runQueued)    // 停止中は最小限だけ積む (再生が始まってから増やす)
            self.activeSource.seek(to: want)
            for _ in 0..<2 { self.scheduleNext(g) }
            grp.leave()                                  // ここまでできれば再生を始められる
            self.refill(g)                               // 残りの補充は、再生ボタンを待たせない
        }
    }
    
    /// 出力遅延 (出力バッファ + 機器) の合計 (秒)
    private func totalLatency() -> Double {
        let s = AVAudioSession.sharedInstance()
        return s.outputLatency + s.ioBufferDuration
    }
    
    /// 伸ばした音のソースを作る (decodeQueue 上、または decodeQueue.sync の中で呼ぶ)。
    /// Rubber Band を組み込んだビルド (GitHub Actions。RubberBand導入手順.md) では Rubber Band を使う。
    /// 組み込んでいないビルド (Swift Playgrounds) では、自前のフェーズボコーダー (TimeStretch.swift) を使う。
    /// size は SETTING の「立ち上がりをはっきりさせる」 (512 = オン)。Rubber Band のときは、オン = Faster (R2・短い窓)、オフ = Finer (R3)
    private func makeStretcher(rate: Double, size: Int) -> PCMSource {
        #if canImport(CRubberBand)
        if let s = RubberBandPCMSource(base: source, rate: rate, sharp: size == 512) {
            stretchEngine = s.engineLabel
            return s
        }
        #endif
        stretchEngine = "自前(窓\(size))"
        return StretchedPCMSource(base: source, rate: rate, fftSize: size)
    }
    
    /// 再生速度 (0.1...1.0。音程は変えない)。停止中に呼ぶ (再生中は何もしない)。
    /// 1.0 のときは曲をそのまま流す。1.0 未満のときは、その速度に伸ばした音を自前で作って流す (TimeStretch.swift)。
    /// 速度が変わると、先に積んだ音 (先読み) は使えないので捨てる
    func setRate(_ r: Double) {
        guard !running else { return }
        let nr = min(max(r, 0.1), 1.0)
        if nr == rate { return }
        let sz = stretchSize
        bumpGeneration()                        // 先読みなどの補充中のデコードを無効にして、終わるのを待つ (差し替え中に触らせない)
        decodeQueue.sync {
            player.stop()
            queued = 0
            eof = false
            stretched = nr < 1.0 ? makeStretcher(rate: nr, size: sz) : nil
            runQueued = nr < 1.0 ? stretchedQueued : normalQueued
            targetQueued = min(idleQueued, runQueued)
        }
        warmFrame = -1
        warmGroup = nil
        hasAnchor = false
        rate = nr
    }
    
    /// 時間伸縮の窓の大きさを変える (1024 = 標準 / 512 = 立ち上がりがはっきり)。停止中に呼ぶ (再生中は何もしない)。
    /// 伸ばした音を使っているときは、作り直す。先に積んだ音 (先読み) は使えないので捨てる
    func setStretchSize(_ size: Int) {
        guard !running else { return }
        let sz = size == 512 ? 512 : 1024
        if sz == stretchSize { return }
        stretchSize = sz
        guard rate < 1.0 else { return }
        let r = rate
        bumpGeneration()
        decodeQueue.sync {
            player.stop()
            queued = 0
            eof = false
            stretched = makeStretcher(rate: r, size: sz)
            runQueued = stretchedQueued
            targetQueued = min(idleQueued, runQueued)
        }
        warmFrame = -1
        warmGroup = nil
        hasAnchor = false
    }
    
    private func resetQueueStats() {
        diagLock.lock(); defer { diagLock.unlock() }
        _minQueued = Int.max
    }
    
    private func noteQueued(_ q: Int) {
        diagLock.lock(); defer { diagLock.unlock() }
        if q < _minQueued { _minQueued = q }
    }
    
    /// 診断用: 直近の再生で、先に積んだ buffer の残りが最小だった値と、その目標の数。
    /// 最小が 0〜1 に近いと、音の作成が再生に間に合っていない (音が途切れる)
    func queueStats() -> (min: Int, target: Int) {
        diagLock.lock(); defer { diagLock.unlock() }
        return (_minQueued == Int.max ? -1 : _minQueued, rate < 1.0 ? stretchedQueued : normalQueued)
    }
    
    func halt() {
        running = false
        warmFrame = -1
        warmGroup = nil
        hasAnchor = false
        bumpGeneration()        // 先に世代を進める → stop() で発火する完了ハンドラは何もせず終わる
        player.stop()           // デコードスレッドの終了は待たない
    }
    
    func shutdown() {
        halt()
        engine.stop()
    }
    
    /// 曲の音量 0...1 (エディタの SETTING から)
    func setVolume(_ v: Float) {
        player.volume = min(max(v, 0), 1)
    }
    
    /// 毎フレーム1回呼ぶ。エンジンが報告する実際の再生位置で時計を補正する
    func refreshAnchor() {
        guard running,
              let lr = player.lastRenderTime, lr.isHostTimeValid, lr.isSampleTimeValid,
              let pt = player.playerTime(forNodeTime: lr), pt.isSampleTimeValid, pt.sampleTime >= 0 else { return }
        let hostLR = AVAudioTime.seconds(forHostTime: lr.hostTime)
        // 流れている音は、速度 rate に伸ばした音。player の経過時間 × rate が、元の曲で進んだ長さ (速度 1.0 なら従来と同じ)
        let pos = Double(baseFrame) / sr + Double(pt.sampleTime) / pt.sampleRate * rate
        let planned = Double(baseFrame) / sr + (hostLR - audioStartHost) * rate
        if abs(pos - planned) < 0.05 * rate {               // 異常値は採用しない (0.05秒 = 実時間)
            anchorHost = hostLR
            anchorPos = pos
            hasAnchor = true
        }
    }
    
    /// ホスト時刻(systemUptime / UITouch.timestamp と同じ時間軸)に対応する譜面時刻
    func chartTime(atUptime h: Double) -> Double {
        let pos = hasAnchor ? anchorPos + (h - anchorHost) * rate : Double(baseFrame) / sr + (h - audioStartHost) * rate
        return pos + offsetTotal
    }
    
    /// chartTime(atUptime:) の逆。譜面時刻 t が「聞こえる(=画面で再生ラインに触れる)」ホスト時刻。
    /// エディタがキー音の予約時刻を決めるのに使う
    func uptime(atChartTime t: Double) -> Double {
        if hasAnchor { return anchorHost + (t - offsetTotal - anchorPos) / rate }
        return audioStartHost + (t - offsetTotal - Double(baseFrame) / sr) / rate
    }
    
    /// 出力遅延 (秒)。別エンジンのキー音は、曲と同時に聞こえるよう、予約時刻をこの分だけ早める
    var outputLatency: Double { latency }
    
    // MARK: ストリーミング
    
    private func prepare(from frame: Int64) {
        decodeQueue.sync {                      // 古い世代のデコードが終わるのをここで待つ(再開時のみ)
            let g = bumpGeneration()
            player.stop()                       // halt 直後に積まれてしまった古いバッファを確実に捨てる
            queued = 0
            eof = false
            targetQueued = min(idleQueued, runQueued)
            activeSource.seek(to: frame)
            for _ in 0..<2 { scheduleNext(g) }
            decodeQueue.async { [weak self] in self?.refill(g) }
        }
    }
    
    private func refill(_ g: Int) {
        while generation == g && !eof && queued < targetQueued { scheduleNext(g) }
        if generation == g && queued >= targetQueued && targetQueued >= runQueued { rampDone = true }
    }
    
    private func scheduleNext(_ g: Int) {
        guard generation == g else { return }          // 無効になった世代は、デコードもしない
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
              let cd = buf.floatChannelData else { eof = true; return }
        let n = activeSource.read(into: cd[0], cd[1], frames: chunk)
        if n <= 0 { eof = true; return }
        buf.frameLength = AVAudioFrameCount(n)
        guard generation == g else { return }          // デコード中に無効になったら積まない
        queued += 1
        player.scheduleBuffer(buf, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.decodeQueue.async {
                guard let self = self, self.generation == g else { return }
                self.queued -= 1
                if !self.eof && self.rampDone { self.noteQueued(self.queued) }   // 積み増し中・曲の終わり近くは減って当然なので、記録しない
                self.refill(g)
            }
        }
    }
}

// MARK: - ゲーム設定(ポーズ画面で変える値。次回起動時も保存される)

final class GameSession: ObservableObject {
    @Published var paused = false
    @Published var pauseInfo = ""                   // ポーズ処理の所要時間(診断用)
    @Published var speed: Double {                  // スクロール速度の倍率 0.5〜2.0
        didSet { UserDefaults.standard.set(speed, forKey: "slide.speed") }
    }
    @Published var offsetMs: Double {               // ±300ms。+で音に対してノーツが遅く、−で早くなる
        didSet { UserDefaults.standard.set(offsetMs, forKey: "slide.offset") }
    }
    weak var view: GameView?
    var quit: () -> Void = {}
    
    init() {
        let s = UserDefaults.standard.double(forKey: "slide.speed")
        speed = s == 0 ? 1.0 : min(max(s, 0.5), 2.0)
        offsetMs = min(max(UserDefaults.standard.double(forKey: "slide.offset"), -300), 300)
    }
    
    func pause() { view?.pause() }
    func resume() { view?.resume() }
    func retry() { view?.retry() }
    func quitGame() {
        paused = false
        quit()
    }
}

// MARK: - スライドのリボン(描画専用)
// リボンの形は「時刻 × x」で最初から決まっていて、動くのは画面の縦位置だけ。
// そこで形(CGPath)は表示に入る時に1回だけ作り、毎フレームはレイヤーの位置を動かすだけにする。
// 形は mc に書かれた順に「隣り合う2点を結ぶ台形」を並べたもの(エディタと同じ)。
// 台形が重なるほど濃く見せるため、重ならない台形同士を1枚のレイヤーにまとめ、
// そのレイヤーを最大 maxLayers 枚だけ重ねる(エディタの「台形ごとに半透明で塗る」と同じ濃さになる)。

/// リボンの1区間: 時刻 ta→tb (ta < tb) の間に、中心xが xa→xb へ動く台形
private struct RibbonQuad {
    let ta: Double              // 縦の位置 (effect が無ければ時刻そのもの。effect があれば表示位置 P(t))
    let tb: Double
    let xa: Double
    let xb: Double
    /// この台形を描くのは、この時刻 (実際の時刻) より前だけ。区間の終わりの点を判定が過ぎたら、その区間は消える。
    /// -infinity = 時刻では消さない (scroll でマイナス = 逆走する譜面だけ、これを使う)
    var gate: Double = -Double.infinity
    
    func cx(_ t: Double) -> Double { xa + (xb - xa) * (t - ta) / (tb - ta) }
    
    /// 縦の位置 lo...hi の範囲だけに切り詰めた台形 (範囲の外なら nil)。
    /// jump で何百万秒も先へ飛ばした台形を、そのまま描かない (座標が大きすぎると描画が壊れる) ためのもの
    func clipped(lo: Double, hi: Double) -> RibbonQuad? {
        if tb < lo || ta > hi { return nil }
        if ta >= lo && tb <= hi { return self }
        let a = max(ta, lo)
        let b = min(tb, hi)
        return RibbonQuad(ta: a, tb: b, xa: cx(a), xb: cx(b), gate: gate)
    }
}

private struct RibbonKey: Hashable {
    let a: Int
    let b: Int
    let c: Int
    let d: Int
}

private final class RibbonView {
    let root = CALayer()
    var shapes: [CAShapeLayer] = []
}

// ---- 前処理: 判定にも描画にも状態を持たない「値」だけ。別スレッドで作る ----

private struct RibbonInput: Sendable {
    let pts: [(t: Double, x: Double)]
    let w: Double
    var times: [Double]? = nil      // effect があるとき: pts の t は「表示位置」になっている。実際の時刻は、ここに持つ
    var needsGate = false           // 逆走 (scroll < 0) があって、通り過ぎた区間を時刻で消す必要があるか
}

private struct RibbonGeometry: Sendable {
    let groups: [[RibbonQuad]]
    let lo: Double
    let hi: Double
    let xMin: Double        // 帯の左端(レーン座標, 半幅込み)
    let xMax: Double
    let peak: Int           // 1.75秒の間に始まる台形の最大数 = 同時に画面へ出る形の複雑さ
    let startT: Double      // 始点の縦の位置 (= リボンが画面に入る目安)
    let endT: Double        // リボン全体で最も遅い「実際の時刻」(これを過ぎたら全部消す)
    let gateTimes: [Double] // needsGate のとき: 台形の gate を昇順に並べたもの (どこまで消えたかを数える用)
    let needsGate: Bool
    
    static func make(_ input: RibbonInput) -> RibbonGeometry {
        var a = Double.infinity
        var b = -Double.infinity
        for p in input.pts {
            a = min(a, p.t)
            b = max(b, p.t)
        }
        let groups = RibbonSlot.makeGroups(input.pts, width: input.w, times: input.times)
        let half = input.w / 2
        var xl = Double.infinity
        var xr = -Double.infinity
        var buckets: [Int: Int] = [:]
        for g in groups {
            for q in g {
                xl = min(xl, min(q.xa, q.xb) - half)
                xr = max(xr, max(q.xa, q.xb) + half)
                buckets[Int((q.ta / 0.25).rounded(.down)), default: 0] += 1
            }
        }
        var peak = 0
        for (k, _) in buckets {
            var s = 0
            for d in 0..<7 { s += buckets[k + d] ?? 0 }
            peak = max(peak, s)
        }
        var gateTimes: [Double] = []
        if input.needsGate {
            for g in groups { for q in g { gateTimes.append(q.gate) } }
            gateTimes.sort()
        }
        return RibbonGeometry(groups: groups, lo: a, hi: b, xMin: xl, xMax: xr, peak: peak,
                              startT: input.pts.first?.t ?? a, endT: input.times?.max() ?? b,
                              gateTimes: gateTimes, needsGate: input.needsGate)
    }
}

/// 別スレッドで作った RibbonGeometry の受け渡し箱(メインスレッドが毎フレーム覗く)
private final class RibbonPrepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [RibbonGeometry?]
    private var done = false
    private var ms = 0.0
    
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    
    func set(_ i: Int, _ g: RibbonGeometry) {
        lock.lock()
        slots[i] = g
        lock.unlock()
    }
    func finish(ms: Double) {
        lock.lock()
        self.ms = ms
        done = true
        lock.unlock()
    }
    func result() -> (slots: [RibbonGeometry?], ms: Double)? {
        lock.lock()
        defer { lock.unlock() }
        return done ? (slots, ms) : nil
    }
}

// ---- ビットマップ方式(台形が多すぎて、毎フレームのベクター描画が重いリボン用) ----
// 巻き戻りで絵を描くようなスライドは、同じ時間帯に何万個もの台形が重なる。ベクターだと「画面に見えている分」
// だけでも毎フレーム描き直しになって重い。そこで形を一定の高さ(tileRows px)のタイルに分けて画像にしておき、
// 毎フレームは画像のレイヤーを動かすだけにする(描画コストが台形の数に依存しなくなる)。
//  - 画像は別スレッドで、画面に入る数秒前から焼く(メインスレッドは待たない)
//  - 焼く時は「縦 = 時刻 × ppsPx」というグローバルなピクセル格子に合わせ、レイヤー位置もピクセルに揃える。
//    だからタイルの継ぎ目は出ないし、拡大縮小のボケもない
//  - 重なりの濃さは、従来と同じく maxLayers 枚のレイヤーを順に半透明で塗って再現する(ベクター方式と同じ濃さ)
//  - 「繋がっている/いない」の2色ぶんを最初から焼いて、色が変わった時は画像を差し替えるだけ

private struct BakeConfig: Equatable {
    let scale: CGFloat
    let unit: CGFloat
    let px: CGFloat
    let width: CGFloat
}

private struct BakeJob: Sendable {
    let groups: [[RibbonQuad]]
    let halfW: Double
    let tile: Int
    let rows: Int
    let ppsPx: Double           // 縦: 1秒あたりのピクセル数
    let pxPerLane: Double       // 横: レーン1単位あたりのピクセル数
    let x0: Int                 // 画像の左端(画面左端からのピクセル数)
    let width: Int
    let epoch: Int
}

private struct BakeResult: @unchecked Sendable {
    let tile: Int
    let epoch: Int
    let on: CGImage?            // nil = そのタイルには何も描かれない
    let off: CGImage?
}

private final class TileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BakeResult] = []
    private var minEpoch = 0
    
    func put(_ r: BakeResult) {
        lock.lock()
        if r.epoch >= minEpoch { items.append(r) }
        lock.unlock()
    }
    func take() -> [BakeResult] {
        lock.lock()
        defer { lock.unlock() }
        if items.isEmpty { return [] }
        let r = items
        items.removeAll()
        return r
    }
    /// 古い設定で焼いた分は、届いていても・これから届いても捨てる
    func discard(below epoch: Int) {
        lock.lock()
        minEpoch = epoch
        items.removeAll { $0.epoch < epoch }
        lock.unlock()
    }
}

private enum RibbonBaker {
    static let queue = DispatchQueue(label: "malody.ribbon.bake", qos: .userInitiated, attributes: .concurrent)
    
    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
    
    /// 1タイル分を焼く。CGContext は y が上向き = 「未来が上」の時刻軸とそのまま対応する
    static func run(_ j: BakeJob) -> BakeResult {
        let originY = Double(j.tile * j.rows)               // このタイルの下端(グローバルなピクセル行)
        let tLo = originY / j.ppsPx                         // このタイルが受け持つ時刻範囲
        let tHi = (originY + Double(j.rows)) / j.ppsPx
        let originX = Double(j.x0)
        let hw = j.halfW * j.pxPerLane
        
        var paths: [CGPath] = []
        for quads in j.groups {
            let p = CGMutablePath()
            var any = false
            for q0 in quads where q0.tb >= tLo && q0.ta <= tHi {
                // jump で遠くへ飛ばした台形は、このタイルの範囲に切り詰める (座標が大きすぎると描画が壊れるので)
                let q = (q0.tb - q0.ta > 50) ? (q0.clipped(lo: tLo - 0.05, hi: tHi + 0.05) ?? q0) : q0
                any = true
                let ya = q.ta * j.ppsPx - originY
                let yb = q.tb * j.ppsPx - originY
                let xa = q.xa * j.pxPerLane - originX
                let xb = q.xb * j.pxPerLane - originX
                p.move(to: CGPoint(x: xa - hw, y: ya))
                p.addLine(to: CGPoint(x: xa + hw, y: ya))
                p.addLine(to: CGPoint(x: xb + hw, y: yb))
                p.addLine(to: CGPoint(x: xb - hw, y: yb))
                p.closeSubpath()
            }
            if any { paths.append(p) }
        }
        guard !paths.isEmpty,
              let on = context(j.width, j.rows),
              let off = context(j.width, j.rows) else {
            return BakeResult(tile: j.tile, epoch: j.epoch, on: nil, off: nil)
        }
        // グループ(=重ならない台形の集まり)ごとに半透明で塗る。重なった所だけ濃くなる
        for p in paths {
            on.setFillColor(red: 1, green: 1, blue: 1, alpha: RibbonSlot.onAlpha)
            on.addPath(p)
            on.fillPath()
            off.setFillColor(red: 1, green: 1, blue: 1, alpha: RibbonSlot.offAlpha)
            off.addPath(p)
            off.fillPath()
        }
        return BakeResult(tile: j.tile, epoch: j.epoch, on: on.makeImage(), off: off.makeImage())
    }
}

private final class BakedTile {
    let layer = CALayer()
    let on: CGImage
    let off: CGImage
    var lastOn: Bool?
    
    init(on: CGImage, off: CGImage, scale: CGFloat) {
        self.on = on
        self.off = off
        layer.anchorPoint = .zero
        layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(on.width) / scale, height: CGFloat(on.height) / scale)
        layer.contentsScale = scale
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.isHidden = true
    }
}

// ---- 台形の重なり判定を速くする粗いマス目(時刻 × x) ----

private struct QuadGrid {
    struct Span {
        let t0: Int
        let t1: Int
        let x0: Int
        let x1: Int
        var cells: Int { (t1 - t0 + 1) * (x1 - x0 + 1) }
    }
    
    static let tStep = 0.05         // 秒
    static let xStep = 8.0          // レーン
    static let bigCells = 400       // これを超えて広い台形はマス目に入れず、毎回全部と比べる
    
    var cells: [Int: [Int]] = [:]
    var big: [Int] = []
    
    private static func cell(_ v: Double, _ step: Double) -> Int {
        Int(max(-1_000_000.0, min(1_000_000.0, (v / step).rounded(.down))))
    }
    private static func key(_ t: Int, _ x: Int) -> Int { t &* 100_003 &+ x }
    
    static func span(_ q: RibbonQuad, half: Double) -> Span {
        let xl = min(q.xa, q.xb) - half
        let xr = max(q.xa, q.xb) + half
        return Span(t0: cell(q.ta, tStep), t1: cell(q.tb, tStep), x0: cell(xl, xStep), x1: cell(xr, xStep))
    }
    
    func clashes(_ q: RibbonQuad, _ s: Span, in quads: [RibbonQuad], width: Double) -> Bool {
        if s.cells > QuadGrid.bigCells {
            for o in quads where RibbonSlot.overlaps(o, q, width: width) { return true }
            return false
        }
        for ti in s.t0...s.t1 {
            for xi in s.x0...s.x1 {
                guard let list = cells[QuadGrid.key(ti, xi)] else { continue }
                for idx in list where RibbonSlot.overlaps(quads[idx], q, width: width) { return true }
            }
        }
        for idx in big where RibbonSlot.overlaps(quads[idx], q, width: width) { return true }
        return false
    }
    
    mutating func insert(_ index: Int, _ s: Span) {
        if s.cells > QuadGrid.bigCells {
            big.append(index)
            return
        }
        for ti in s.t0...s.t1 {
            for xi in s.x0...s.x1 {
                cells[QuadGrid.key(ti, xi), default: []].append(index)
            }
        }
    }
}

private final class RibbonSlot {
    static let maxLayers = 5        // 重なりを濃く表現する上限(これ以上重ねても見た目はほぼ変わらない)
    static let onAlpha: CGFloat = 0.45      // 繋がっている時の濃さ
    static let offAlpha: CGFloat = 0.22     // 繋がっていない時の濃さ
    
    // ---- 調整用 ----
    static let bitmapThreshold = 500        // 1.75秒の間に始まる台形がこの数以上 → ビットマップ方式。Int.max にすると従来方式のみ
    static let tileRows = 1024              // タイルの高さ(px)
    static let prefetch = 3.0               // 秒: ビットマップ方式は、画面に入る何秒前から焼き始めるか
    // ----------------
    
    let note: PlayNote
    let appear: Double              // リボンが現れる時刻 = 始点ノーツが画面上端に入る時刻(始点より前に伸びる部分もここで一気に出る)
    let lo: Double                  // リボン全体の最も早い時刻
    let hi: Double                  // 最も遅い時刻(これが判定バーを過ぎたら消す)
    let halfW: Double               // 半幅(レーン座標)
    let groups: [[RibbonQuad]]      // 重ならない台形ごとのレイヤー分け
    let xMin: Double
    let xMax: Double
    let heavy: Bool                 // true = ビットマップ方式
    let endT: Double                // 全体が判定バーを過ぎる「実際の時刻」(effect が無ければ hi と同じ)
    let needsGate: Bool             // 逆走があるので、通り過ぎた区間を時刻で消す
    let gateTimes: [Double]
    var admitted = false            // effect があるとき: 画面に入れた (一度入れたら、終わるまで外さない)
    var shown = false               // effect があるとき: 始点が画面に入って、描き始めた (逆走で始点が遠ざかっても消さない)
    var builtPassed = -1            // 今のパスを作った時に、消えていた区間の数
    
    // ベクター方式の状態
    var view: RibbonView?           // 表示中だけ持つ
    var builtUnit: CGFloat = -1     // パスを作った時の unit / pxPerSec
    var builtPx: CGFloat = -1
    var winLo = 0.0                 // 今のパスに入れている時刻の範囲(パスの原点は winLo)。
    var winHi = 0.0                 // 画面外の台形は入れない = 長いスライドでも1回に描く量が一定になる
    var lastOn: Bool?               // 今の塗り色(繋がっているか)
    
    // ビットマップ方式の状態
    var tiles: [Int: BakedTile] = [:]
    var requested = Set<Int>()
    var epoch = 0                   // 設定(速度・画面サイズ)が変わるたび・捨てるたびに進める。古い焼き上がりを見分ける
    var cfg: BakeConfig?
    var x0 = 0                      // 画像の左端 / 幅 (px)
    var pxW = 0
    let box = TileBox()
    
    init(note n: PlayNote, geo: RibbonGeometry) {
        note = n
        appear = geo.startT             // effect が無ければ n.t と同じ
        endT = geo.endT
        needsGate = geo.needsGate
        gateTimes = geo.gateTimes
        halfW = n.w / 2
        lo = geo.lo
        hi = geo.hi
        groups = geo.groups
        xMin = geo.xMin
        xMax = geo.xMax
        heavy = geo.peak >= RibbonSlot.bitmapThreshold
    }
    
    /// 全スライドの形を別スレッドで作る(重なり判定はスライドごとに独立なので並列にできる)
    static func prepare(_ inputs: [RibbonInput], into box: RibbonPrepBox) {
        if inputs.isEmpty {
            box.finish(ms: 0)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = ProcessInfo.processInfo.systemUptime
            DispatchQueue.concurrentPerform(iterations: inputs.count) { i in
                box.set(i, RibbonGeometry.make(inputs[i]))
            }
            box.finish(ms: (ProcessInfo.processInfo.systemUptime - t0) * 1000)
        }
    }
    
    /// 台形に分けて、重ならないもの同士を同じグループにまとめる(先頭から順に入る所へ入れる)。
    /// maxLayers を超えて重なる分は最後のグループにまとめて塗る(その部分は濃さが頭打ち)
    static func makeGroups(_ pts: [(t: Double, x: Double)], width: Double, times: [Double]? = nil) -> [[RibbonQuad]] {
        if pts.count < 2 { return [] }
        let k = maxLayers
        let half = width / 2
        var groups: [[RibbonQuad]] = Array(repeating: [], count: k)
        var grids = Array(repeating: QuadGrid(), count: k - 1)   // 最後のグループは重なっても良いので判定不要
        var seen: [RibbonKey: Int] = [:]
        for i in 0..<(pts.count - 1) {
            var p = pts[i]
            var q = pts[i + 1]
            if q.t < p.t { (p, q) = (q, p) }                     // 時間が戻る区間も、同じ向きの台形として扱う
            if q.t - p.t < 0.0001 { continue }                   // 同時刻の横移動は面積ゼロ
            var gate = -Double.infinity
            if let ts = times, i + 1 < ts.count { gate = max(ts[i], ts[i + 1]) }   // 区間の終わりの点を判定が過ぎたら消す
            let quad = RibbonQuad(ta: p.t, tb: q.t, xa: p.x, xb: q.x, gate: gate)
            let key = RibbonKey(a: Int((p.t * 100000).rounded()), b: Int((q.t * 100000).rounded()),
                                c: Int((p.x * 100).rounded()), d: Int((q.x * 100).rounded()))
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            if count > k { continue }                            // 全く同じ形が k 回を超えて重なっても、これ以上濃くならない
            let span = QuadGrid.span(quad, half: half)
            var placed = false
            for g in 0..<(k - 1) {
                // 近くにある台形とだけ比べる(全部と比べると、台形が何万個もある時に2乗で遅くなる)
                if grids[g].clashes(quad, span, in: groups[g], width: width) { continue }
                grids[g].insert(groups[g].count, span)
                groups[g].append(quad)
                placed = true
                break
            }
            if !placed { groups[k - 1].append(quad) }
        }
        return groups.filter { !$0.isEmpty }
    }
    
    /// 昇順の配列のうち、x 以下の個数
    static func countAtMost(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    
    /// 同じ幅の2つの台形が、面積を持って重なるか(辺が接しているだけなら false)
    static func overlaps(_ p: RibbonQuad, _ q: RibbonQuad, width: Double) -> Bool {
        let t0 = max(p.ta, q.ta)
        let t1 = min(p.tb, q.tb)
        if t1 - t0 < 0.0001 { return false }
        let d0 = p.cx(t0) - q.cx(t0)
        let d1 = p.cx(t1) - q.cx(t1)
        let nearest = ((d0 < 0) != (d1 < 0)) ? 0 : min(abs(d0), abs(d1))   // 中心線の横ずれの最小値
        return nearest < width - 0.05
    }
}

// MARK: - 画面(UIKit: CALayerの使い回し + CADisplayLink + マルチタッチ)
// 毎フレーム全画面を再描画せず、ノーツ用のレイヤーを数個だけ動かす軽量構成

final class GameView: UIView {
    // ---- 調整用 ----
    private let baseApproach = 0.55          // 秒: 速度1.0のとき、画面上端 → 判定バーまで落ちる時間
    private let judgeRatio: CGFloat = 0.82   // 判定バーの縦位置(画面の高さに対する比)
    private let judgeShift = 0.0             // 秒: 全体的に判定が早い/遅いと感じたらここで補正
    private static let countIn = 2.0         // 秒: 開始前のカウント
    // ----------------
    
    private var core: GameCore
    private let startAt: Double               // 譜面時刻(秒): テストを始める位置(0 = 最初から)
    private let chart: MalodyChart
    private let fx: EffectMap                 // scroll / jump (空なら従来どおり。判定は変わらず、見た目の位置だけが変わる)
    private var hasFX: Bool { !fx.isEmpty }
    private let audio: GameAudio?
    private let session: GameSession
    private var link: CADisplayLink?
    private var running = false
    private var pausedT = 0.0
    private var silentHost = 0.0             // 無音時の時計: この時刻に譜面時刻 silentChart
    private var silentChart = 0.0
    private var observers: [NSObjectProtocol] = []
    
    // 表示用の部品(使い回し)
    private let judgeLine = CALayer()
    private var bars: [CALayer] = []
    private let ribbonHost = CALayer()                    // リボン置き場。判定バーより下を切り落とす
    private var ribbons: [RibbonSlot] = []                // 全スライド(始点の時刻順)。形の前処理が終わってから入る
    private let ribbonSources: [PlayNote]                 // ribbons の元になるスライド(前処理の結果と同じ順)
    private let ribbonPrep: RibbonPrepBox                 // 別スレッドで作っている形の受け取り箱
    private var ribbonsReady = false
    private var ribbonNext = 0                            // まだ画面に入っていない先頭
    private var ribbonLive: [RibbonSlot] = []             // 今 描いているリボン
    private var ribbonPool: [RibbonView] = []             // 使い回し用
    private var dots: [Int: CALayer] = [:]
    private var rings: [(layer: CALayer, born: Double)] = []
    private var freeRings: [CALayer] = []
    private let comboLabel = GameView.makeLabel(72, .bold, .white)
    private let accLabel = GameView.makeLabel(24, .bold, UIColor(red: 1, green: 0.4, blue: 0.45, alpha: 1))
    private let scoreLabel = GameView.makeLabel(28, .bold, .white)
    private let fpsLabel = GameView.makeLabel(14, .regular, UIColor(white: 0.7, alpha: 1))
    private let judgeLabel = GameView.makeLabel(56, .bold, .white)
    private let resultLabel = GameView.makeLabel(30, .bold, .white)
    
    private var frames = 0
    private var fpsStamp = 0.0
    private var touchCount = 0
    
    // 診断用(ポーズ画面に出す)
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var firstFrameMs = -1.0
    private var prepMs = 0.0
    private var bakedCount = 0
    
    private var approach: Double { baseApproach / min(max(session.speed, 0.5), 2.0) }
    
    private var firstTime: Double { startAt - Self.countIn }

    init(chart: MalodyChart, audio: GameAudio?, session: GameSession, startAt: Double = 0) {
        self.chart = chart
        self.fx = chart.effects
        self.startAt = startAt
        self.core = GameCore(notes: chart.notes, startTime: startAt - GameView.countIn)
        self.audio = audio
        self.session = session
        let slides = chart.notes.filter { $0.kind == .slide && $0.ribbon.count > 1 }
        self.ribbonSources = slides
        self.ribbonPrep = RibbonPrepBox(count: slides.count)
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.03, alpha: 1)
        isMultipleTouchEnabled = true
        
        judgeLine.backgroundColor = UIColor(red: 1, green: 0.2, blue: 0.25, alpha: 0.9).cgColor
        judgeLine.zPosition = 1
        layer.addSublayer(judgeLine)
        
        ribbonHost.masksToBounds = true
        ribbonHost.zPosition = 1
        layer.addSublayer(ribbonHost)
        // リボンの形づくり(台形の重なり判定など)は重いので、別スレッドで始める。
        // カウントイン(2秒)の間に終わるので、起動は待たせない
        let fxMap = chart.effects
        RibbonSlot.prepare(slides.map { s -> RibbonInput in
            if fxMap.isEmpty { return RibbonInput(pts: s.ribbon, w: s.w) }
            // effect があるときは、リボンの形を「表示位置 × x」で作る (実際の時刻は、消すタイミングの判定用に別で持つ)
            let times = s.ribbon.map { $0.t }
            let pts = s.ribbon.map { (t: fxMap.p($0.t), x: $0.x) }
            return RibbonInput(pts: pts, w: s.w, times: times, needsGate: (times.max() ?? 0) > fxMap.negFrom)
        }, into: ribbonPrep)
        
        fpsLabel.textAlignment = .left
        scoreLabel.textAlignment = .right
        resultLabel.numberOfLines = 2
        resultLabel.isHidden = true
        for l in [comboLabel, accLabel, scoreLabel, fpsLabel, judgeLabel, resultLabel] { addSubview(l) }
        attachHitSound()
    }
    
    /// ノーツを捌いたらキー音を鳴らす (core を作り直すたびに付け直す)
    private func attachHitSound() {
        core.onHit = { KeySound.shared.playNow() }
    }
    
    required init?(coder: NSCoder) { fatalError("not used") }
    
    private static func makeLabel(_ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor) -> UILabel {
        let l = UILabel()
        l.font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.textAlignment = .center
        return l
    }
    
    private func noAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        noAnimation {
            judgeLine.frame = CGRect(x: 0, y: h * judgeRatio - 2, width: w, height: 4)
            ribbonHost.frame = CGRect(x: 0, y: 0, width: w, height: h * judgeRatio)
        }
        comboLabel.frame = CGRect(x: 0, y: h * 0.05, width: w, height: 84)
        accLabel.frame = CGRect(x: 0, y: h * 0.05 + 84, width: w, height: 30)
        scoreLabel.frame = CGRect(x: w - 280, y: 16, width: 260, height: 34)
        fpsLabel.frame = CGRect(x: 150, y: 20, width: 260, height: 24)
        judgeLabel.frame = CGRect(x: 0, y: h * 0.38, width: w, height: 70)
        resultLabel.frame = CGRect(x: 0, y: h * 0.50, width: w, height: 90)
    }
    
    // MARK: 開始・停止・ポーズ
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if link == nil { startGame() }
        } else {
            teardown()
        }
    }
    
    private func startGame() {
        session.view = self
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in self?.pause() })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] _ in self?.pause() })
        begin(at: firstTime)
    }
    
    private func teardown() {
        link?.invalidate()
        link = nil
        running = false
        audio?.shutdown()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }
    
    private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    
    /// 譜面時刻 tc から(音も含めて)再生を始める。最初・コンティニュー・リトライ共通。
    /// 毎回「曲のサンプル位置」から時刻を作り直すので、何度繰り返してもズレない
    private func begin(at tc: Double) {
        let off = chart.offset - session.offsetMs / 1000
        if let a = audio {
            a.begin(chartTime: tc, offsetTotal: off)
        } else {
            silentHost = uptime() + 0.05
            silentChart = tc
        }
        running = true
        link?.isPaused = false
        if session.paused { session.paused = false }
    }
    
    private func chartTime(at h: Double) -> Double {
        if let a = audio { return a.chartTime(atUptime: h) }
        return silentChart + (h - silentHost)
    }
    
    func pause() {
        guard running else { return }
        let tStart = uptime()
        pausedT = chartTime(at: tStart)
        running = false
        link?.isPaused = true
        core.releaseFingers()
        clearTouchEffects()
        let tAudio = uptime()
        audio?.halt()
        let tEnd = uptime()
        var info = String(format: "pause処理 %.1f ms (うち音声停止 %.1f ms)", (tEnd - tStart) * 1000, (tEnd - tAudio) * 1000)
        if ribbonsReady {
            info += String(format: "\n画面作成→最初のフレーム %.0f ms / リボン準備(別スレッド) %.0f ms / ビットマップ方式 %ld本",
                           firstFrameMs, prepMs, bakedCount)
        }
        session.pauseInfo = info
        session.paused = true
    }
    
    func resume() {
        guard !running else { return }
        begin(at: pausedT)
    }
    
    func retry() {
        core = GameCore(notes: chart.notes, startTime: firstTime)
        attachHitSound()
        noAnimation { resetRibbons() }
        resultLabel.isHidden = true
        judgeLabel.alpha = 0
        clearTouchEffects()
        begin(at: firstTime)
    }
    
    private func clearTouchEffects() {
        for d in dots.values { d.removeFromSuperlayer() }
        dots.removeAll()
        noAnimation {
            for r in rings {
                r.layer.isHidden = true
                freeRings.append(r.layer)
            }
        }
        rings.removeAll()
    }
    
    @objc private func tick(_ l: CADisplayLink) {
        guard running else { return }
        audio?.refreshAnchor()
        let now = uptime()
        if firstFrameMs < 0 { firstFrameMs = (now - createdAt) * 1000 }
        core.update(to: chartTime(at: now))
        let tView = chartTime(at: l.targetTimestamp)          // 画面に出る時刻で描く
        noAnimation { render(tView, now: now) }
    }
    
    // MARK: 入力(タッチが起きた時刻そのもので判定する)
    
    private func lane(_ sx: CGFloat) -> Double {
        Double(sx / max(bounds.width, 1)) * 255
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard running else { return }
        let now = uptime()
        for tc in touches {
            let p = tc.location(in: self)
            let id = ObjectIdentifier(tc).hashValue
            core.touchBegan(id: id, x: lane(p.x), at: chartTime(at: tc.timestamp) + judgeShift)
            touchCount += 1
            showDot(id, at: p)
            spawnRing(at: p, now: now)
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard running else { return }
        for tc in touches {
            let p = tc.location(in: self)
            let id = ObjectIdentifier(tc).hashValue
            core.touchMoved(id: id, x: lane(p.x), at: chartTime(at: tc.timestamp) + judgeShift)
            showDot(id, at: p)
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for tc in touches {
            let id = ObjectIdentifier(tc).hashValue
            core.touchEnded(id: id)
            dots[id]?.removeFromSuperlayer()
            dots[id] = nil
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
    
    // MARK: 描画
    
    private func showDot(_ id: Int, at p: CGPoint) {
        let d: CALayer
        if let e = dots[id] {
            d = e
        } else {
            d = CALayer()
            d.bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
            d.cornerRadius = 28
            d.backgroundColor = UIColor(red: 1, green: 0.3, blue: 0.35, alpha: 0.45).cgColor
            d.zPosition = 3
            layer.addSublayer(d)
            dots[id] = d
        }
        noAnimation { d.position = p }
    }
    
    private func spawnRing(at p: CGPoint, now: Double) {
        let r: CALayer
        if let f = freeRings.popLast() {
            r = f
        } else {
            r = CALayer()
            r.bounds = CGRect(x: 0, y: 0, width: 90, height: 90)
            r.cornerRadius = 45
            r.borderWidth = 3
            r.borderColor = UIColor.white.cgColor
            r.zPosition = 4
            layer.addSublayer(r)
        }
        noAnimation {
            r.position = p
            r.opacity = 1
            r.isHidden = false
            r.transform = CATransform3DMakeScale(0.5, 0.5, 1)
        }
        rings.append((layer: r, born: now))
    }
    
    private func bar(_ i: Int) -> CALayer {
        while bars.count <= i {
            let l = CALayer()
            l.zPosition = 2
            layer.addSublayer(l)
            bars.append(l)
        }
        bars[i].isHidden = false
        return bars[i]
    }
    
    // MARK: スライドのリボン
    
    private func acquireRibbonView(shapes need: Int) -> RibbonView {
        let v: RibbonView
        if let e = ribbonPool.popLast() {
            v = e
        } else {
            v = RibbonView()
            ribbonHost.addSublayer(v.root)
        }
        while v.shapes.count < need {
            let sh = CAShapeLayer()
            v.root.addSublayer(sh)
            v.shapes.append(sh)
        }
        v.root.isHidden = false
        return v
    }
    
    /// ビットマップ方式: 持っているタイルを全部捨てる。進行中の焼き込みも epoch を進めて無効にする
    private func dropTiles(_ r: RibbonSlot) {
        for tl in r.tiles.values { tl.layer.removeFromSuperlayer() }
        r.tiles.removeAll()
        r.requested.removeAll()
        r.epoch += 1
        r.box.discard(below: r.epoch)
    }
    
    private func releaseRibbon(_ r: RibbonSlot) {
        if r.heavy {
            dropTiles(r)
            r.cfg = nil
            return
        }
        if let v = r.view {
            v.root.isHidden = true
            for sh in v.shapes { sh.path = nil }
            ribbonPool.append(v)
        }
        r.view = nil
        r.builtUnit = -1
        r.builtPx = -1
        r.builtPassed = -1
        r.lastOn = nil
    }
    
    private func resetRibbons() {
        for r in ribbonLive { releaseRibbon(r) }
        ribbonLive.removeAll()
        ribbonNext = 0
        for r in ribbons {
            r.admitted = false
            r.shown = false
        }
    }
    
    /// レイヤー内の座標: x = レーン座標 × unit / y = -(時刻 - origin) × pxPerSec (上が未来)
    /// 時刻が origin...upTo にかかる台形だけをパスに入れる(台形は切らずに丸ごと入れるので継ぎ目も出ない。
    /// はみ出た分は ribbonHost の masksToBounds で切れる)
    private func ribbonPath(_ quads: [RibbonQuad], _ r: RibbonSlot, origin: Double, upTo: Double,
                            unit: CGFloat, pxPerSec: CGFloat, gateT: Double? = nil, clip: Bool = false) -> CGPath {
        let hw = CGFloat(r.halfW) * unit
        let path = CGMutablePath()
        for q0 in quads where q0.tb >= origin && q0.ta <= upTo {
            if let g = gateT, q0.gate <= g { continue }          // 中継点などを判定が過ぎた区間は、もう描かない
            var q = q0
            if clip {                                            // effect の譜面: jump で遠くへ飛んだ台形は、範囲に切り詰める
                guard let c = q0.clipped(lo: origin, hi: upTo) else { continue }
                q = c
            }
            let ya = -CGFloat(q.ta - origin) * pxPerSec
            let yb = -CGFloat(q.tb - origin) * pxPerSec
            let xa = CGFloat(q.xa) * unit
            let xb = CGFloat(q.xb) * unit
            path.move(to: CGPoint(x: xa - hw, y: ya))
            path.addLine(to: CGPoint(x: xa + hw, y: ya))
            path.addLine(to: CGPoint(x: xb + hw, y: yb))
            path.addLine(to: CGPoint(x: xb - hw, y: yb))
            path.closeSubpath()
        }
        return path
    }
    
    /// ビットマップ方式のリボンを描く(焼き込みの要求・受け取り・古いタイルの破棄・位置合わせ)
    private func renderBaked(_ r: RibbonSlot, t: Double, approach: Double, judgeY: CGFloat,
                             unit: CGFloat, pxPerSec: CGFloat, width: CGFloat) {
        let scale = max(contentScaleFactor, 1)
        let cfg = BakeConfig(scale: scale, unit: unit, px: pxPerSec, width: width)
        if r.cfg != cfg {                                       // 初回 / 速度や画面サイズが変わった時は焼き直し
            dropTiles(r)
            r.cfg = cfg
            let perLane = Double(unit * scale)
            let x0 = max(0, Int((r.xMin * perLane).rounded(.down)))
            let x1 = min(Int(Double(width * scale).rounded(.up)), Int((r.xMax * perLane).rounded(.up)))
            r.x0 = x0
            r.pxW = max(0, x1 - x0)
        }
        if r.pxW <= 0 { return }                                // 画面の外にしか無い
        
        let rows = RibbonSlot.tileRows
        let ppsPx = Double(pxPerSec * scale)                    // 縦: 1秒あたりのピクセル数
        func tileIndex(_ time: Double) -> Int { Int((time * ppsPx / Double(rows)).rounded(.down)) }
        
        // 1. 焼き上がったタイルを受け取る
        for res in r.box.take() where res.epoch == r.epoch {
            guard let on = res.on, let off = res.off, r.tiles[res.tile] == nil else { continue }
            let tl = BakedTile(on: on, off: off, scale: scale)
            ribbonHost.addSublayer(tl.layer)
            r.tiles[res.tile] = tl
        }
        
        // 2. これから見える所(+先読み2枚)で、まだ頼んでいないタイルを焼いてもらう。
        //    画面に出る前(prefetch 秒前)から頼むので、出る時にはもう焼けている
        let tShow = max(t, r.appear - approach - 0.05)
        let reqLo = max(tileIndex(tShow), tileIndex(r.lo))
        let reqHi = min(tileIndex(tShow + approach) + 2, tileIndex(r.hi))
        if reqLo <= reqHi {
            for i in reqLo...reqHi where !r.requested.contains(i) {
                r.requested.insert(i)
                startBake(r, tile: i, cfg: cfg)
            }
        }
        
        // 3. 判定バーより下に過ぎ去ったタイルは捨てる(メモリを持ち続けない)
        let visLo = tileIndex(t)
        let visHi = tileIndex(t + approach)
        for i in Array(r.tiles.keys) where i < visLo {
            r.tiles[i]?.layer.removeFromSuperlayer()
            r.tiles[i] = nil
            r.requested.remove(i)                               // 逆走で戻ってきたとき、焼き直せるように
        }
        
        // 4. 位置合わせ。ピクセルに揃えるので、タイルの継ぎ目も出ずボケもしない
        let visible = r.appear - t <= approach + 0.05
        let isOn = r.note.connected
        let baseY = (judgeY * scale + CGFloat(t * ppsPx)).rounded()
        let x = CGFloat(r.x0) / scale
        for (i, tl) in r.tiles {
            let show = visible && i <= visHi
            tl.layer.isHidden = !show
            if show {
                tl.layer.position = CGPoint(x: x, y: (baseY - CGFloat((i + 1) * rows)) / scale)
                if tl.lastOn != isOn {
                    tl.layer.contents = isOn ? tl.on : tl.off
                    tl.lastOn = isOn
                }
            }
        }
    }
    
    private func startBake(_ r: RibbonSlot, tile: Int, cfg: BakeConfig) {
        let job = BakeJob(groups: r.groups, halfW: r.halfW, tile: tile, rows: RibbonSlot.tileRows,
                          ppsPx: Double(cfg.px * cfg.scale), pxPerLane: Double(cfg.unit * cfg.scale),
                          x0: r.x0, width: r.pxW, epoch: r.epoch)
        let box = r.box
        RibbonBaker.queue.async { box.put(RibbonBaker.run(job)) }
    }
    
    /// t = 実際の時刻 / pt = 表示位置 (effect が無ければ t と同じ)。リボンの縦位置は pt、消えるタイミングは t で決まる
    private func renderRibbons(_ t: Double, pos pt: Double, approach: Double, judgeY: CGFloat, unit: CGFloat,
                               pxPerSec: CGFloat, width: CGFloat) {
        // 別スレッドで作っていた形が出来たら、ここで受け取る(出来るまでリボンは出さない)
        if !ribbonsReady {
            guard let res = ribbonPrep.result() else { return }
            var list: [RibbonSlot] = []
            for (i, g) in res.slots.enumerated() {
                if let g = g, !g.groups.isEmpty { list.append(RibbonSlot(note: ribbonSources[i], geo: g)) }
            }
            ribbons = list
            ribbonsReady = true
            prepMs = res.ms
            bakedCount = list.filter { $0.heavy }.count
        }
        // 始点ノーツが画面上端に入った時にリボンを出す(始点より前に伸びる部分も、ここで一気に現れる)。
        // ビットマップ方式は焼く時間が要るので、その prefetch 秒前から対象に入れて先に焼き始める
        if hasFX {
            // scroll / jump があると、始点の時刻の順と、画面に入る順は一致しない。全部を毎フレーム見る (軽い比較だけ)
            for r in ribbons where !r.admitted && r.appear - pt <= approach + 0.05 + RibbonSlot.prefetch {
                r.admitted = true
                if r.endT > t { ribbonLive.append(r) }
            }
        } else {
            while ribbonNext < ribbons.count
                    && ribbons[ribbonNext].appear - t <= approach + 0.05 + RibbonSlot.prefetch {
                let r = ribbons[ribbonNext]
                ribbonNext += 1
                if r.hi > t { ribbonLive.append(r) }
            }
        }
        let on = UIColor(white: 1, alpha: RibbonSlot.onAlpha).cgColor
        let off = UIColor(white: 1, alpha: RibbonSlot.offAlpha).cgColor
        var k = 0
        while k < ribbonLive.count {
            let r = ribbonLive[k]
            if r.endT <= t {                                    // 全体が判定バーを過ぎた (effect が無ければ r.hi <= t と同じ)
                releaseRibbon(r)
                ribbonLive.remove(at: k)
                continue
            }
            if r.heavy {
                renderBaked(r, t: pt, approach: approach, judgeY: judgeY, unit: unit, pxPerSec: pxPerSec, width: width)
                k += 1
                continue
            }
            if hasFX {
                // effect あり: 始点が画面に入るまでは出さない。入ったあとは、逆走で始点が遠ざかっても出し続ける
                if !r.shown {
                    if r.appear - pt > approach + 0.05 {
                        k += 1
                        continue
                    }
                    r.shown = true
                }
            } else if r.appear - pt > approach + 0.05 {         // ベクター方式: まだ画面に入らない
                k += 1
                continue
            }
            let v: RibbonView
            if let e = r.view {
                v = e
            } else {
                v = acquireRibbonView(shapes: r.groups.count)
                r.view = v
            }
            // パスに入れているのは「今見えている範囲の前後」だけ。見える範囲 [t, t+approach] がそこから出そうに
            // なった時だけ作り直す(スライド全体が短くて全部入っている時は作り直さない)
            let sameScale = r.builtUnit == unit && r.builtPx == pxPerSec     // 速度や画面サイズが変わったら作り直し
            let coversAll = r.winLo <= r.lo && r.winHi >= r.hi
            let inWindow = pt >= r.winLo && pt + approach <= r.winHi
            // 逆走のある譜面: 区間の終わりの点を判定が過ぎるたびに、その区間を消して作り直す
            let passed = r.needsGate ? RibbonSlot.countAtMost(r.gateTimes, t) : 0
            let sameGate = !r.needsGate || r.builtPassed == passed
            if !(sameScale && sameGate && (coversAll || inWindow)) {
                let wLo = pt - approach * 0.5
                let wHi = pt + approach * 2.5
                for (gi, quads) in r.groups.enumerated() {
                    v.shapes[gi].path = ribbonPath(quads, r, origin: wLo, upTo: wHi, unit: unit, pxPerSec: pxPerSec,
                                                   gateT: r.needsGate ? t : nil, clip: hasFX)
                    v.shapes[gi].isHidden = false
                }
                r.builtPassed = passed
                r.winLo = wLo
                r.winHi = wHi
                if v.shapes.count > r.groups.count {
                    for gi in r.groups.count..<v.shapes.count {
                        v.shapes[gi].path = nil
                        v.shapes[gi].isHidden = true
                    }
                }
                r.builtUnit = unit
                r.builtPx = pxPerSec
                r.lastOn = nil
            }
            v.root.position = CGPoint(x: 0, y: judgeY + CGFloat(pt - r.winLo) * pxPerSec)
            let isOn = r.note.connected
            if r.lastOn != isOn {
                let col = isOn ? on : off
                for sh in v.shapes { sh.fillColor = col }
                r.lastOn = isOn
            }
            k += 1
        }
    }
    
    private func color(of j: Judge) -> UIColor {
        switch j {
        case .best: return UIColor(red: 1.0, green: 0.3, blue: 0.35, alpha: 1)
        case .cool: return UIColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1)
        case .good: return UIColor(red: 0.4, green: 1.0, blue: 0.5, alpha: 1)
        case .miss: return UIColor(white: 0.6, alpha: 1)
        }
    }
    
    private func setText(_ l: UILabel, _ s: String) {
        if l.text != s { l.text = s }
    }
    
    /// 時刻 t 以降で最初のノーツの番号 (notes は時刻順)
    private func firstNote(atOrAfter t: Double, in notes: [PlayNote]) -> Int {
        var lo = 0, hi = notes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if notes[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    
    private func render(_ t: Double, now: Double) {
        let approach = self.approach
        let w = bounds.width, h = bounds.height
        let judgeY = h * judgeRatio
        let unit = w / 255                                   // レーン1単位あたりのpt
        let barH = max(10, h * 0.016)
        let pxPerSec = judgeY / CGFloat(approach)             // 1秒あたりの縦移動量
        func yAt(_ dt: Double) -> CGFloat { judgeY * (1 - CGFloat(dt / approach)) }   // dt = 判定までの残り秒
        
        let white = UIColor(white: 1, alpha: 0.95).cgColor
        let yellow = UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1).cgColor
        
        // 表示位置: effect (scroll / jump) が無ければ、時刻そのもの
        let pt = hasFX ? fx.p(t) : t
        renderRibbons(t, pos: pt, approach: approach, judgeY: judgeY, unit: unit, pxPerSec: pxPerSec, width: w)
        
        var bi = 0
        let notes = core.notes
        if hasFX {
            // effect あり: 画面に見える位置 (表示位置が pt-0.3 〜 pt+approach) にいるノーツだけを、時刻の範囲に直して拾う。
            // (scroll / jump で、時刻の順と画面の順は一致しない)
            let firstIdx = core.firstIndex
            for rng in fx.timeRanges(p: pt - 0.3, pt + approach + 0.05) {
                var i = max(firstIdx, firstNote(atOrAfter: rng.lo, in: notes))
                while i < notes.count && notes[i].t <= rng.hi && bi < 400 {
                    let n = notes[i]
                    i += 1
                    if n.state == .done { continue }
                    if n.kind == .slide && n.state != .waiting { continue }
                    let d = fx.p(n.t) - pt
                    if d > approach + 0.05 || d < -0.3 { continue }
                    let b = bar(bi)
                    bi += 1
                    b.frame = CGRect(x: CGFloat(n.x - n.w / 2) * unit, y: yAt(d) - barH / 2,
                                     width: CGFloat(n.w) * unit, height: barH)
                    b.backgroundColor = n.kind == .wipe ? yellow : white
                }
            }
        } else {
            var i = core.firstIndex
            while i < notes.count {
                let n = notes[i]
                i += 1
                let dt = n.t - t
                if dt > approach + 0.05 { break }
                if n.state == .done { continue }
                
                if n.kind == .slide && n.state != .waiting { continue }   // リボンは renderRibbons で描く。始点の白い帯は未処理の間だけ
                
                let b = bar(bi)
                bi += 1
                b.frame = CGRect(x: CGFloat(n.x - n.w / 2) * unit, y: yAt(dt) - barH / 2,
                                 width: CGFloat(n.w) * unit, height: barH)
                b.backgroundColor = n.kind == .wipe ? yellow : white
            }
        }
        for k in bi..<bars.count { bars[k].isHidden = true }
        
        // タッチエフェクト
        var k = 0
        while k < rings.count {
            let age = now - rings[k].born
            if age >= 0.3 {
                rings[k].layer.isHidden = true
                freeRings.append(rings[k].layer)
                rings.remove(at: k)
            } else {
                let p = CGFloat(age / 0.3)
                rings[k].layer.opacity = Float(1 - p)
                rings[k].layer.transform = CATransform3DMakeScale(0.5 + p, 0.5 + p, 1)
                k += 1
            }
        }
        
        // HUD
        setText(comboLabel, core.combo > 0 ? "\(core.combo)" : "")
        setText(accLabel, String(format: "%.2f%%", core.accuracy))
        setText(scoreLabel, "\(core.score)")
        if t < 0 {
            setText(judgeLabel, "\(Int(ceil(-t)))")
            judgeLabel.textColor = .white
            judgeLabel.alpha = 1
        } else if let j = core.lastJudge, t - core.lastJudgeAt < 0.6 {
            setText(judgeLabel, j.name)
            judgeLabel.textColor = color(of: j)
            judgeLabel.alpha = CGFloat(1 - (t - core.lastJudgeAt) / 0.6)
        } else {
            judgeLabel.alpha = 0
        }
        if core.isFinished && t > core.endTime + 0.3 {
            setText(resultLabel, "FINISH\n" + String(format: "ACC %.2f%%   MAX COMBO %ld", core.accuracy, core.maxCombo))
            resultLabel.isHidden = false
        }
        
        frames += 1
        if now - fpsStamp >= 0.5 {
            let fps = Double(frames) / (now - fpsStamp)
            frames = 0
            fpsStamp = now
            setText(fpsLabel, String(format: "%.0f fps", fps) + "  touch \(touchCount)")
        }
    }
}

// MARK: - SwiftUI(メニューと画面の橋渡し)

struct GameRepresentable: UIViewRepresentable {
    let chart: MalodyChart
    let audio: GameAudio?
    let session: GameSession
    var startAt: Double = 0
    
    func makeUIView(context: Context) -> GameView {
        GameView(chart: chart, audio: audio, session: session, startAt: startAt)
    }
    func updateUIView(_ uiView: GameView, context: Context) {}
}

struct PauseOverlay: View {
    @ObservedObject var session: GameSession
    
    private var offsetBinding: Binding<Double> {
        Binding(get: { session.offsetMs },
                set: { session.offsetMs = min(max($0.rounded(), -300), 300) })
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Text("PAUSE").font(.title.bold())
                    if !session.pauseInfo.isEmpty {
                        Text(session.pauseInfo)
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.gray)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("スクロール速度")
                            Spacer()
                            Text(String(format: "×%.1f", session.speed)).monospacedDigit()
                        }
                        Slider(value: $session.speed, in: 0.5...2.0, step: 0.1)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("オフセット (ms)")
                            Spacer()
                            TextField("0", value: offsetBinding, format: .number)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                        Slider(value: offsetBinding, in: -300...300, step: 1)
                        Text("＋で音に対してノーツが遅く、−で早くなります (±300)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    HStack(spacing: 12) {
                        Button("終了") { session.quitGame() }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        Button("コンティニュー") { session.resume() }
                            .buttonStyle(.borderedProminent)
                        Button("リトライ") { session.retry() }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                }
                .foregroundColor(.white)
                .padding(24)
                .frame(maxWidth: 460)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.13)))
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - エディタ連携 (ここから下がエディタ用の追加分)

/// テストプレイ開始時にエディタが作る「お膳立て」
struct TestPlayLaunch: Identifiable {
    let id = UUID()
    let chart: MalodyChart
    let audio: GameAudio?
    let startSec: Double          // 譜面時間(秒)。エディタの現在位置
}

/// フルスクリーンで出すテストプレイ画面 (PAUSE → 終了 でエディタに戻る)
struct TestPlayScreen: View {
    let launch: TestPlayLaunch
    let onClose: () -> Void
    @StateObject private var session = GameSession()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            GameRepresentable(chart: launch.chart, audio: launch.audio, session: session, startAt: launch.startSec)
                .ignoresSafeArea()
            if !session.paused {
                Button { session.pause() } label: {
                    Label("PAUSE", systemImage: "pause.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                        .padding(16)
                }
            }
            if session.paused {
                PauseOverlay(session: session)
            }
        }
        .statusBarHidden(true)      // fullScreenCover は別の画面扱いなので、ここにも付ける
        .persistentSystemOverlays(.hidden)      // ホームバーも同じ (EditorView と同じ設定。RootView を参照)
        .defersSystemGestures(on: .bottom)
        .onAppear {
            session.paused = false
            session.quit = onClose
        }
    }
}
