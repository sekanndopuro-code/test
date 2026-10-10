import Foundation

/// 曲全体シークバー (再生ボタンの下) のノーツ密度。本家の赤いヒストグラムと同じ作り。
///
/// 本家のスクリーンショット (iPad Air 4 横画面 2360×1640px) を 1 ピクセルずつ測って決めた仕様:
/// - 曲全体を縦に **120 等分** (112 ではない)。1 本 = 6.84pt おき、棒の太さ 5.4pt (ピッチの 0.79 倍)
/// - 棒の長さは **20 段階** (最大 = 67.4pt、1 段 = 3.37pt)。長さが 1 段の整数倍にそろっていて、
///   しかも最大の長さの棒が 120 本中 19 本もあった (= 上限で頭打ちになっている) ので、
///   「その区間のノーツの数 (上限 20)」を、「全区間のうちの最大」を 1.0 とした割合にしている
/// - 数えるのは、タップ / ウィップ / スライドの始点 だけ (スライドの seg = 中継点は数えない)
enum SeekDensity {
    /// 縦の分割数
    static let binCount = 120
    /// 1 区間で数える上限。これ以上は同じ長さ (最大) になる。
    /// 純粋に「最大の区間 = 1.0」だけにしたいときは Int.max にする
    static let levelCap = 20

    /// 区間ごとのノーツ数 (上限を掛ける前)。[0] = 曲の頭 (画面では下) … [binCount - 1] = 曲の末 (画面では上)。
    /// totalSec の外 (マイナスの時刻 / 曲より後ろ) のノーツは数えない
    static func counts(notes: [Note], timeMap: TimeMap, totalSec: Double) -> [Int] {
        var out = [Int](repeating: 0, count: binCount)
        guard totalSec > 0 else { return out }
        let scale = Double(binCount) / totalSec
        let last = binCount - 1

        func add(_ beat: Double) {
            guard beat.isFinite else { return }
            let sec = timeMap.sec(atBeat: beat)
            guard sec.isFinite, sec >= 0, sec <= totalSec else { return }
            var k = Int(sec * scale)
            if k > last { k = last }
            out[k] += 1
        }

        for n in notes {
            add(n.beat.value)                       // タップ / ウィップ / スライドの始点 (seg は数えない)
        }
        return out
    }

    /// 棒の長さの割合 (0...1)。上限 levelCap で頭打ちにしてから、いちばん大きい区間を 1.0 にする。
    /// ノーツが 1 つも無い区間は 0 (棒を描かない)
    static func ratios(_ counts: [Int]) -> [Double] {
        let capped = counts.map { min($0, levelCap) }
        let peak = capped.max() ?? 0
        if peak <= 0 { return [Double](repeating: 0, count: counts.count) }
        return capped.map { Double($0) / Double(peak) }
    }
}
