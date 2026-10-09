import Foundation

// MARK: - 曲を先に PCM へ展開しておくソース (再生ボタンの待ち時間を縮める)
//
// 自前の ogg デコーダーは、シークのたびに「目標位置の手前のページ頭」からデコードし直して、
// 位置が合うまでの出力を捨てる。さらに最初の buffer も作る。最適化なしのビルドでは、この「シーク + 最初の buffer」が
// 数十〜数百 ms 掛かり、位置を動かしてすぐ再生ボタンを押すと (先読みが間に合わない)、そのぶん再生が遅れて始まる。
//
// そこで、曲全体を背景スレッドで先に PCM (Float 左右) に展開しておく。
//   ・展開済みの区間は memcpy だけで読める → シークはほぼ一瞬、最初の buffer 作りも一瞬
//   ・展開が済んでいない区間は、従来どおり元のソース (live) でデコードする (遅いだけで、動作は変わらない)
//   ・背景スレッドは「いま見ている位置 (focus)」に近い区間から展開する。位置が変わったら focus も移る
//   ・再生中は背景の展開を止める (再生の邪魔をしない)
//   ・使うメモリは 展開した長さ × 約 21 MB/分 (44.1kHz ステレオ)。上限 (既定 200MB ≒ 9 分) を超える分は展開せず、従来どおり
//
// 背景スレッドは、元のソースとは別のインスタンス (makeFiller で作る) を使う。
// 読み出し (seek / read) は GameAudio の decodeQueue 上でだけ呼ばれる。背景スレッドと共有するのは blocks などで、lock で守る。

final class CachedPCMSource: PCMSource, @unchecked Sendable {
    let sampleRate: Double

    private static let blockFrames = 1 << 15        // 1 ブロック = 32768 フレーム (44.1kHz で約 0.74 秒)

    /// 展開した 1 ブロック。作ったあとは変えない (読む側は lock の外で memcpy してよい)
    private final class Block {
        let count: Int                              // 入っているフレーム数 (曲の最後のブロックだけ blockFrames より少ない)
        let l: [Float]
        let r: [Float]
        init(count: Int, l: [Float], r: [Float]) {
            self.count = count
            self.l = l
            self.r = r
        }
    }

    private let live: PCMSource                     // 未展開の区間を読むための元のソース (decodeQueue 上でだけ使う)
    private let makeFiller: () throws -> PCMSource  // 背景スレッド用の、別のソースを作る
    private let maxBlocks: Int

    // 背景スレッドと共有する (lock で守る)
    private let lock = NSLock()
    private var blocks: [Int: Block] = [:]
    private var endBlock: Int? = nil                // 曲の終わりのすぐ後ろのブロック番号 (わかったら)
    private var focusBlock = 0                      // ここから先を優先して展開する
    private var paused = false
    private var cancelled = false
    private var started = false

    // 読み出し側 (decodeQueue 上でだけ触る)
    private var pos: Int64 = 0                      // 次に読むフレーム
    private var livePos: Int64 = -1                 // live が次に読むフレーム (-1 = 不明)

    init(live: PCMSource, memoryLimitMB: Int = 200, makeFiller: @escaping () throws -> PCMSource) {
        self.live = live
        self.makeFiller = makeFiller
        self.sampleRate = live.sampleRate
        let perBlock = CachedPCMSource.blockFrames * 2 * MemoryLayout<Float>.size
        self.maxBlocks = max(1, memoryLimitMB * 1024 * 1024 / perBlock)
    }

    // MARK: 背景での展開

