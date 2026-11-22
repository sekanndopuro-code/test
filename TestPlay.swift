// テストプレイ機能 (本家の Slide モードの仕様・見た目に合わせた版)
//
// このファイルに残っているもの:
//   ・音声 (自前の Ogg デコーダー + AVAudioEngine + 時計: GameAudio)
//   ・ゲーム設定 (GameSession: ポーズ画面で変える値)
//   ・SwiftUI の橋渡し (GameRepresentable / PauseOverlay / TestPlayLaunch / TestPlayScreen)
// 判定・スコア・時間計算は SlideCore.swift、画面の幾何は SlideLayout.swift、画像は SlideSkin.swift、
// プレイ画面そのもの (GameView) は SlideGameView.swift、エディタの譜面からの変換は MalodyChartBuilder.swift。

import SwiftUI
import UIKit
import AVFoundation

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
    /// スクロール速度 n (整数。速度係数 = exp(n × 0.05)。本家の「速度」設定の整数。既定 10 は本家の画面収録の実測から)
    @Published var speedN: Int {
        didSet { UserDefaults.standard.set(speedN, forKey: "slide.speedN") }
    }
    /// 判定レベル 0...4 (窓のずれ +20/+10/0/−8/−16 ms とスコア倍率 78/85/100/110/120 %。既定 2 = 標準)
    @Published var judgeLevel: Int {
        didSet { UserDefaults.standard.set(judgeLevel, forKey: "slide.judgeLevel") }
    }
    /// ヒット音 (頭を叩いたとき。エディタのノーツサウンドと同じ音)。既定はオン
    @Published var hitSound: Bool {
        didSet { UserDefaults.standard.set(hitSound, forKey: "slide.hitSound") }
    }
    @Published var offsetMs: Double {               // ±300ms。+で音に対してノーツが遅く、−で早くなる
        didSet { UserDefaults.standard.set(offsetMs, forKey: "slide.offset") }
    }
    weak var view: GameView?
    var quit: () -> Void = {}

    static let speedRange = 1...30

    init() {
        let ud = UserDefaults.standard
        let n = ud.object(forKey: "slide.speedN") == nil ? 10 : ud.integer(forKey: "slide.speedN")
        speedN = min(max(n, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        let k = ud.object(forKey: "slide.judgeLevel") == nil ? 2 : ud.integer(forKey: "slide.judgeLevel")
        judgeLevel = min(max(k, 0), 4)
        hitSound = ud.object(forKey: "slide.hitSound") == nil ? true : ud.bool(forKey: "slide.hitSound")
        offsetMs = min(max(ud.double(forKey: "slide.offset"), -300), 300)
    }

    func pause() { view?.pause() }
    func resume() { view?.resume() }
    func retry() { view?.retry() }
    func quitGame() {
        paused = false
        quit()
    }
}

// MARK: - SwiftUI(メニューと画面の橋渡し)

struct GameRepresentable: UIViewRepresentable {
    let chart: MalodyChart
    let audio: GameAudio?
    let session: GameSession
    var startAt: Double = 0
    var background: UIImage? = nil
    var bgDim: Double = 0.7

    func makeUIView(context: Context) -> GameView {
        GameView(chart: chart, audio: audio, session: session, startAt: startAt,
                 background: background, bgDim: bgDim)
    }
    func updateUIView(_ uiView: GameView, context: Context) {}
}

struct PauseOverlay: View {
    @ObservedObject var session: GameSession

    private var offsetBinding: Binding<Double> {
        Binding(get: { session.offsetMs },
                set: { session.offsetMs = min(max($0.rounded(), -300), 300) })
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { Double(session.speedN) },
                set: { session.speedN = min(max(Int($0.rounded()), GameSession.speedRange.lowerBound),
                                            GameSession.speedRange.upperBound) })
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

                    Toggle("ヒット音", isOn: $session.hitSound)
                        .toggleStyle(CheckboxToggleStyle())

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("スクロール速度")
                            Spacer()
                            Text(String(format: "%ld  (×%.2f)", session.speedN, exp(Double(session.speedN) * 0.05)))
                                .monospacedDigit()
                        }
                        Slider(value: speedBinding,
                               in: Double(GameSession.speedRange.lowerBound)...Double(GameSession.speedRange.upperBound),
                               step: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("判定レベル")
                        Picker("判定レベル", selection: $session.judgeLevel) {
                            ForEach(0..<5, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text("0 = ゆるい (スコア ×0.78) 〜 2 = 標準 〜 4 = きびしい (スコア ×1.20)。コンティニュー / リトライから反映")
                            .font(.caption)
                            .foregroundColor(.gray)
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

/// ラベル + チェックボックス (iPadOS ではスイッチが標準なので、四角いチェックにする)
private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 24))
                    .foregroundColor(configuration.isOn ? .accentColor : .gray)
                configuration.label
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - エディタ連携 (ここから下がエディタ用の追加分)

/// テストプレイ開始時にエディタが作る「お膳立て」
struct TestPlayLaunch: Identifiable {
    let id = UUID()
    let chart: MalodyChart
    let audio: GameAudio?
    let startSec: Double          // 譜面時間(秒)。エディタの現在位置
    var background: UIImage? = nil    // エディタの背景画像 (プレイ画面にも敷く)
    var bgDim: Double = 0.7           // その上に重ねる黒の濃さ (エディタの SETTING と同じ値)
    var touchEffect: Bool = false     // エディタの「タッチエフェクト」のチェック (プレイ中に指の位置へ出す)
}

/// フルスクリーンで出すテストプレイ画面 (左上のポーズボタン → 終了 でエディタに戻る)
struct TestPlayScreen: View {
    let launch: TestPlayLaunch
    let onClose: () -> Void
    @StateObject private var session = GameSession()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            GameRepresentable(chart: launch.chart, audio: launch.audio, session: session, startAt: launch.startSec,
                              background: launch.background, bgDim: launch.bgDim)
                .ignoresSafeArea()
            if session.paused {
                PauseOverlay(session: session)
            }
        }
        // fullScreenCover が出ている間、エディタ側のタッチエフェクトは外れる (EditorView の .background を参照)。
        // プレイ中の指の位置の表示は、エディタのチェックボックスと同じ ON/OFF に従う
        .background(TouchEffectInstaller(enabled: launch.touchEffect))
        .statusBarHidden(true)      // fullScreenCover は別の画面扱いなので、ここにも付ける
        .persistentSystemOverlays(.hidden)      // ホームバーも同じ (EditorView と同じ設定。RootView を参照)
        .defersSystemGestures(on: .bottom)
        .onAppear {
            session.paused = false
            session.quit = onClose
        }
    }
}
