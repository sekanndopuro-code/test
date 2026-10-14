import Foundation
import AVFoundation

/// オーディオセッションの起こし方を1か所にまとめたもの。
/// 出力バッファを 5ms に絞る設定も、ここで必ず一緒に行う (どの経路が先にセッションを起こしても同じ状態になる)。
/// 既定のままだと出力バッファが 20ms 前後あり、キー音・曲の出だしがその分だけ遅れる。
enum AudioSessionSetup {
    static let ioBufferSec = 0.005
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback)
        try? s.setPreferredIOBufferDuration(ioBufferSec)
        try? s.setActive(true)
    }
}

// MARK: - 曲を 1 回だけ PCM に展開して、全員で共有する (SongPCM)
//
// 以前は、曲を開くたびに「AVAudioPlayer で開く → 開けなければ WKWebView で WAV に変換」を行い、
// そのうえ再生用の GameAudio が自前の ogg デコーダーでもう一度全部展開し、テストプレイを始めるたびに
// ファイルを書き直してまた展開していた。
// 今は、曲を開くときに 1 回だけ Float の左右 PCM へ展開して (SongPCM)、エディタの再生・テストプレイ・曲の長さの計算が
// すべてこの同じ PCM を読む。展開し直す処理も、ファイルの書き直しも無い。
//
//  ・ipa (project.yml でビルドした版): ogg は stb_vorbis (StbVorbisBridge.c) で展開する。(PC での測定: 185 秒の曲で約 0.3 秒。iPad での実測は SETTING の「音源読込」の行に出る)
//  ・Swift Playgrounds (Package.swift) の版: C は入らないので、従来の自前 ogg デコーダー (TestPlay.swift の OggPCMSource) で展開する。
//    最適化なしのビルドなので、曲を開くときに数十秒待たされる (ipa では起きない)
//  ・ogg 以外 (mp3 / wav / m4a など) は、どちらの版でも AVAudioFile で展開する
//
// 展開した PCM は読むだけで書き換えない。そのため、複数のスレッド・複数の GameAudio から同時に読んでよい。

final class SongPCM: @unchecked Sendable {
    /// 展開できる長さの上限 (フレーム数)。48kHz ステレオで 20 分 = 約 460MB。これを超える曲は読み込まない
    static let maxFrames = 48_000 * 60 * 20

    let sampleRate: Double
    let frames: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>      // モノラルの曲では left と同じ場所を指す (メモリを倍にしない)
    let info: String                            // どう読み込んだか (SETTING の音源表示用)
    private let rightIsLeft: Bool

    var duration: Double { Double(frames) / sampleRate }

    /// malloc で確保した左右の波形の持ち主になる (deinit で free する)。right が nil ならモノラル
    init(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?,
         frames: Int, sampleRate: Double, info: String) {
        self.left = left
        self.right = right ?? left
        self.rightIsLeft = (right == nil)
        self.frames = frames
        self.sampleRate = sampleRate
        self.info = info
    }

    deinit {
        free(left)
        if !rightIsLeft { free(right) }
    }

    // MARK: 展開

    /// 音源ファイルの中身を、最初から最後まで PCM に展開する。重いので、メインスレッドでは呼ばない
    /// (RootView は Task.detached から呼ぶ)。
    static func decode(data: Data, fileName: String) throws -> SongPCM {
        let t0 = ProcessInfo.processInfo.systemUptime
        let isOgg = data.count >= 4 && data.starts(with: [0x4F, 0x67, 0x67, 0x53])      // "OggS"
        var firstError: Error? = nil

        #if HAVE_STB_VORBIS
        if isOgg {
            do {
                let s = try decodeWithStbVorbis(data, t0: t0)
                return s
            } catch {
                firstError = error          // stb_vorbis が読めない ogg (Opus など) は、下の方法も試す
            }
        }
        #endif

        do {
            return try decodeWithFileSources(data, fileName: fileName, isOgg: isOgg, t0: t0)
        } catch {
            throw firstError ?? error
        }
    }

