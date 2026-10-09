import Foundation

// MARK: - 時間伸縮 (0.5倍未満の再生用)
//
// 以前は AVAudioUnitTimePitch を使っていたが、その内部遅延は速度が遅いほど大きく変わり、
// AVAudioUnit が報告する latency では正しく補正できなかった (0.5倍未満で曲と譜面が大きくズレる原因)。
// そこで、伸ばした音そのものを自前で作る。作り方が決まっているので、ズレが「計算で」決まる:
//
//   ・出力の n フレーム目は、元の曲の (開始位置 + n × 速度) フレーム付近の音になる (遅延ゼロ、フレーム単位で正確)
//   ・出力はふつうの速度 1.0 の PCM なので、GameAudio は player → mixer の直結で鳴らせる
//     (= 速度 1.0 と同じ時計 / 同じ補正の仕組みがそのまま使える)
//
// 方式はフェーズボコーダー (位相をそろえる処理つき)。音程は変わらない。
// 伸ばした音は、ドラムなどの立ち上がりが少しにじむ (にじむ幅は 0.25倍で前後 約15ms、0.1倍で前後 約50〜70ms。
// いずれも「伸ばした後の時間」での幅) が、音のピークは曲と同じ位置に来る。
//
// ■ 軽さについて (音が途切れる問題の対策)
// 伸ばした音は、再生に間に合う速さで「リアルタイムに」作り続けなければならない。
// 以前の実装は計算が重く (Array の添字アクセス + Double の FFT を 1 ホップに 4 回)、
// Swift Playgrounds のように最適化なしでビルドされる環境では再生速度ぎりぎり(実測で約2倍)しか出ず、
// 画面の描画などで少し忙しくなっただけで作成が間に合わず、音が途切れていた。
// そこで次のようにして、同じ音を 5〜10 倍速く作れるようにしている:
//   ・FFT は Float + ポインタで直接書く (最適化なしでも遅くならない)
//   ・左右の音を「実部=左、虚部=右」として 1 本の複素 FFT にまとめる → FFT は 1 ホップに 2 回 (以前は 4 回)
//   ・作業用の領域は最初に 1 回だけ確保して使い回す (Array の追加・削除をしない)
// 出てくる音は以前の実装と同じ (Float の誤差の範囲で一致)。

/// 複素数列 (実部と虚部が別の領域) の FFT (基数2)。n は 2 の累乗。
/// Float + UnsafeMutablePointer で書いてある。Array の添字アクセスは、最適化なしのビルドだと非常に遅いため
final class FloatFFT {
    let n: Int
    private let cosT: UnsafeMutablePointer<Float>        // cos(2πi/n)        (i = 0 ..< n/2)
    private let sinFwd: UnsafeMutablePointer<Float>      // 順変換用 sin(-2πi/n)
    private let sinInv: UnsafeMutablePointer<Float>      // 逆変換用 sin(+2πi/n)
    private let rev: UnsafeMutablePointer<Int>           // ビット反転の表

    init(n: Int) {
        self.n = n
        var bits = 0
        while (1 << bits) < n { bits += 1 }
        let half = max(1, n / 2)
        cosT = UnsafeMutablePointer<Float>.allocate(capacity: half)
        sinFwd = UnsafeMutablePointer<Float>.allocate(capacity: half)
        sinInv = UnsafeMutablePointer<Float>.allocate(capacity: half)
        rev = UnsafeMutablePointer<Int>.allocate(capacity: n)
        for i in 0..<n {
            var x = i
            var y = 0
            for _ in 0..<bits {
                y = (y << 1) | (x & 1)
                x >>= 1
            }
            rev[i] = y
        }
        for i in 0..<half {
            let a = 2.0 * Double.pi * Double(i) / Double(n)
            cosT[i] = Float(cos(a))
            sinFwd[i] = Float(-sin(a))
            sinInv[i] = Float(sin(a))
        }
    }

    deinit {
        cosT.deallocate()
        sinFwd.deallocate()
        sinInv.deallocate()
        rev.deallocate()
    }

