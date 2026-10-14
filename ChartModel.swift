import Foundation

enum ChartError: Error {
    case invalid
}

/// スライドの経由点。beat / x はどちらも「始点からの相対値」
struct Seg: Sendable {
    var beat: Beat
    var x: Int
}

/// ノーツを区別する番号 (選択状態・Order・プラグインとのやり取りに使う)。
/// 以前は UUID (16バイト・作るのも比べるのも重い) だったが、整数にした。
/// 番号は作った順に 1, 2, 3… と増えるだけで、mc には書き出さない。
typealias NoteID = Int

/// NoteID を作る。どのスレッドから呼んでも、同じ番号は出ない
final class NoteIDGenerator: @unchecked Sendable {
    static let shared = NoteIDGenerator()
    private let lock = NSLock()
    private var counter = 0
    func next() -> NoteID {
        lock.lock()
        counter += 1
        let v = counter
        lock.unlock()
        return v
    }
}

enum NoteIDGen {
    static func next() -> NoteID { NoteIDGenerator.shared.next() }
}

/// タップ / ウィップ(type 4) / スライド(seg あり)
/// x は「中心座標」(0...255)、w は幅
struct Note: Sendable {
    var beat: Beat
    var x: Int
    var w: Int
    var type: Int? = nil
    var segs: [Seg] = []
    var extra: [String: JSONValue] = [:]   // 未知のキーは保存時にそのまま書き戻す
    var id: NoteID = NoteIDGen.next()      // 選択状態の管理用 (mc には書き出さない。コピーした時は付け直す)
}

extension Note {
    init?(json dict: [String: JSONValue]) {
        guard let b = Beat(json: dict["beat"]) else { return nil }
        self.beat = b
        self.x = dict["x"]?.intValue ?? 0
        self.w = dict["w"]?.intValue ?? 64
        self.type = dict["type"]?.intValue
        var list: [Seg] = []
        if let arr = dict["seg"]?.arrayOfObjects {
            list.reserveCapacity(arr.count)
            for s in arr {
                if let sb = Beat(json: s["beat"]) {
                    list.append(Seg(beat: sb, x: s["x"]?.intValue ?? 0))
                }
            }
        }
        self.segs = list
        var e = dict
        for k in ["beat", "x", "w", "type", "seg"] {
            e.removeValue(forKey: k)
        }
        self.extra = e
    }

    /// mc に書く形 (キーの順番は書き出すときに並べ替える)
    var jsonObject: [String: JSONValue] {
        var d = extra
        d["beat"] = beat.jsonValue
        d["x"] = .int(x)
        d["w"] = .int(w)
        if let t = type, t != 0 { d["type"] = .int(t) }
        if !segs.isEmpty {
            d["seg"] = .array(segs.map { s -> JSONValue in
                .object(["beat": s.beat.jsonValue, "x": .int(s.x)])
            })
        }
        return d
    }

    /// 1 つのノーツを JSON にして out へ足す (キーは並べ替え済みの順)。
    /// 未知のキーが無いふつうのノーツは、辞書を作らずに直接書く (保存を軽くするため。結果は jsonObject と同じ)
    func write(into out: inout [UInt8]) throws {
        if !extra.isEmpty {
            try JSONValue.writeObject(jsonObject, into: &out)
            return
        }
        // キーの並び: beat < seg < type < w < x
        out.append(contentsOf: Note.kBeat)
        beat.write(into: &out)
        if !segs.isEmpty {
            out.append(contentsOf: Note.kSeg)
            out.append(0x5B)
            var first = true
            for s in segs {
                if !first { out.append(0x2C) }
                first = false
                out.append(contentsOf: Note.kSegBeat)
                s.beat.write(into: &out)
                out.append(contentsOf: Note.kSegX)
                JSONValue.writeInt(s.x, into: &out)
                out.append(0x7D)
            }
            out.append(0x5D)
        }
        if let t = type, t != 0 {
            out.append(contentsOf: Note.kType)
            JSONValue.writeInt(t, into: &out)
        }
        out.append(contentsOf: Note.kW)
        JSONValue.writeInt(w, into: &out)
        out.append(contentsOf: Note.kX)
        JSONValue.writeInt(x, into: &out)
        out.append(0x7D)
    }

