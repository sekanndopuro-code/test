import Foundation

enum ChartError: Error {
    case invalid
}

/// スライドの経由点。beat / x はどちらも「始点からの相対値」
struct Seg {
    var beat: Beat
    var x: Int
}

/// タップ / ウィップ(type 4) / スライド(seg あり)
/// x は「中心座標」(0...255)、w は幅
struct Note {
    var beat: Beat
    var x: Int
    var w: Int
    var type: Int? = nil
    var segs: [Seg] = []
    var extra: [String: Any] = [:]   // 未知のキーは保存時にそのまま書き戻す
    var id = UUID()                  // 選択状態の管理用 (mc には書き出さない。コピーした時は付け直す)
}

extension Note {
    init?(dict: [String: Any]) {
        guard let b = Beat(json: dict["beat"]) else { return nil }
        self.beat = b
        self.x = (dict["x"] as? NSNumber)?.intValue ?? 0
        self.w = (dict["w"] as? NSNumber)?.intValue ?? 64
        self.type = (dict["type"] as? NSNumber)?.intValue
        var list: [Seg] = []
        if let arr = dict["seg"] as? [[String: Any]] {
            for s in arr {
                if let sb = Beat(json: s["beat"]) {
                    list.append(Seg(beat: sb, x: (s["x"] as? NSNumber)?.intValue ?? 0))
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

    var dict: [String: Any] {
        var d = extra
        d["beat"] = beat.json
        d["x"] = x
        d["w"] = w
        if let t = type, t != 0 { d["type"] = t }
        if !segs.isEmpty {
            d["seg"] = segs.map { s -> [String: Any] in
                ["beat": s.beat.json, "x": s.x]
            }
        }
        return d
    }

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

struct TimePoint {
    var beat: Beat
    var bpm: Double
}

/// effect 1 つ (mc の "effect" の要素)。scroll か jump のどちらか 1 つ。
/// scroll: その拍から、譜面の流れる速さが value 倍になる (0 で止まる / マイナスで逆走)
/// jump:   その拍になった瞬間、譜面が先へ一気に飛ぶ。value は ms で、1000 = 1 秒間に進む距離ぶん (そのときの scroll に比例)
/// 見た目が変わるのはテストプレイ (と本家) だけで、エディタの画面は変わらない
struct EffectPoint {
    enum Kind: String {
        case scroll, jump
        var label: String { rawValue }
    }
    var beat: Beat
    var kind: Kind
    var value: Double
    var extra: [String: Any] = [:]   // 未知のキーは保存時にそのまま書き戻す

    /// 一覧に出す値 (整数なら小数点なし。10000000 のような大きな値も、そのまま読める)
    var valueText: String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}

/// beat <-> 秒 の変換 (BPM変化対応)。秒は「譜面時間」(offset は含まない)
struct TimeMap {
    private var bs: [Double] = []
    private var spb: [Double] = []
    private var secs: [Double] = []

    init(_ pts: [TimePoint]) {
        var list = pts.sorted { $0.beat < $1.beat }
        if list.isEmpty { list = [TimePoint(beat: .zero, bpm: 120)] }
        var t = 0.0
        for i in 0..<list.count {
            let b = list[i].beat.value
            if i > 0 { t += (b - bs[i - 1]) * spb[i - 1] }
            bs.append(b)
            spb.append(60.0 / max(1.0, list[i].bpm))
            secs.append(t)
        }
    }

    func sec(atBeat b: Double) -> Double {
        var i = 0
        while i + 1 < bs.count && bs[i + 1] <= b { i += 1 }
        return secs[i] + (b - bs[i]) * spb[i]
    }

    func beat(atSec s: Double) -> Double {
        var i = 0
        while i + 1 < secs.count && secs[i + 1] <= s { i += 1 }
        return bs[i] + (s - secs[i]) / spb[i]
    }

    func index(atBeat b: Double) -> Int {
        var i = 0
        while i + 1 < bs.count && bs[i + 1] <= b { i += 1 }
        return i
    }
}

struct ChartData {
    var root: [String: Any]            // meta / effect / extra など (note, time 以外)
    var times: [TimePoint]
    var notes: [Note]
    var soundEntries: [[String: Any]]  // "sound" を持つ特別ノート (offset などを保持)
    var effects: [EffectPoint] = []    // mc の "effect" のうち scroll / jump
    var otherEffects: [[String: Any]] = []   // それ以外の形の effect は、読み取らずにそのまま書き戻す
    var hadEffectKey = false           // 読み込んだ mc に "effect" のキーがあったか (無かったら、空のままなら書かない)

    static func parse(_ data: Data) throws -> ChartData {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChartError.invalid
        }
        var times: [TimePoint] = []
        if let arr = root["time"] as? [[String: Any]] {
            for e in arr {
                if let b = Beat(json: e["beat"]), let bpm = (e["bpm"] as? NSNumber)?.doubleValue {
                    times.append(TimePoint(beat: b, bpm: bpm))
                }
            }
        }
        if times.isEmpty { times = [TimePoint(beat: .zero, bpm: 120)] }
        var notes: [Note] = []
        var sounds: [[String: Any]] = []
        if let arr = root["note"] as? [[String: Any]] {
            for e in arr {
                if e["sound"] != nil {
                    sounds.append(e)
                } else if let n = Note(dict: e) {
                    notes.append(n)
                }
            }
        }
        var effects: [EffectPoint] = []
        var others: [[String: Any]] = []
        let hadKey = root["effect"] != nil
        if let arr = root["effect"] as? [[String: Any]] {
            for e in arr {
                guard let b = Beat(json: e["beat"]) else { others.append(e); continue }
                var rest = e
                rest.removeValue(forKey: "beat")
                var found = false
                // 1 つの要素に scroll と jump が両方書かれていても、2 つの effect として読む
                if let v = (e["scroll"] as? NSNumber)?.doubleValue {
                    rest.removeValue(forKey: "scroll")
                    effects.append(EffectPoint(beat: b, kind: .scroll, value: v, extra: [:]))
                    found = true
                }
                if let v = (e["jump"] as? NSNumber)?.doubleValue {
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

    func serialized() throws -> Data {
        var out = root
        out["time"] = times.sorted { $0.beat < $1.beat }.map { t -> [String: Any] in
            ["beat": t.beat.json, "bpm": t.bpm]
        }
        var arr: [[String: Any]] = notes.sorted { $0.beat < $1.beat }.map { $0.dict }
        arr.append(contentsOf: soundEntries)
        out["note"] = arr
        // effect は、あるとき (または元の mc にキーがあったとき) だけ書く
        var fx: [[String: Any]] = effects.sorted { $0.beat < $1.beat }.map { e -> [String: Any] in
            var d = e.extra
            d["beat"] = e.beat.json
            d[e.kind.rawValue] = e.value
            return d
        }
        fx.append(contentsOf: otherEffects)
        if !fx.isEmpty || hadEffectKey { out["effect"] = fx }
        return try JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes, .sortedKeys])
    }

    // MARK: メタデータ

    func metaString(_ path: [String]) -> String {
        var cur: Any? = root["meta"]
        for k in path {
            cur = (cur as? [String: Any])?[k]
        }
        return (cur as? String) ?? ""
    }

    mutating func setMetaString(_ path: [String], _ v: String) {
        var meta = root["meta"] as? [String: Any] ?? [:]
        if path.count == 1 {
            meta[path[0]] = v
        } else if path.count == 2 {
            var sub = meta[path[0]] as? [String: Any] ?? [:]
            sub[path[1]] = v
            meta[path[0]] = sub
        }
        root["meta"] = meta
    }

    var soundFile: String {
        get { (soundEntries.first?["sound"] as? String) ?? "" }
        set {
            if soundEntries.isEmpty {
                soundEntries = [["beat": [0, 0, 1], "sound": newValue, "vol": 100, "offset": 0, "type": 1]]
            } else {
                soundEntries[0]["sound"] = newValue
            }
        }
    }

    /// 音源のオフセット(ms)。譜面時間 t の音源再生位置は t - offset/1000 (editor.html と同じ)
    var offsetMs: Int {
        get { (soundEntries.first?["offset"] as? NSNumber)?.intValue ?? 0 }
        set {
            if soundEntries.isEmpty {
                soundEntries = [["beat": [0, 0, 1], "sound": "", "vol": 100, "offset": newValue, "type": 1]]
            } else {
                soundEntries[0]["offset"] = newValue
            }
        }
    }

    // MARK: extra.test (エディタ設定: divide / speed)

    func testInt(_ key: String) -> Int? {
        let extra = root["extra"] as? [String: Any]
        let test = extra?["test"] as? [String: Any]
        return (test?[key] as? NSNumber)?.intValue
    }

    mutating func setTest(_ key: String, _ value: Int) {
        var extra = root["extra"] as? [String: Any] ?? [:]
        var test = extra["test"] as? [String: Any] ?? [:]
        test[key] = value
        extra["test"] = test
        root["extra"] = extra
    }
}