    /// その場で変換する。inverse = true は逆変換 (1/n はかけない)
    func transform(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, inverse: Bool) {
        let n = self.n
        // ビット反転の並べ替え
        var i = 0
        while i < n {
            let j = rev[i]
            if j > i {
                let tr = re[i]
                re[i] = re[j]
                re[j] = tr
                let ti = im[i]
                im[i] = im[j]
                im[j] = ti
            }
            i += 1
        }
        let sinT = inverse ? sinInv : sinFwd
        // 長さ 2 の段 (回転なし)
        i = 0
        while i < n {
            let b = i + 1
            let tr = re[b]
            let ti = im[b]
            re[b] = re[i] - tr
            im[b] = im[i] - ti
            re[i] += tr
            im[i] += ti
            i += 2
        }
        // 長さ 4 以上の段
        var len = 4
        while len <= n {
            let half = len >> 1
            let step = n / len
            var start = 0
            while start < n {
                var k = 0
                var a = start
                let end = start + half
                while a < end {
                    let b = a + half
                    let wr = cosT[k]
                    let wi = sinT[k]
                    let br = re[b]
                    let bi = im[b]
                    let tr = br * wr - bi * wi
                    let ti = br * wi + bi * wr
                    let ar = re[a]
                    let ai = im[a]
                    re[b] = ar - tr
                    im[b] = ai - ti
                    re[a] = ar + tr
                    im[a] = ai + ti
                    k += step
                    a += 1
                }
                start += len
            }
            len <<= 1
        }
    }
}

/// 元の PCMSource を、遅い速度 (rate < 1) に伸ばして返す PCMSource。
/// seek(to: f) の f は「元の曲のフレーム」。出力の先頭 (0フレーム目) が、その位置の音になる。
/// read は伸ばした後の PCM (サンプリング周波数は元と同じ) を返す。decodeQueue 上でだけ使うこと。
final class StretchedPCMSource: PCMSource {
    let sampleRate: Double
    let rate: Double

    private let base: PCMSource
    private let n: Int                 // FFT の大きさ (窓の長さ)
    private let hs: Int                // 出力側のフレーム間隔 (n/4)
    private let half: Int
    private let bins: Int
    private let fft: FloatFFT

    // 窓
    private let win: UnsafeMutablePointer<Float>         // 解析用の窓 w[i]
    private let winSyn: UnsafeMutablePointer<Float>      // 合成用の窓 w[i] / n (逆FFTの 1/n 込み)
    private let winSq: UnsafeMutablePointer<Float>       // w[i]^2 (重なりの正規化用)

    // 入力 (元の曲) の先読み領域。inStart は inL[0] の元の曲でのフレーム位置 (負 = 曲頭より前 = 無音)
    private let inCap: Int
    private let inL: UnsafeMutablePointer<Float>
    private let inR: UnsafeMutablePointer<Float>
    private var inCount = 0
    private var inStart = 0
    private var eofAt = Int.max        // 元の曲の終わりのフレーム位置 (Int.max = まだ終わりが見えていない)

    // 出力の重ね合わせ領域。accBase は accL[0] の出力フレーム位置
    private let maxRead: Int           // 1 回の read で返す最大フレーム数
    private let accCap: Int
    private let accL: UnsafeMutablePointer<Float>
    private let accR: UnsafeMutablePointer<Float>
    private let accW: UnsafeMutablePointer<Float>
    private var accCount = 0
    private var accBase = 0
    private var finalized = 0          // ここより前の出力は確定済み (これ以上足されない)
    private var ended = false

    private var want = 0               // seek で指定された元の曲の位置
    private var frameIndex = 0
    private var prevCenter = 0

    // 位相の計算用 (bins 個)
    private let ph: UnsafeMutablePointer<Double>
    private let prevPhase: UnsafeMutablePointer<Double>
    private let synPhase: UnsafeMutablePointer<Double>
    private let newSyn: UnsafeMutablePointer<Double>
    private let mag: UnsafeMutablePointer<Float>
    private let peaks: UnsafeMutablePointer<Int>