    private static let kBeat = Array("{\"beat\":".utf8)
    private static let kSeg = Array(",\"seg\":".utf8)
    private static let kSegBeat = Array("{\"beat\":".utf8)
    private static let kSegX = Array(",\"x\":".utf8)
    private static let kType = Array(",\"type\":".utf8)
    private static let kW = Array(",\"w\":".utf8)
    private static let kX = Array(",\"x\":".utf8)

    var isWipe: Bool { type == 4 }
    var isSlide: Bool { !segs.isEmpty }

    /// seg を含めた beat の最小・最大
    var span: (lo: Double, hi: Double) {
        let s = beat.value
        var lo = s
        var hi = s
        for g in segs {
            let v = s + g.beat.value
            lo = min(lo, v)
            hi = max(hi, v)
        }
        return (lo, hi)
    }
}

struct TimePoint: Sendable {
    var beat: Beat
    var bpm: Double
}

/// effect 1 つ (mc の "effect" の要素)。scroll か jump のどちらか 1 つ。
/// scroll: その拍から、譜面の流れる速さが value 倍になる (0 で止まる / マイナスで逆走)
/// jump:   その拍になった瞬間、譜面が先へ一気に飛ぶ。value は ms で、1000 = 1 秒間に進む距離ぶん (そのときの scroll に比例)
/// 見た目が変わるのはテストプレイ (と本家) だけで、エディタの画面は変わらない
struct EffectPoint: Sendable {
    enum Kind: String, Sendable {
        case scroll, jump
        var label: String { rawValue }
    }
    var beat: Beat
    var kind: Kind
    var value: Double
    var extra: [String: JSONValue] = [:]   // 未知のキーは保存時にそのまま書き戻す

    /// 一覧に出す値 (整数なら小数点なし。10000000 のような大きな値も、そのまま読める)
    var valueText: String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}

/// beat <-> 秒 の変換 (BPM変化対応)。秒は「譜面時間」(offset は含まない)
/// BPM の変化点は拍の昇順に並んでいるので、二分探索で区間を探す (以前は先頭から順に探していた)
struct TimeMap: Sendable {
    private var bs: [Double] = []
    private var spb: [Double] = []
    private var secs: [Double] = []

    init(_ pts: [TimePoint]) {
        var list = pts.sorted { $0.beat < $1.beat }
        if list.isEmpty { list = [TimePoint(beat: .zero, bpm: 120)] }
        var t = 0.0
        bs.reserveCapacity(list.count)
        spb.reserveCapacity(list.count)
        secs.reserveCapacity(list.count)
        for i in 0..<list.count {
            let b = list[i].beat.value
            if i > 0 { t += (b - bs[i - 1]) * spb[i - 1] }
            bs.append(b)
            spb.append(60.0 / max(1.0, list[i].bpm))
            secs.append(t)
        }
    }

