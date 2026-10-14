import Foundation

// エディタ上の譜面 (ChartData) から、テストプレイ用の譜面 (MalodyChart) を直接作る。
//
// 以前は、テストプレイを始めるたびに「譜面 → JSON に書き出し → JSONDecoder で読み直し (MalodyChart.load)」をしていた。
// 譜面が大きいほど、その分だけ始まるのが遅れた。ここでは、メモリ上の譜面から直接 PlayNote を作る。
//
// 結果は MalodyChart.load(chart.serialized()) と、数値まで同じになるようにしてある。
//  ・拍の値は「保存される形 [整数部, 分子, 分母] の 整数部 + 分子 / 分母」(Beat.value とは、桁の端で 1ulp 違うことがあるため、load と同じ式で計算する)
//  ・拍 → 秒は、load と同じ足し算の順番 (BPM の変化点ごとの累計を先に作っておき、二分探索で区間を選ぶ。以前は毎回、先頭から足していた)
//  ・ノーツの並びも同じ (拍の順 → そのあと時刻の順)

extension MalodyChart {
    static func make(from chart: ChartData) throws -> MalodyChart {
        // load の beat(): v[0] + v[1] / v[2] (分母が 0 なら 0)
        func jb(_ b: Beat) -> Double {
            let t = b.jsonTriple
            guard t.2 != 0 else { return 0 }
            return Double(t.0) + Double(t.1) / Double(t.2)
        }

        let timing = chart.times
            .sorted { $0.beat < $1.beat }                       // 保存されるときの並び
            .map { (beat: jb($0.beat), bpm: $0.bpm) }
            .filter { $0.bpm > 0 }
            .sorted { $0.beat < $1.beat }
        guard let head = timing.first else { throw PlayChartError.noTiming }

        // 区間ごとの「そこまでの秒」の累計 (load の sec() が毎回足していたものと、同じ順番・同じ式)
        var cum = [Double](repeating: 0, count: timing.count)
        var t = 0.0
        var pb = head.beat
        var bpm = head.bpm
        for k in 1..<max(1, timing.count) {
            let e = timing[k]
            t += (e.beat - pb) * 60 / bpm
            pb = e.beat
            bpm = e.bpm
            cum[k] = t
        }
        // beat -> 秒。「beat が b より前にある変化点」のうち、最後のものの区間を使う
        func sec(_ b: Double) -> Double {
            var lo = 1
            var hi = timing.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if timing[mid].beat < b { lo = mid + 1 } else { hi = mid }
            }
            let k = lo - 1
            return cum[k] + (b - timing[k].beat) * 60 / timing[k].bpm
        }

        var notes: [PlayNote] = []
        notes.reserveCapacity(chart.notes.count)
        var offset = 0.0
        for n in chart.notes.sorted(by: { $0.beat < $1.beat }) {
            if n.type == 1 { offset = (n.extra["offset"]?.doubleValue ?? 0) / 1000; continue }   // 音源ノート
            let x = Double(n.x)
            let w = Double(n.w)
            let b = jb(n.beat)
            let t0 = sec(b)
            if n.type == 4 {
                notes.append(PlayNote(kind: .wipe, t: t0, x: x, w: w))
            } else if !n.segs.isEmpty {
                // seg の beat と x は始点からの相対値
                var all: [(t: Double, x: Double)] = []
                all.reserveCapacity(n.segs.count + 1)
                all.append((t: t0, x: x))
                for s in n.segs { all.append((t: sec(b + jb(s.beat)), x: x + Double(s.x))) }
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
        // 音源の行 (type 1)。エディタでは notes と別に持っている。保存では notes の後ろに並ぶので、offset は最後のものが勝つ
        for s in chart.soundEntries where s["type"]?.intValue == 1 {
            offset = (s["offset"]?.doubleValue ?? 0) / 1000
        }
        notes.sort { $0.t < $1.t }

        // effect (scroll / jump)。jump は ms の単位 (1000 = 1 秒間に scroll で進む距離)。scroll との掛け算は EffectMap 側でする
        var events: [EffectMap.Event] = []
        for e in chart.effects.sorted(by: { $0.beat < $1.beat }) {
            guard e.beat.jsonTriple.2 != 0 else { continue }
            let b = jb(e.beat)
            events.append(EffectMap.Event(t: sec(b),
                                          scroll: e.kind == .scroll ? e.value : nil,
                                          jumpMs: e.kind == .jump ? e.value : 0))
        }
        return MalodyChart(title: chart.metaString(["song", "title"]), offset: offset, notes: notes,
                           effects: EffectMap.make(events))
    }
}