    // FFT の作業領域 (n 個)。左を実部、右を虚部に入れて 1 本の複素 FFT にする
    private let zRe: UnsafeMutablePointer<Float>
    private let zIm: UnsafeMutablePointer<Float>
    private let rotRe: UnsafeMutablePointer<Float>      // 位相の回転 (下半分 0...n/2 が本体、上半分はその共役)
    private let rotIm: UnsafeMutablePointer<Float>

    init(base: PCMSource, rate: Double, fftSize: Int = 1024) {
        self.base = base
        self.rate = min(max(rate, 0.05), 1.0)
        sampleRate = base.sampleRate
        n = fftSize
        hs = fftSize / 4
        half = fftSize / 2
        bins = fftSize / 2 + 1
        fft = FloatFFT(n: fftSize)

        win = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        winSyn = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        winSq = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        for i in 0..<fftSize {
            let w = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(fftSize))
            win[i] = Float(w)
            winSyn[i] = Float(w / Double(fftSize))
            winSq[i] = Float(w * w)
        }

        inCap = 4096 + 4 * fftSize
        inL = UnsafeMutablePointer<Float>.allocate(capacity: inCap)
        inR = UnsafeMutablePointer<Float>.allocate(capacity: inCap)
        inL.initialize(repeating: 0, count: inCap)
        inR.initialize(repeating: 0, count: inCap)

        maxRead = 16384
        accCap = 16384 + 2 * fftSize + 64
        accL = UnsafeMutablePointer<Float>.allocate(capacity: accCap)
        accR = UnsafeMutablePointer<Float>.allocate(capacity: accCap)
        accW = UnsafeMutablePointer<Float>.allocate(capacity: accCap)
        accL.initialize(repeating: 0, count: accCap)
        accR.initialize(repeating: 0, count: accCap)
        accW.initialize(repeating: 0, count: accCap)

        let b = fftSize / 2 + 1
        ph = UnsafeMutablePointer<Double>.allocate(capacity: b)
        prevPhase = UnsafeMutablePointer<Double>.allocate(capacity: b)
        synPhase = UnsafeMutablePointer<Double>.allocate(capacity: b)
        newSyn = UnsafeMutablePointer<Double>.allocate(capacity: b)
        mag = UnsafeMutablePointer<Float>.allocate(capacity: b)
        peaks = UnsafeMutablePointer<Int>.allocate(capacity: b)
        ph.initialize(repeating: 0, count: b)
        prevPhase.initialize(repeating: 0, count: b)
        synPhase.initialize(repeating: 0, count: b)
        newSyn.initialize(repeating: 0, count: b)
        mag.initialize(repeating: 0, count: b)
        peaks.initialize(repeating: 0, count: b)

        zRe = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        zIm = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        rotRe = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        rotIm = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        zRe.initialize(repeating: 0, count: fftSize)
        zIm.initialize(repeating: 0, count: fftSize)
        rotRe.initialize(repeating: 1, count: fftSize)
        rotIm.initialize(repeating: 0, count: fftSize)

