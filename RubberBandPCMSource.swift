// MARK: - Rubber Band による時間伸縮 (0.75 / 0.5 / 0.25 / 0.1 倍の再生用)
//
// このファイルは `CRubberBand` (Rubber Band を C++ のまま組み込んだ SwiftPM ターゲット) があるときだけ中身が有効になる。
//   ・GitHub Actions のビルド (RubberBand導入手順.md の手順で組み込んだもの) → Rubber Band を使う
//   ・Swift Playgrounds (C++ を組み込めない) → このファイルは空になり、TimeStretch.swift の自前フェーズボコーダーのまま動く
// どちらで動いているかは、再生したあとの SETTING 下の診断表示 (「伸ばした音(...)」) で分かる。
//
// ■ 作り方 (自前の StretchedPCMSource と同じ約束)
//   seek(to: f) の f は「元の曲のフレーム」。出力の n フレーム目 = 元の曲の (f + n × 速度) フレーム付近。
//   出力は速度 1.0 の PCM (サンプリング周波数は元と同じ) なので、GameAudio は player → mixer の直結のまま鳴らせる。
//   Rubber Band は入力から遅れて出力する (開始遅延)。ここでは次のようにして、この遅れを「計算で」消している:
//     1. rubberband_reset
//     2. rubberband_get_preferred_start_pad() フレームぶんを、先に入力する
//        (曲の頭より前は無音、そうでなければ f の直前の本物の音。ぶつ切りの立ち上がりにならない)
//     3. rubberband_get_start_delay() フレームぶんの出力を捨てる
//   これで出力の先頭が f の位置の音になる。もしズレて聞こえたら `trimFrames` で動かせる。
//
// ■ 動き方
//   RealTime モード + ThreadingNever (別スレッドを作らない)。decodeQueue 上でだけ呼ばれる (PCMSource の約束と同じ)。
//   read が呼ばれるたびに、出力が足りなければ rubberband_get_samples_required() ぶんの入力を渡す (入力は base から読む)。
//
// ■ ライセンス
//   Rubber Band は GPL v2 以上 (または商用ライセンス)。自分用 / リポジトリを公開して配る分には GPL で足りる。
//   ソースを公開しないまま ipa を配る・ストアに出すときは商用ライセンスが要る。

#if canImport(CRubberBand)
import Foundation
import CRubberBand

final class RubberBandPCMSource: PCMSource {
    let sampleRate: Double
    let rate: Double

    /// 出力の位置の微調整 (出力側のフレーム数)。
    /// 正 = 音が早くなる (出力の頭を余分に捨てる) / 負 = 音が遅くなる (頭に無音を足す)。
    /// 速度 0.25 でクリック音がノーツ (譜面) より遅く聞こえるなら、正の値にする。通常は 0 のままでよい
    static var trimFrames = 0

    /// この速度より遅いときは、重い Finer (R3) をやめて Faster (R2) を使う。0 = いつも Finer。
    /// 0.1 倍で音が途切れる・変になるときは 0.2 などにする
    static var finerMinRate = 0.0

    /// 診断表示用の名前
    let engineLabel: String

    private let base: PCMSource
    private var state: OpaquePointer?

    private let maxIn = 4096                                     // 1 回に Rubber Band へ渡す入力の最大フレーム数 (作業用の領域も同じ大きさ)
    private let inL: UnsafeMutablePointer<Float>
    private let inR: UnsafeMutablePointer<Float>
    private let dumpL: UnsafeMutablePointer<Float>                // 開始遅延で捨てる出力の受け皿
    private let dumpR: UnsafeMutablePointer<Float>
    private let inPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>          // [左, 右] の入力ポインタの配列
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>  // [左, 右] の出力ポインタの配列

    private var skip = 0              // 出力の頭から捨てるフレーム数 (開始遅延 + trim)
    private var silence = 0           // 出力の頭に足す無音のフレーム数 (trim が負のとき)
    private var baseEOF = false       // base (元の曲) の終わりに着いた
    private var sentFinal = false     // 最後の入力 (final) を渡した

    /// sharp: true なら立ち上がり重視の Faster (R2 / 短い窓)、false なら高品質の Finer (R3)
    init?(base: PCMSource, rate: Double, sharp: Bool) {
        let r = min(max(rate, 0.05), 1.0)
        // rubberband-c.h の RubberBandOption のビット:
        //   ProcessRealTime = 0x1 / ThreadingNever = 0x10000 / ChannelsTogether = 0x10000000
        //   WindowShort = 0x100000 (R2 用) / EngineFiner = 0x20000000 (R3)
        var opts: Int32 = 0x0000_0001 | 0x0001_0000 | 0x1000_0000
        let finer = !sharp && r >= RubberBandPCMSource.finerMinRate
        if finer {
            opts |= 0x2000_0000
        } else {
            opts |= 0x0010_0000
        }
        guard let s = rubberband_new(UInt32(base.sampleRate.rounded()), 2, opts, 1.0 / r, 1.0) else { return nil }
        rubberband_set_max_process_size(s, 4096)

        // 作業用の領域は、先に局所変数で作って初期化してから、まとめてプロパティへ入れる
        func buf() -> UnsafeMutablePointer<Float> {
            let b = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
            b.initialize(repeating: 0, count: 4096)
            return b
        }
        let ip = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
        ip.initialize(repeating: nil, count: 2)
        let op = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        op.initialize(repeating: nil, count: 2)

        self.base = base
        self.rate = r
        self.sampleRate = base.sampleRate
        self.engineLabel = finer ? "Rubber Band R3" : "Rubber Band R2"
        self.state = s
        self.inL = buf()
        self.inR = buf()
        self.dumpL = buf()
        self.dumpR = buf()
        self.inPtrs = ip
        self.outPtrs = op
    }

