import Foundation
import AVFoundation
import QuartzCore

/// ノーツ音(キー音)。
/// 高い鈴のような音(6.6kHz)を、ごく短く(20ms)潰して「チッ」と鳴らす。
/// 音声ファイルは使わず、起動時にコードで合成する。
///
/// - playNow()      : すぐ鳴らす (テストプレイの打鍵・SETTINGの試聴)
/// - play(atTime:)  : CACurrentMediaTime() と同じ時間軸の時刻に鳴らす (エディタ再生中の先行予約)
/// - cancelScheduled(): 予約済みの音を全部捨てる (ポーズ・シーク時)
///
/// すべてメインスレッドから呼ぶこと。
final class KeySound {
    static let shared = KeySound()

    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var cursor = 0
    private var buffer: AVAudioPCMBuffer?
    private var configured = false
    private var pendingUntil: [Double] = []   // ノードごとの「先行予約した音が鳴り終わる時刻」(CACurrentMediaTime と同じ時間軸)
    private static let bufferDur = 0.02       // キー音1発の長さ (秒)

    /// 0...1 (SETTING の「ノーツサウンド」)
    var volume: Float = 0.8 {
        didSet {
            if configured { engine.mainMixerNode.outputVolume = min(max(volume, 0), 1) }
        }
    }

    private static let voices = 8      // 同時に鳴らせる数 (ラウンドロビン)

    private init() {}

    // MARK: - 準備

    /// エンジンを起動しておく (最初の1発が遅れないように、エディタを開いた時・再生前に呼ぶ)
    func prepare() {
        _ = ensureRunning()
    }

    private func configureIfNeeded() {
        if configured { return }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buf = KeySound.makeBuffer(format: fmt) else { return }
        buffer = buf
        for _ in 0..<KeySound.voices {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: fmt)
            nodes.append(n)
        }
        pendingUntil = Array(repeating: 0, count: nodes.count)
        engine.mainMixerNode.outputVolume = min(max(volume, 0), 1)
        configured = true
    }

    /// エンジンが止まっていたら(割り込み・イヤホン抜き差しなど)起こし直して、ノードも再生状態にする
    private func ensureRunning() -> Bool {
        configureIfNeeded()
        guard configured else { return false }
        if !engine.isRunning {
            AudioSessionSetup.activate()
            engine.prepare()
            do {
                try engine.start()
            } catch {
                return false
            }
        }
        for n in nodes where !n.isPlaying {
            n.play()
        }
        return true
    }

    // MARK: - 鳴らす

    func playNow() {
        guard volume > 0.001, ensureRunning(), let buf = buffer else { return }
        let n = nodes[cursor]
        cursor = (cursor + 1) % nodes.count
        n.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// time: CACurrentMediaTime() と同じ時間軸(秒)。すでに過ぎていたらすぐ鳴らす
    func play(atTime time: Double) {
        guard volume > 0.001, ensureRunning(), let buf = buffer else { return }
        let idx = cursor
        let n = nodes[idx]
        cursor = (cursor + 1) % nodes.count
        if time > CACurrentMediaTime() + 0.002 {
            let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: time))
            n.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
            pendingUntil[idx] = max(pendingUntil[idx], time + KeySound.bufferDur + 0.01)
        } else {
            n.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        }
    }

    /// 予約済み(まだ鳴っていない)の音を捨てる。
    /// AVAudioPlayerNode.stop() は1回ごとにオーディオスレッドの完了待ちで数十ms止まることがあるため、
    /// 「まだ鳴っていない予約を持つノード」だけを止める (以前は8ノード全部を stop + play していた)。
    /// 止めたノードを再生状態に戻すのは次の ensureRunning() (= 次に鳴らす時 / prepare()) に任せる。
    func cancelScheduled() {
        guard configured else { return }
        let now = CACurrentMediaTime()
        let running = engine.isRunning
        for i in nodes.indices where pendingUntil[i] > now {
            if running { nodes[i].stop() }
            pendingUntil[i] = 0
        }
    }

    // MARK: - 音の合成

    /// 鈴らしい非整数倍の部分音を3つ重ね、立ち上がりに短いノイズを足し、tanhで軽く潰す
    private static func makeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let dur = KeySound.bufferDur         // 全長 (秒)
        let count = Int(sr * dur)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(count)

        let base = 6600.0                    // 鈴の高さ (Hz)
        let drive = 100.0                    // 潰し具合 (大きいほど「ギュッ」と詰まる)
        // (周波数比, 振幅, 減衰の時定数[秒])
        let partials: [(Double, Double, Double)] = [
            (1.00, 1.00, 0.012),
            (2.76, 0.50, 0.008),
            (5.40, 0.22, 0.005)
        ]
        let norm = tanh(drive)
        var seed: UInt32 = 12345             // ノイズは毎回同じ並びにする
        for i in 0..<count {
            let t = Double(i) / sr
            var s = 0.0
            for p in partials {
                s += p.1 * sin(2.0 * Double.pi * base * p.0 * t) * exp(-t / p.2)
            }
            seed = seed &* 1664525 &+ 1013904223
            let noise = Double(seed) / 4294967295.0 * 2.0 - 1.0
            s += 0.30 * noise * exp(-t / 0.0012)
            s *= min(1.0, t / 0.0004)        // 0.4msの立ち上がり (プチ音防止)
            let tail = dur - t
            if tail < 0.008 { s *= tail / 0.008 }   // 最後の8msでフェードアウト
            ch[i] = Float(tanh(drive * s) / norm * 0.9)
        }
        return buf
    }
}