        seek(to: 0)
    }

    deinit {
        win.deallocate()
        winSyn.deallocate()
        winSq.deallocate()
        inL.deallocate()
        inR.deallocate()
        accL.deallocate()
        accR.deallocate()
        accW.deallocate()
        ph.deallocate()
        prevPhase.deallocate()
        synPhase.deallocate()
        newSyn.deallocate()
        mag.deallocate()
        peaks.deallocate()
        zRe.deallocate()
        zIm.deallocate()
        rotRe.deallocate()
        rotIm.deallocate()
    }

    func seek(to frame: Int64) {
        want = Int(max(0, frame))
        frameIndex = 0
        prevCenter = want
        eofAt = Int.max
        let s0 = want - half
        if s0 < 0 {
            base.seek(to: 0)
            inCount = -s0                                   // 曲頭より前は無音
            memset(inL, 0, inCount * MemoryLayout<Float>.size)
            memset(inR, 0, inCount * MemoryLayout<Float>.size)
        } else {
            base.seek(to: Int64(s0))
            inCount = 0
        }
        inStart = s0
        accCount = 0
        accBase = 0
        finalized = 0
        ended = false
    }

    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let req = min(frames, maxRead)
        if req <= 0 { return 0 }
        while !ended && finalized - accBase < req {
            processFrame()
        }
        let avail = finalized - accBase
        let take = min(req, min(max(0, avail), accCount))
        if take <= 0 { return 0 }
        var i = 0
        while i < take {
            let w = accW[i] > 0.001 ? accW[i] : 0.001
            let inv = 1.0 / w
            l[i] = accL[i] * inv
            r[i] = accR[i] * inv
            i += 1
        }
        let rest = accCount - take
        if rest > 0 {
            let bytes = rest * MemoryLayout<Float>.size
            memmove(accL, accL + take, bytes)
            memmove(accR, accR + take, bytes)
            memmove(accW, accW + take, bytes)
        }
        accCount = rest
        accBase += take
        return take
    }

    /// 入力領域を、元の曲のフレーム s から s + n まで読める状態にする
    /// (曲の終わりより先は無音で埋める)
    private func ensureInput(from s: Int) {
        let drop = s - inStart
        if drop > 0 {
            let d = min(drop, inCount)
            if d > 0 {
                let rest = inCount - d
                if rest > 0 {
                    let bytes = rest * MemoryLayout<Float>.size
                    memmove(inL, inL + d, bytes)
                    memmove(inR, inR + d, bytes)
                }
                inCount = rest
                inStart += d
            }
        }
        let need = s + n
        while inStart + inCount < need && eofAt == Int.max {
            if inCap - inCount < 4096 { break }               // 領域が足りない (通常は起こらない)
            let got = base.read(into: inL + inCount, inR + inCount, frames: 4096)
            if got <= 0 {
                eofAt = inStart + inCount
                break
            }
            inCount += got
        }
        if eofAt != Int.max {
            let missing = need - (inStart + inCount)
            if missing > 0 {
                let m = min(missing, inCap - inCount)
                if m > 0 {
                    memset(inL + inCount, 0, m * MemoryLayout<Float>.size)
                    memset(inR + inCount, 0, m * MemoryLayout<Float>.size)
                    inCount += m
                }
            }
        }
    }

    /// 1フレーム分 (n サンプルの窓) を解析 → 位相をそろえて合成 → 出力に重ねる
    private func processFrame() {
        let k = frameIndex
        let center = want + Int((Double(k) * rate * Double(hs)).rounded())
        let s = center - half
        ensureInput(from: s)
        if eofAt != Int.max && center >= eofAt {
            // 曲の終わりを過ぎた: 最後の分まで確定させて終わり
            ended = true
            finalized = max(finalized, k * hs - half + hs)
            return
        }

        // --- 解析 (窓をかけて FFT) ---
        // 左を実部、右を虚部に入れて、1 本の複素 FFT で両方まとめて変換する
        let off = s - inStart
        if off >= 0 && off + n <= inCount {
            let pl = inL + off
            let pr = inR + off
            var i = 0
            while i < n {
                let w = win[i]
                zRe[i] = pl[i] * w
                zIm[i] = pr[i] * w
                i += 1
            }
        } else {
            // 起こらないはずの場合の保険 (読めない所は無音として扱う)
            var i = 0
            while i < n {
                let j = off + i
                if j >= 0 && j < inCount {
                    zRe[i] = inL[j] * win[i]
                    zIm[i] = inR[j] * win[i]
                } else {
                    zRe[i] = 0
                    zIm[i] = 0
                }
                i += 1
            }
        }
        fft.transform(zRe, zIm, inverse: false)

        // 位相は左右を足した音 (モノラル) から決める。同じ回転を左右にかけるので、ステレオの定位は変わらない。
        // 実数の左 L と右 R を L + iR にまとめて変換したので、Z[b] と Z[n-b] から左右それぞれのスペクトルを取り出せる:
        //   左 = (Z[b] + conj(Z[n-b])) / 2,  右 = (Z[b] - conj(Z[n-b])) / (2i),  モノラル = (左 + 右) / 2
        var b = 0
        while b < bins {
            let j = (n - b) & (n - 1)
            let zr = zRe[b]
            let zi = zIm[b]
            let yr = zRe[j]
            let yi = zIm[j]
            let mr = (zr + yr + zi + yi) * 0.25
            let mi = (zi - yi + yr - zr) * 0.25
            mag[b] = mr * mr + mi * mi
            ph[b] = atan2(Double(mi), Double(mr))
            b += 1
        }

        if k == 0 {
            b = 0
            while b < bins {
                synPhase[b] = ph[b]
                prevPhase[b] = ph[b]
                rotRe[b] = 1.0
                rotIm[b] = 0.0
                b += 1
            }
        } else {
            let dA = Double(max(1, center - prevCenter))      // 前のフレームとの、元の曲での間隔
            // 山 (ピーク) を探す。山ごとに「周波数」を推定して位相を進め、まわりの bin は山との位相差を保つ
            var peakCount = 0
            b = 0
            while b < bins {
                let m = mag[b]
                var isPeak = true
                var q = 1
                while q <= 2 {
                    if b - q >= 0 && mag[b - q] >= m { isPeak = false; break }
                    if b + q < bins && mag[b + q] > m { isPeak = false; break }
                    q += 1
                }
                if isPeak {
                    peaks[peakCount] = b
                    peakCount += 1
                }
                b += 1
            }
            if peakCount == 0 {
                peaks[0] = 0
                peakCount = 1
            }
            let twoPi = 2.0 * Double.pi
            var pk = 0
            while pk < peakCount {
                let p = peaks[pk]
                let lo = pk == 0 ? 0 : (peaks[pk - 1] + p) / 2 + 1
                let hi = pk == peakCount - 1 ? bins - 1 : (p + peaks[pk + 1]) / 2
                let omega = twoPi * Double(p) / Double(n)
                var d = ph[p] - prevPhase[p] - omega * dA
                d -= twoPi * (d / twoPi).rounded()
                let tf = omega + d / dA
                let sp = synPhase[p] + tf * Double(hs)
                let r = sp - ph[p]
                let cr = Float(cos(r))
                let sr = Float(sin(r))
                var x = lo
                while x <= hi {
                    newSyn[x] = ph[x] + r
                    rotRe[x] = cr
                    rotIm[x] = sr
                    x += 1
                }
                pk += 1
            }
            b = 0
            while b < bins {
                synPhase[b] = newSyn[b]
                prevPhase[b] = ph[b]
                b += 1
            }
        }
        prevCenter = center

        // --- 合成 (回転 → 逆FFT) ---
        // 直流 (0) とナイキスト (n/2) は実数のままにする。上半分 (n/2+1 ... n-1) には、下半分の共役の回転をかける
        rotIm[0] = 0
        rotIm[half] = 0
        b = 1
        while b < half {
            rotRe[n - b] = rotRe[b]
            rotIm[n - b] = -rotIm[b]
            b += 1
        }
        var i = 0
        while i < n {
            let a = zRe[i]
            let c = zIm[i]
            zRe[i] = a * rotRe[i] - c * rotIm[i]
            zIm[i] = a * rotIm[i] + c * rotRe[i]
            i += 1
        }
        fft.transform(zRe, zIm, inverse: true)      // 実部 = 左、虚部 = 右 (どちらも n 倍)

        // --- 出力に重ねる。出力 0 フレーム目 = 0番目のフレームの中心 ---
        let o = k * hs - half - accBase
        let need = o + n
        if need > accCount {
            let from = max(0, accCount)
            if need <= accCap {
                let bytes = (need - from) * MemoryLayout<Float>.size
                memset(accL + from, 0, bytes)
                memset(accR + from, 0, bytes)
                memset(accW + from, 0, bytes)
                accCount = need
            }
        }
        let i0 = o < 0 ? -o : 0
        if i0 < n && need <= accCap {
            i = i0
            while i < n {
                let idx = o + i
                let ws = winSyn[i]
                accL[idx] += zRe[i] * ws
                accR[idx] += zIm[i] * ws
                accW[idx] += winSq[i]
                i += 1
            }
        }
        finalized = k * hs - half + hs        // 次のフレームの先頭より前は、もう足されない
        frameIndex = k + 1
    }
}