    /// 背景スレッドで展開を始める (1 回だけ)
    func startFilling() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        let t = Thread { [weak self] in self?.fillLoop() }
        t.name = "malody.pcmcache"
        t.qualityOfService = .utility                // 画面・再生より下の優先度
        t.start()
    }

    /// 展開をやめる (曲を閉じるとき)。展開済みのぶんは、このオブジェクトが無くなるときに解放される
    func stop() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// 再生中は展開を止める / 止まったら再開する
    func setPaused(_ p: Bool) {
        lock.lock()
        paused = p
        lock.unlock()
    }

    /// 次の再生位置 (曲内のフレーム)。ここから先を優先して展開する
    func setFocus(frame: Int64) {
        let k = Int(max(0, frame) / Int64(CachedPCMSource.blockFrames))
        lock.lock()
        focusBlock = k
        lock.unlock()
    }

    /// そのフレームが展開済みか (診断用)
    func isCached(frame: Int64) -> Bool {
        let k = Int(max(0, frame) / Int64(CachedPCMSource.blockFrames))
        lock.lock()
        defer { lock.unlock() }
        return blocks[k] != nil
    }

    /// 次に展開するブロック。focus 以降で最初の未展開 → なければ曲の頭から focus の手前まで。全部済んでいれば nil (lock を持って呼ぶ)
    private func nextBlockLocked() -> Int? {
        let limit = min(endBlock ?? Int.max, maxBlocks)
        if limit <= 0 { return nil }
        let start = min(max(0, focusBlock), limit)
        var k = start
        while k < limit {
            if blocks[k] == nil { return k }
            k += 1
        }
        k = 0
        while k < start {
            if blocks[k] == nil { return k }
            k += 1
        }
        return nil
    }

    private func fillLoop() {
        guard let bg = try? makeFiller() else { return }       // 作れなければ展開しない (従来どおり live だけで動く)
        let bf = CachedPCMSource.blockFrames
        var at = -1                                             // bg が次に読むブロック番号 (-1 = 不明)
        while true {
            lock.lock()
            let stopNow = cancelled
            let hold = paused
            let next: Int? = (stopNow || hold) ? nil : nextBlockLocked()
            lock.unlock()
            if stopNow { return }
            if hold {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard let k = next else { return }                  // 全部展開した
            if at != k {
                bg.seek(to: Int64(k) * Int64(bf))               // 連続して展開するときはシークしない
                at = k
            }
            var l = [Float](repeating: 0, count: bf)
            var r = [Float](repeating: 0, count: bf)
            var got = 0
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    guard let lb = lp.baseAddress, let rb = rp.baseAddress else { return }
                    while got < bf {
                        let n = bg.read(into: lb + got, rb + got, frames: min(8192, bf - got))
                        if n <= 0 { break }
                        got += n
                    }
                }
            }
            lock.lock()
            if cancelled { lock.unlock(); return }
            if got <= 0 {
                endBlock = min(endBlock ?? k, k)                // k は曲の終わりより先
                at = -1
            } else {
                if got < bf {                                   // 曲の最後のブロック
                    l.removeLast(bf - got)
                    r.removeLast(bf - got)
                    endBlock = min(endBlock ?? (k + 1), k + 1)
                    at = -1
                } else {
                    at = k + 1
                }
                blocks[k] = Block(count: got, l: l, r: r)
            }
            lock.unlock()
        }
    }

    // MARK: PCMSource (decodeQueue 上でだけ呼ばれる)

    func seek(to frame: Int64) {
        pos = max(0, frame)
    }

    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let bf = Int64(CachedPCMSource.blockFrames)
        var done = 0
        while done < frames {
            let k = Int(pos / bf)
            let off = Int(pos - Int64(k) * bf)
            lock.lock()
            let b = blocks[k]
            let end = endBlock
            lock.unlock()
            if let b = b {
                let n = min(frames - done, b.count - off)
                if n <= 0 { break }                              // 最後の (短い) ブロックの後ろ = 曲の終わり
                let bytes = n * MemoryLayout<Float>.size
                b.l.withUnsafeBufferPointer { _ = memcpy(l + done, $0.baseAddress! + off, bytes) }
                b.r.withUnsafeBufferPointer { _ = memcpy(r + done, $0.baseAddress! + off, bytes) }
                pos += Int64(n)
                done += n
            } else {
                if let e = end, k >= e { break }                 // 曲の終わりより先
                if livePos != pos {
                    live.seek(to: pos)                           // 展開済みの区間を読んでいた間に、live の位置はずれている
                }
                let n = live.read(into: l + done, r + done, frames: frames - done)
                if n <= 0 {
                    livePos = pos
                    break
                }
                pos += Int64(n)
                done += n
                livePos = pos
            }
        }
        return done
    }
}