    /// a[i] <= x を満たす最後の i (昇順の配列)。無ければ 0。
    /// (以前の `while i + 1 < n && a[i + 1] <= x { i += 1 }` と同じ答え。nan のときも 0)
    @inline(__always)
    private static func lastIndex(notAfter x: Double, in a: [Double]) -> Int {
        // a[0] は常に採用 (i は 0 から始まる) なので、1 以降で「a[k] <= x」が成り立たなくなる最初の位置を探す
        var lo = 1
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if a[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    func sec(atBeat b: Double) -> Double {
        let i = TimeMap.lastIndex(notAfter: b, in: bs)
        return secs[i] + (b - bs[i]) * spb[i]
    }

    func beat(atSec s: Double) -> Double {
        let i = TimeMap.lastIndex(notAfter: s, in: secs)
        return bs[i] + (s - secs[i]) / spb[i]
    }

    func index(atBeat b: Double) -> Int {
        TimeMap.lastIndex(notAfter: b, in: bs)
    }
}

struct ChartData: Sendable {
    var root: [String: JSONValue]      // meta / extra など (note, time, effect 以外)
    var times: [TimePoint]
    /// ノーツ。どこで書き換えても notesRevision が増えるので、索引 (NoteIndex) などの作り直しの目印になる
    var notes: [Note] { didSet { notesRevision &+= 1 } }
    var soundEntries: [[String: JSONValue]]  // "sound" を持つ特別ノート (offset などを保持)
    var effects: [EffectPoint]         // mc の "effect" のうち scroll / jump
    var otherEffects: [[String: JSONValue]]  // それ以外の形の effect は、読み取らずにそのまま書き戻す
    var hadEffectKey: Bool             // 読み込んだ mc に "effect" のキーがあったか (無かったら、空のままなら書かない)
    var notesRevision = 0

    init(root: [String: JSONValue], times: [TimePoint], notes: [Note], soundEntries: [[String: JSONValue]],
         effects: [EffectPoint] = [], otherEffects: [[String: JSONValue]] = [], hadEffectKey: Bool = false) {
        self.root = root
        self.times = times
        self.notes = notes
        self.soundEntries = soundEntries
        self.effects = effects
        self.otherEffects = otherEffects
        self.hadEffectKey = hadEffectKey
    }

    static func parse(_ data: Data) throws -> ChartData {
        guard case .object(var root) = try JSONValue.parse(data) else {
            throw ChartError.invalid
        }
        var times: [TimePoint] = []
        if let arr = root["time"]?.arrayOfObjects {
            for e in arr {
                if let b = Beat(json: e["beat"]), let bpm = e["bpm"]?.doubleValue {
                    times.append(TimePoint(beat: b, bpm: bpm))
                }
            }
        }
        if times.isEmpty { times = [TimePoint(beat: .zero, bpm: 120)] }
        var notes: [Note] = []
        var sounds: [[String: JSONValue]] = []
        if let arr = root["note"]?.arrayOfObjects {
            notes.reserveCapacity(arr.count)
            for e in arr {
                if e["sound"] != nil {
                    sounds.append(e)
                } else if let n = Note(json: e) {
                    notes.append(n)
                }
            }
        }
        var effects: [EffectPoint] = []
        var others: [[String: JSONValue]] = []
        let hadKey = root["effect"] != nil
        if let arr = root["effect"]?.arrayOfObjects {
            for e in arr {
                guard let b = Beat(json: e["beat"]) else { others.append(e); continue }
                var rest = e
                rest.removeValue(forKey: "beat")
                var found = false
                // 1 つの要素に scroll と jump が両方書かれていても、2 つの effect として読む
                if let v = e["scroll"]?.doubleValue {
                    rest.removeValue(forKey: "scroll")
                    effects.append(EffectPoint(beat: b, kind: .scroll, value: v, extra: [:]))
                    found = true
                }
                if let v = e["jump"]?.doubleValue {
                    rest.removeValue(forKey: "jump")
                    effects.append(EffectPoint(beat: b, kind: .jump, value: v, extra: [:]))
                    found = true
                }
                if !found { others.append(e); continue }
                if !rest.isEmpty, let last = effects.indices.last { effects[last].extra = rest }   // 未知のキーは最後の 1 つに付ける
            }
        }
        root.removeValue(forKey: "note")
        root.removeValue(forKey: "time")
        root.removeValue(forKey: "effect")
        return ChartData(root: root, times: times, notes: notes, soundEntries: sounds,
                         effects: effects, otherEffects: others, hadEffectKey: hadKey)
    }

    /// mc の JSON にする。どのスレッドから呼んでもよい (ChartData は値なので、コピーを渡せば保存を別スレッドでできる)。
    /// 以前は JSONSerialization で辞書の木を作っていたが、いまは直接書く (キーの並び・数の書き方は同じ)
    func serialized() throws -> Data {
        // 並べ替えたあとの順番。note は拍の順、そのあとに sound の行
        let sortedNotes = notes.sorted { $0.beat < $1.beat }
        var fx: [JSONValue] = effects.sorted { $0.beat < $1.beat }.map { e -> JSONValue in
            var d = e.extra
            d["beat"] = e.beat.jsonValue
            d[e.kind.rawValue] = .double(e.value)
            return .object(d)
        }
        fx.append(contentsOf: otherEffects.map { JSONValue.object($0) })
        let writeEffect = !fx.isEmpty || hadEffectKey

        // トップレベルのキーを並べ替えて書く (note / time / effect は root の同名キーを置き換える)
        var keys = Set(root.keys)
        keys.insert("time")
        keys.insert("note")
        if writeEffect { keys.insert("effect") } else { keys.remove("effect") }

        var out: [UInt8] = []
        out.reserveCapacity(sortedNotes.count * 48 + 4096)
        out.append(0x7B)
        var first = true
        for k in keys.sorted() {
            if !first { out.append(0x2C) }
            first = false
            JSONValue.writeString(k, into: &out)
            out.append(0x3A)
            switch k {
            case "time":
                out.append(0x5B)
                var f2 = true
                for t in times.sorted(by: { $0.beat < $1.beat }) {
                    if !f2 { out.append(0x2C) }
                    f2 = false
                    // キーの並び: beat < bpm
                    out.append(contentsOf: Array("{\"beat\":".utf8))
                    t.beat.write(into: &out)
                    out.append(contentsOf: Array(",\"bpm\":".utf8))
                    try JSONValue.writeDouble(t.bpm, into: &out)
                    out.append(0x7D)
                }
                out.append(0x5D)
            case "note":
                out.append(0x5B)
                var f2 = true
                for n in sortedNotes {
                    if !f2 { out.append(0x2C) }
                    f2 = false
                    try n.write(into: &out)
                }
                for s in soundEntries {
                    if !f2 { out.append(0x2C) }
                    f2 = false
                    try JSONValue.writeObject(s, into: &out)
                }
                out.append(0x5D)
            case "effect":
                try JSONValue.array(fx).write(into: &out)
            default:
                try root[k]!.write(into: &out)
            }
        }
        out.append(0x7D)
        return Data(out)
    }

    // MARK: メタデータ

    func metaString(_ path: [String]) -> String {
        var cur: JSONValue? = root["meta"]
        for k in path {
            cur = cur?.objectValue?[k]
        }
        return cur?.stringValue ?? ""
    }

    mutating func setMetaString(_ path: [String], _ v: String) {
        var meta = root["meta"]?.objectValue ?? [:]
        if path.count == 1 {
            meta[path[0]] = .string(v)
        } else if path.count == 2 {
            var sub = meta[path[0]]?.objectValue ?? [:]
            sub[path[1]] = .string(v)
            meta[path[0]] = .object(sub)
        }
        root["meta"] = .object(meta)
    }

    var soundFile: String {
        get { soundEntries.first?["sound"]?.stringValue ?? "" }
        set {
            if soundEntries.isEmpty {
                soundEntries = [["beat": .array([.int(0), .int(0), .int(1)]), "sound": .string(newValue),
                                 "vol": .int(100), "offset": .int(0), "type": .int(1)]]
            } else {
                soundEntries[0]["sound"] = .string(newValue)
            }
        }
    }

    /// 音源のオフセット(ms)。譜面時間 t の音源再生位置は t - offset/1000 (editor.html と同じ)
    var offsetMs: Int {
        get { soundEntries.first?["offset"]?.intValue ?? 0 }
        set {
            if soundEntries.isEmpty {
                soundEntries = [["beat": .array([.int(0), .int(0), .int(1)]), "sound": .string(""),
                                 "vol": .int(100), "offset": .int(newValue), "type": .int(1)]]
            } else {
                soundEntries[0]["offset"] = .int(newValue)
            }
        }
    }

    // MARK: extra.test (エディタ設定: divide / speed)

    func testInt(_ key: String) -> Int? {
        root["extra"]?.objectValue?["test"]?.objectValue?[key]?.intValue
    }

    mutating func setTest(_ key: String, _ value: Int) {
        var extra = root["extra"]?.objectValue ?? [:]
        var test = extra["test"]?.objectValue ?? [:]
        test[key] = .int(value)
        extra["test"] = .object(test)
        root["extra"] = .object(extra)
    }
}