    #if HAVE_STB_VORBIS
    private static func decodeWithStbVorbis(_ data: Data, t0: Double) throws -> SongPCM {
        guard data.count > 0, data.count < Int(Int32.max) else {
            throw AudioLoadError(text: "oggのサイズが不正です")
        }
        var l: UnsafeMutablePointer<Float>? = nil
        var r: UnsafeMutablePointer<Float>? = nil
        var frames: Int32 = 0
        var rate: Int32 = 0
        var channels: Int32 = 0
        let length = Int32(data.count)
        let code: Int32 = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return msd_vorbis_decode(p, length, &l, &r, &frames, &rate, &channels, Int32(SongPCM.maxFrames))
        }
        guard code == 0, let left = l, frames > 0, rate > 0 else {
            if let l = l { free(l) }
            if let r = r { free(r) }
            switch code {
            case -2: throw AudioLoadError(text: "曲が長すぎます (20分まで)")
            case -3: throw AudioLoadError(text: "曲を展開するメモリが足りません")
            default: throw AudioLoadError(text: "stb_vorbis で読めませんでした (エラー \(code))")
            }
        }
        let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        let info = String(format: "stb_vorbis で展開 (%d Hz・%dch・%.0f ms)", rate, channels, ms)
        return SongPCM(left: left, right: r, frames: Int(frames), sampleRate: Double(rate), info: info)
    }
    #endif

    /// 従来の読み方 (ファイルを経由する): ogg は自前の Swift デコーダー、それ以外は AVAudioFile。
    /// ipa では ogg 以外の曲か、stb_vorbis が読めなかった曲のときだけ通る
    private static func decodeWithFileSources(_ data: Data, fileName: String, isOgg: Bool, t0: Double) throws -> SongPCM {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("songdecode", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext0 = (fileName as NSString).pathExtension.lowercased()
        let ext = ext0.isEmpty ? (isOgg ? "ogg" : "dat") : ext0
        let url = dir.appendingPathComponent("source.\(ext)")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        var firstError: Error? = nil
        if isOgg {
            do {
                let src = try OggPCMSource(url: url)
                return try drain(src, label: "自前のoggデコーダー", t0: t0)
            } catch {
                firstError = error
            }
        }
        do {
            let src = try FilePCMSource(url: url)
            return try drain(src, label: "AVAudioFile", t0: t0)
        } catch {
            throw firstError ?? error
        }
    }

    /// PCMSource を最後まで読んで、1 つの SongPCM にする (長さがわからないので、足りなくなったら増やしながら)
    private static func drain(_ src: PCMSource, label: String, t0: Double) throws -> SongPCM {
        let sr = src.sampleRate
        guard sr > 0 else { throw AudioLoadError(text: "音源のサンプルレートが不正です") }
        let chunk = 16384
        var cap = max(Int(sr) * 60, chunk * 4)
        let unit = MemoryLayout<Float>.size
        guard var lp = malloc(cap * unit)?.assumingMemoryBound(to: Float.self) else {
            throw AudioLoadError(text: "曲を展開するメモリが足りません")
        }
        guard var rp = malloc(cap * unit)?.assumingMemoryBound(to: Float.self) else {
            free(lp)
            throw AudioLoadError(text: "曲を展開するメモリが足りません")
        }
        src.seek(to: 0)
        var n = 0
        while true {
            if cap - n < chunk {
                let ncap = cap + cap / 2 + chunk
                guard let nl = realloc(lp, ncap * unit)?.assumingMemoryBound(to: Float.self) else {
                    free(lp); free(rp)
                    throw AudioLoadError(text: "曲を展開するメモリが足りません")
                }
                lp = nl
                guard let nr = realloc(rp, ncap * unit)?.assumingMemoryBound(to: Float.self) else {
                    free(lp); free(rp)
                    throw AudioLoadError(text: "曲を展開するメモリが足りません")
                }
                rp = nr
                cap = ncap
            }
            let got = src.read(into: lp + n, rp + n, frames: chunk)
            if got <= 0 { break }
            n += got
            if n > maxFrames {
                free(lp); free(rp)
                throw AudioLoadError(text: "曲が長すぎます (20分まで)")
            }
        }
        if n <= 0 {
            free(lp); free(rp)
            throw AudioLoadError(text: "音源にデータがありません")
        }
        let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        let info = String(format: "%@で展開 (%ld Hz・%.0f ms)", label, Int(sr), ms)
        return SongPCM(left: lp, right: rp, frames: n, sampleRate: sr, info: info)
    }
}

/// SongPCM を PCMSource として読むだけの薄い入れ物 (メモリのコピーだけ。デコードもシークの探し直しも無い)。
/// GameAudio ごとに 1 つ持つ (位置 pos は持ち主ごと。PCM 本体は共有)。decodeQueue 上でだけ触る。
final class SongPCMSource: PCMSource {
    let song: SongPCM
    private var pos = 0

    init(_ song: SongPCM) { self.song = song }

    var sampleRate: Double { song.sampleRate }

    func seek(to frame: Int64) {
        pos = Int(max(0, min(frame, Int64(song.frames))))
    }

    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let n = min(frames, song.frames - pos)
        if n <= 0 { return 0 }
        let bytes = n * MemoryLayout<Float>.size
        memcpy(l, song.left + pos, bytes)
        memcpy(r, song.right + pos, bytes)
        pos += n
        return n
    }
}
