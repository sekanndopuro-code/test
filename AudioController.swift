import Foundation
import AVFoundation
import WebKit

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

/// 音源の読込と再生。
/// 1) AVAudioPlayer でそのまま開けるか試す (iOS/iPadOS 18.4 以降は ogg が開ける可能性あり)
/// 2) 開けなければ WKWebView(WebKit) の decodeAudioData で WAV に変換してから再生
final class AudioController {
    private(set) var player: AVAudioPlayer?
    private(set) var info: String = ""
    private var warmedSec: Double? = nil      // warm() で用意済みの再生位置
    private var pendingStart: Double = 0      // 直近の play(atTime:) で予約した開始時刻 (player.deviceCurrentTime の時間軸)

    var duration: Double { player?.duration ?? 0 }
    var hasAudio: Bool { player != nil }

    /// 曲の音量 0...1 (SETTING の「曲の音量」)。再生中でも即反映される
    var volume: Float = 1.0 {
        didSet { player?.volume = min(max(volume, 0), 1) }
    }

    @MainActor
    func load(data: Data, fileName: String) async throws {
        AudioSessionSetup.activate()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext0 = (fileName as NSString).pathExtension
        let ext = ext0.isEmpty ? "ogg" : ext0
        let src = dir.appendingPathComponent("source.\(ext)")
        try data.write(to: src)

        if let p = try? AVAudioPlayer(contentsOf: src) {
            adopt(p, how: "ネイティブ再生")
            return
        }
        let wavURL = dir.appendingPathComponent("decoded.wav")
        let decoder = WebAudioDecoder()
        try await decoder.decode(data: data, dest: wavURL)
        let p = try AVAudioPlayer(contentsOf: wavURL)
        adopt(p, how: "WebKitでデコード(モノラルWAV)")
    }

    private func adopt(_ p: AVAudioPlayer, how: String) {
        p.enableRate = true          // prepareToPlay より前に必要
        p.volume = min(max(volume, 0), 1)
        p.prepareToPlay()
        player = p
        info = how
    }

    /// 停止中に「次に再生を始める位置」を先に用意しておく (再生ボタンを押した瞬間の下ごしらえを省くため)。
    /// audioSec は start と同じ意味 (負なら曲頭から)
    func warm(audioSec: Double) {
        guard let p = player, !p.isPlaying, audioSec < p.duration else { return }
        p.currentTime = max(0, audioSec)
        p.prepareToPlay()
        warmedSec = audioSec
    }

    /// audioSec: 音源内の再生開始位置(秒)。負の場合は音源の頭出しを遅らせる。
    /// 重い下ごしらえはこの関数の前半で終わらせ、「鳴らす時刻」は最後に決める。
    /// → 呼び出し側は、この関数から戻った後の時刻を基準に画面の時計を始めること
    func start(audioSec: Double, rate: Double, lead: Double) {
        guard let p = player else { return }
        let ready = !p.isPlaying && (warmedSec.map { abs($0 - audioSec) < 0.0005 } ?? false)
        warmedSec = nil
        // 鳴っている最中のときだけ止める。止まっている(pause 済みの)プレイヤーは準備状態を保ったまま位置だけ動かす
        if !ready && p.isPlaying { p.stop() }
        p.rate = Float(rate)
        let r = max(0.25, rate)
        var delay = lead
        if audioSec >= 0 {
            if audioSec >= p.duration { return }
            if !ready {
                p.currentTime = audioSec
                p.prepareToPlay()
            }
        } else {
            if !ready {
                p.currentTime = 0
                p.prepareToPlay()
            }
            delay += (-audioSec) / r
        }
        let at = p.deviceCurrentTime + delay
        pendingStart = at
        if !p.play(atTime: at) {
            // 再生を始められなかった (他アプリの音・通知・イヤホンの抜き差し等でオーディオセッションが止まっていた)
            // → セッションを起こし直して1回だけやり直す。「押したのに鳴らない」を防ぐ
            AudioSessionSetup.activate()
            p.prepareToPlay()
            let at2 = p.deviceCurrentTime + delay
            pendingStart = at2
            _ = p.play(atTime: at2)
        }
    }

    func stop() {
        warmedSec = nil
        guard let p = player else { return }
        if p.deviceCurrentTime < pendingStart + 0.01 {
            // まだ鳴り始めていない予約があるかもしれない → 確実に取り消すため stop
            p.stop()
        } else {
            // 鳴っている最中は pause。stop() のような後片付けをしない分だけ止まるのが速く、
            // 準備状態も保たれるので、次の再生ボタンも速い
            p.pause()
        }
    }
}

enum AudioDecodeError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        }
    }
}

/// 画面に出さない WKWebView で Web Audio の decodeAudioData を使い、WAV にして返す
@MainActor
final class WebAudioDecoder: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var cont: CheckedContinuation<Void, Error>?

    func decode(data: Data, dest: URL) async throws {
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: WKWebViewConfiguration())
        wv.navigationDelegate = self
        web = wv
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.cont = c
            wv.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://localhost/"))
        }
        let result = try await wv.callAsyncJavaScript(
            Self.script,
            arguments: ["b64": data.base64EncodedString()],
            in: nil,
            contentWorld: .page
        )
        wv.navigationDelegate = nil
        web = nil
        guard let s = result as? String else {
            throw AudioDecodeError.failed("デコード結果が不正です")
        }
        if s.hasPrefix("ERR:") {
            throw AudioDecodeError.failed("この端末のWebKitではoggをデコードできませんでした (\(s))")
        }
        guard let wav = Data(base64Encoded: s) else {
            throw AudioDecodeError.failed("WAVデータの復元に失敗しました")
        }
        try wav.write(to: dest)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        cont?.resume()
        cont = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        cont?.resume(throwing: error)
        cont = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        cont?.resume(throwing: error)
        cont = nil
    }

    static let script = """
    try {
      const bin = atob(b64);
      const u8 = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
      const AC = window.AudioContext || window.webkitAudioContext;
      const ctx = new AC();
      const buf = await new Promise((res, rej) => { ctx.decodeAudioData(u8.buffer, res, rej); });
      const n = buf.length, sr = buf.sampleRate, nch = buf.numberOfChannels;
      const chs = [];
      for (let c = 0; c < nch; c++) chs.push(buf.getChannelData(c));
      const out = new ArrayBuffer(44 + n * 2);
      const dv = new DataView(out);
      const w4 = (o, s) => { for (let i = 0; i < 4; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
      w4(0, 'RIFF'); dv.setUint32(4, 36 + n * 2, true); w4(8, 'WAVE'); w4(12, 'fmt ');
      dv.setUint32(16, 16, true); dv.setUint16(20, 1, true); dv.setUint16(22, 1, true);
      dv.setUint32(24, sr, true); dv.setUint32(28, sr * 2, true);
      dv.setUint16(32, 2, true); dv.setUint16(34, 16, true);
      w4(36, 'data'); dv.setUint32(40, n * 2, true);
      for (let i = 0; i < n; i++) {
        let s = 0;
        for (let c = 0; c < nch; c++) s += chs[c][i];
        s /= nch;
        s = s < -1 ? -1 : (s > 1 ? 1 : s);
        dv.setInt16(44 + i * 2, s < 0 ? s * 32768 : s * 32767, true);
      }
      const u = new Uint8Array(out);
      const parts = [];
      const CH = 3 * 8192;
      for (let i = 0; i < u.length; i += CH) {
        parts.push(btoa(String.fromCharCode.apply(null, u.subarray(i, i + CH))));
      }
      return parts.join('');
    } catch (e) {
      return 'ERR:' + e;
    }
    """
}
