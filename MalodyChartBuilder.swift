import Foundation

// エディタ上の譜面 (ChartData) から、テストプレイ用の譜面 (MalodyChart) を直接作る。
//
// 以前は、テストプレイを始めるたびに「譜面 → JSON に書き出し → JSONDecoder で読み直し」をしていた。
// 譜面が大きいほど、その分だけ始まるのが遅れた。ここでは、メモリ上の譜面から SlideRawChart を作り、
// SlideCore.swift の SlideChart (本家と同じ時間計算・並び・スクロール) に渡す。

enum PlayChartError: Error { case noTiming }

/// テストプレイ用の譜面
struct MalodyChart {
    let title: String
    let offset: Double          // 秒。曲の頭が来る譜面時刻 (大きいほど曲の開始が遅れる)
    let slide: SlideChart       // 時間・ノーツ・スクロール (本家の仕様どおり。SlideCore.swift)

    var isEmpty: Bool { slide.notes.isEmpty }
}

extension MalodyChart {
    static func make(from chart: ChartData) throws -> MalodyChart {
        func sb(_ b: Beat) -> SlideBeat {
            let t = b.jsonTriple
            return SlideBeat(t.0, t.1, t.2)
        }
        var raw = SlideRawChart()
        raw.title = chart.metaString(["song", "title"])
        raw.times = chart.times.map { SlideRawChart.Time(beat: sb($0.beat), bpm: $0.bpm) }
        raw.notes.reserveCapacity(chart.notes.count)
        var offsetMs = 0.0
        for n in chart.notes {
            if n.type == 1 { offsetMs = n.extra["offset"]?.doubleValue ?? 0; continue }   // 音源ノート
            raw.notes.append(SlideRawChart.Note(
                beat: sb(n.beat), x: n.x, w: n.w, type: n.type,
                segs: n.segs.map { SlideRawChart.Seg(beat: sb($0.beat), x: $0.x) }))
        }
        // 音源の行 (type 1)。エディタでは notes と別に持っている。保存では notes の後ろに並ぶので、offset は最後のものが勝つ
        for s in chart.soundEntries where s["type"]?.intValue == 1 {
            offsetMs = s["offset"]?.doubleValue ?? 0
        }
        raw.offsetMs = offsetMs
        // effect: 拍の順に並べる (同じ拍の scroll と jump は SlideChart がひとつにまとめる)
        for e in chart.effects.sorted(by: { $0.beat < $1.beat }) {
            raw.effects.append(SlideRawChart.Effect(beat: sb(e.beat),
                                                    scroll: e.kind == .scroll ? e.value : nil,
                                                    jump: e.kind == .jump ? e.value : nil))
        }
        guard let slide = SlideChart(raw: raw) else { throw PlayChartError.noTiming }
        return MalodyChart(title: raw.title, offset: offsetMs / 1000, slide: slide)
    }
}