    deinit {
        if let s = state { rubberband_delete(s) }
        inL.deallocate()
        inR.deallocate()
        dumpL.deallocate()
        dumpR.deallocate()
        inPtrs.deallocate()
        outPtrs.deallocate()
    }

    // MARK: PCMSource (decodeQueue 上でだけ呼ばれる)

    func seek(to frame: Int64) {
        guard let s = state else { return }
        let want = max(0, frame)
        rubberband_reset(s)
        rubberband_set_time_ratio(s, 1.0 / rate)               // reset 後も速度が残る作りだが、念のため入れ直す
        baseEOF = false
        sentFinal = false

        let pad = Int(rubberband_get_preferred_start_pad(s))
        let shift = Int(rubberband_get_start_delay(s)) + RubberBandPCMSource.trimFrames
        skip = max(0, shift)
        silence = max(0, -shift)

        // 先に pad フレームぶんを入れる。曲の頭より前は無音、それ以外は want の直前の本物の音
        let from = want - Int64(pad)
        var zeroLead = 0
        if from < 0 {
            zeroLead = Int(-from)
            base.seek(to: 0)
        } else {
            base.seek(to: from)
        }
        var left = pad
        while left > 0 {
            let n = min(left, maxIn)
            fill(n, zeroLead: &zeroLead)
            process(s, n, final: false)
            left -= n
        }
    }

    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard let s = state, frames > 0 else { return 0 }
        var done = 0
        var spins = 0
        while done < frames {
            spins += 1
            if spins > 8192 { break }                          // 念のための歯止め (出力が全く出ないとき)

            if silence > 0 {                                   // trim が負: 頭に無音を足す
                let n = min(silence, frames - done)
                memset(l + done, 0, n * MemoryLayout<Float>.size)
                memset(r + done, 0, n * MemoryLayout<Float>.size)
                silence -= n
                done += n
                continue
            }

            let avail = Int(rubberband_available(s))
            if avail < 0 { break }                             // final のあと、全部出し切った
            if avail == 0 {
                if sentFinal { break }
                feedMore(s)
                continue
            }

            if skip > 0 {                                      // 開始遅延ぶんの出力は捨てる
                let n = min(avail, skip, maxIn)
                outPtrs[0] = dumpL
                outPtrs[1] = dumpR
                let got = Int(rubberband_retrieve(s, outPtrs, UInt32(n)))
                if got <= 0 { break }
                skip -= got
                continue
            }

            let n = min(avail, frames - done)
            outPtrs[0] = l + done
            outPtrs[1] = r + done
            let got = Int(rubberband_retrieve(s, outPtrs, UInt32(n)))
            if got <= 0 { break }
            done += got
        }
        return done
    }

    // MARK: 入力

    /// 出力を作るのに足りない入力を base から読んで Rubber Band に渡す
    private func feedMore(_ s: OpaquePointer) {
        var req = Int(rubberband_get_samples_required(s))
        if req <= 0 { req = 256 }
        req = min(req, maxIn)
        var zeroLead = 0
        fill(req, zeroLead: &zeroLead)
        if baseEOF {
            sentFinal = true                                   // 曲の終わり: 足りない分は無音で埋めて、これを最後の入力にする
            process(s, req, final: true)
        } else {
            process(s, req, final: false)
        }
    }

    /// inL / inR の先頭から n フレームを埋める。先頭の zeroLead フレームは無音、残りは base から読む。
    /// base が終わったら足りない分を無音で埋めて baseEOF にする
    private func fill(_ n: Int, zeroLead: inout Int) {
        var off = 0
        if zeroLead > 0 {
            let z = min(zeroLead, n)
            memset(inL, 0, z * MemoryLayout<Float>.size)
            memset(inR, 0, z * MemoryLayout<Float>.size)
            zeroLead -= z
            off = z
        }
        while off < n && !baseEOF {
            let got = base.read(into: inL + off, inR + off, frames: n - off)
            if got <= 0 {
                baseEOF = true
                break
            }
            off += got
        }
        if off < n {
            memset(inL + off, 0, (n - off) * MemoryLayout<Float>.size)
            memset(inR + off, 0, (n - off) * MemoryLayout<Float>.size)
        }
    }

    private func process(_ s: OpaquePointer, _ n: Int, final: Bool) {
        inPtrs[0] = UnsafePointer(inL)
        inPtrs[1] = UnsafePointer(inR)
        rubberband_process(s, inPtrs, UInt32(n), final ? 1 : 0)
    }
}
#endif
