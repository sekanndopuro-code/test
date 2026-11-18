import Foundation
import AVFoundation
import QuartzCore

/// ノーツサウンドの種類 (SETTING の「ノーツサウンドの種類」)。
/// rawValue は元の音声ファイル名で、SETTING のボタンの名前と、保存 (UserDefaults) の値にそのまま使う。
/// 波形は KeySoundData にある。種類を足すときは、ここに case を足し、KeySoundData にも波形を足す。
enum NoteSoundKind: String, CaseIterable {
    case hit = "hit"
    case hit1 = "hit-1"
    case hit2 = "hit-2"
    case sampleNormal = "sample-normal"

    /// 初めて起動したとき (保存された選択がないとき) の音
    static let defaultKind: NoteSoundKind = .sampleNormal

    /// SETTING のボタンに出す名前
    var title: String { rawValue }
}

/// ノーツ音(キー音)。
/// KeySoundData.swift に埋め込んだ 4 種類の波形 (NoteSoundKind) のうち、選ばれている 1 つを鳴らす。音声ファイルは使わない
/// (Swift Playgrounds でも、.swift をコピーするだけで動くように)。
///
/// - select(_:) : 鳴らす種類を切り替える (SETTING の「ノーツサウンドの種類」)
/// - playNow() : すぐ鳴らす (テストプレイの打鍵・SETTINGの試聴)
/// - play(atTime:count:) : CACurrentMediaTime() と同じ時間軸の時刻に鳴らす (エディタ再生中の先行予約)
/// - cancelScheduled(): 予約済みの音を全部捨てる (ポーズ・シーク時)
///
/// 同時にノーツが来たとき (同時押し) は、その個数ぶん音が大きくなる。
/// 同じ波形を重ねて鳴らすのではなく、個数ごとに大きさを変えた波形を最初から作っておき (buffers)、
/// 1 つの声 (ノード) でそれを鳴らす。大きくした波形のうち、1.0 を越えそうな山はなめらかに丸めてある (softLimit) ので、割れない。
///
/// すべてメインスレッドから呼ぶこと。
///
/// 出力先が変わったとき (有線イヤホン・USB-C オーディオ・Bluetooth の抜き差し) は、
/// エンジンが止まり、出力側のサンプルレート/チャンネル数も変わることがある。
/// そのため、変更の通知を受けたら「つなぎ直してから起動し直す」(rebuild)。
/// 起動に失敗しても1回だけつなぎ直して再挑戦する (以前は失敗を黙って捨てていたので、ずっと無音のままだった)。
final class KeySound {
    static let shared = KeySound()

    /// ほどいた波形 (左右)。モノラルの音は、左右が同じ配列を指す
    private struct DecodedWave {
        let left: [Float]
        let right: [Float]
    }

    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var cursor = 0
    private var format: AVAudioFormat?              // 全部のノード・波形で共通 (44.1kHz ステレオ)
    private var buffers: [AVAudioPCMBuffer] = []    // buffers[n - 1] = ノーツが n 個同時のときの音 (n = 1...maxChord)
    private var waves: [NoteSoundKind: DecodedWave] = [:]   // base64 からほどいた波形 (切り替えるたびに読み直さないため)
    private var kind: NoteSoundKind = .defaultKind
    private var configured = false
    private var pendingUntil: [Double] = []   // ノードごとの「先行予約した音が鳴り終わる時刻」(CACurrentMediaTime と同じ時間軸)
    private var bufferDur = 0.1               // キー音1発の長さ (秒)。波形を読んだときに実際の長さへ更新する

    private var observing = false
    private var needsRebuild = false          // 出力先が変わった → 次に鳴らす前につなぎ直す

    // playNow() の「ほぼ同時」の判定 (テストプレイで、複数の指・複数のノーツをほぼ同時に捌いたとき)
    private var chordStart = -1.0             // 今のかたまりの最初の音を鳴らした時刻
    private var chordCount = 0                // 今のかたまりに入っている音の数 (0 = まだ無い)
    private var chordNode = 0                 // 今のかたまりを鳴らしているノード

    /// 最後にエンジンの起動に失敗した理由 (空なら正常)。鳴らないときの診断用 (SETTING に出して使える)
    private(set) var lastError = ""

    /// 0...1 (SETTING の「ノーツサウンド」)
    var volume: Float = 0.8 {
        didSet {
            if configured { engine.mainMixerNode.outputVolume = min(max(volume, 0), 1) }
        }
    }

    /// 同時に鳴らせる数 (ラウンドロビン)。いちばん長い音 (約 250ms) でも、1 秒に 60 発までは詰まらない
    private static let voices = 16

    // MARK: 同時ノーツで音が大きくなる決まり

    /// 大きくなるのはここまで (これ以上の同時数は、この個数と同じ大きさ)
    static let maxChord = 6
    /// n 個同時のときの大きさ = n の chordExponent 乗 (振幅の倍率)。
    /// 1.0 なら、同じ音を n 個重ねたのと同じ (2 個で +6dB)。小さいほど控えめ。
    /// 0.75 のときは、2 個で ×1.68 (+4.5dB) / 3 個で ×2.28 (+7.2dB) / 4 個で ×2.83 (+9.0dB) / 6 個で ×3.83 (+11.7dB)
    private static let chordExponent: Float = 0.75
    /// 大きくした波形の、ここまでは手を加えない (0...1)。これより上の山を、1.0 に近づけながらなめらかに丸める
    private static let limiterKnee: Float = 0.6
    /// playNow() で、最初の音から何秒以内に来た音を「同時」とみなすか (同じタッチイベント・同じフレームの中の差を吸収する)
    private static let chordWindow = 0.02

    /// ノーツが n 個同時のときの、元の音に掛ける倍率 (n = 1 は 1.0)
    static func chordGain(_ n: Int) -> Float {
        let k = min(max(n, 1), maxChord)
        return pow(Float(k), chordExponent)
    }

    private init() {}

    // MARK: - 準備

    /// エンジンを起動しておく (最初の1発が遅れないように、エディタを開いた時・再生前に呼ぶ)
    func prepare() {
        _ = ensureRunning()
    }

    /// 鳴らす種類を切り替える。エンジンを止めずに、波形だけ差し替える (すでに予約した音は、前の種類のまま鳴る)
    func select(_ newKind: NoteSoundKind) {
        if newKind == kind && !buffers.isEmpty { return }
        kind = newKind
        if configured { loadBuffers() }     // 準備前なら、configureIfNeeded が今の kind で読む
    }

    private func configureIfNeeded() {
        if configured { return }
        // エンジンを組む前にセッションを起こす。
        // (先に組むと、出力側の形式が「セッションを起こす前のもの」で決まってしまい、
        //  イヤホン接続中だと起動に失敗することがある)
        AudioSessionSetup.activate()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: KeySoundData.sampleRate, channels: 2) else { return }
        format = fmt
        guard loadBuffers() else {
            format = nil
            return
        }
        for _ in 0..<KeySound.voices {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: fmt)
            nodes.append(n)
        }
        pendingUntil = Array(repeating: 0, count: nodes.count)
        engine.mainMixerNode.outputVolume = min(max(volume, 0), 1)
        configured = true
        observe()
    }

    /// 今の種類の音を、同時ノーツ数 1...maxChord ぶん作って buffers に入れる。作れなかったら buffers は今のまま
    @discardableResult
    private func loadBuffers() -> Bool {
        guard let fmt = format, let wave = decodedWave(kind) else {
            lastError = "ノーツサウンドの波形を読めませんでした (\(kind.rawValue))"
            return false
        }
        var made: [AVAudioPCMBuffer] = []
        for n in 1...KeySound.maxChord {
            guard let b = KeySound.makeBuffer(wave: wave, chord: n, format: fmt) else {
                lastError = "ノーツサウンドの波形を作れませんでした (\(kind.rawValue))"
                return false
            }
            made.append(b)
        }
        buffers = made
        bufferDur = Double(made[0].frameLength) / fmt.sampleRate
        return true
    }

    /// 出力先の変更・エンジンの設定変更・メディアサービスのリセットを受け取る
    private func observe() {
        if observing { return }
        observing = true
        let mark: (Notification) -> Void = { [weak self] _ in self?.needsRebuild = true }
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main, using: mark)
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main, using: mark)
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main, using: mark)
    }

    /// エンジンを止めて、出力先の今の形式でつなぎ直す (まだ鳴っていない予約は捨てる)
    private func rebuild() {
        engine.stop()
        for i in nodes.indices {
            nodes[i].stop()
            pendingUntil[i] = 0
        }
        let out = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode,
                       format: (out.sampleRate > 0 && out.channelCount > 0) ? out : nil)
        if let f = format {
            for n in nodes { engine.connect(n, to: engine.mainMixerNode, format: f) }
        }
    }

    /// エンジンが止まっていたら(割り込み・イヤホン抜き差しなど)つなぎ直して起こし、ノードも再生状態にする
    private func ensureRunning() -> Bool {
        configureIfNeeded()
        guard configured else { return false }
        if needsRebuild || !engine.isRunning {
            AudioSessionSetup.activate()
            if needsRebuild { rebuild() }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                // 1回だけ、つなぎ直して再挑戦
                rebuild()
                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    lastError = "\(error)"
                    return false
                }
            }
            needsRebuild = false
            lastError = ""
        }
        for n in nodes where !n.isPlaying {
            n.play()
        }
        return true
    }

    // MARK: - 鳴らす

    /// すぐ鳴らす。ほぼ同時 (chordWindow 以内) に続けて呼ばれたら、同じノードで、個数ぶん大きい音に差し替える
    /// (足し算で重ねないので、音が割れず、重なり方のズレも出ない)
    func playNow() {
        guard volume > 0.001, ensureRunning(), !buffers.isEmpty else { return }
        let now = CACurrentMediaTime()
        if chordCount > 0, now - chordStart < KeySound.chordWindow {
            if chordCount >= KeySound.maxChord { return }     // これ以上は大きくならない
            chordCount += 1
        } else {
            chordStart = now
            chordCount = 1
            chordNode = cursor
            cursor = (cursor + 1) % nodes.count
        }
        let idx = min(chordCount, buffers.count) - 1
        nodes[chordNode].scheduleBuffer(buffers[idx], at: nil, options: .interrupts, completionHandler: nil)
    }

    /// time: CACurrentMediaTime() と同じ時間軸(秒)。すでに過ぎていたらすぐ鳴らす
    /// count: その時刻に同時に来るノーツの数 (多いほど大きい音で鳴る)
    func play(atTime time: Double, count: Int = 1) {
        guard volume > 0.001, ensureRunning(), !buffers.isEmpty else { return }
        let buf = buffers[min(max(count, 1), buffers.count) - 1]
        let idx = cursor
        let n = nodes[idx]
        cursor = (cursor + 1) % nodes.count
        if time > CACurrentMediaTime() + 0.002 {
            let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: time))
            n.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
            pendingUntil[idx] = max(pendingUntil[idx], time + bufferDur + 0.01)
        } else {
            n.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        }
    }

    /// 予約済み(まだ鳴っていない)の音を捨てる。
    /// AVAudioPlayerNode.stop() は1回ごとにオーディオスレッドの完了待ちで数十ms止まることがあるため、
    /// 「まだ鳴っていない予約を持つノード」だけを止める (以前は全ノードを stop + play していた)。
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

    // MARK: - 音の用意

    /// 埋め込みの波形 (KeySoundData: 16bit PCM の base64) をほどく。読めなければ nil。一度ほどいたものは覚えておく
    private func decodedWave(_ k: NoteSoundKind) -> DecodedWave? {
        if let w = waves[k] { return w }
        let src = KeySoundData.wave(for: k)
        let channels = src.channels
        guard channels == 1 || channels == 2,
              let data = Data(base64Encoded: src.pcm16Base64, options: .ignoreUnknownCharacters)
        else { return nil }
        let bytes = [UInt8](data)
        let frames = bytes.count / (2 * channels)
        guard frames > 0 else { return nil }
        var left = [Float](repeating: 0, count: frames)
        var right = left
        for f in 0..<frames {
            left[f] = KeySound.sample16(bytes, f * channels)
            if channels == 2 {
                right[f] = KeySound.sample16(bytes, f * channels + 1)
            }
        }
        if channels == 1 { right = left }
        let w = DecodedWave(left: left, right: right)
        waves[k] = w
        return w
    }

    /// bytes の i 番目の 16bit (リトルエンディアン) を -1...1 にする
    private static func sample16(_ bytes: [UInt8], _ i: Int) -> Float {
        let lo = UInt16(bytes[2 * i])
        let hi = UInt16(bytes[2 * i + 1]) << 8
        return Float(Int16(bitPattern: lo | hi)) / 32768
    }

    /// 波形に chordGain(n) を掛けたバッファを作る (n = 1 は元の音のまま)
    private static func makeBuffer(wave: DecodedWave, chord n: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = wave.left.count
        guard frames > 0, wave.right.count == frames, format.channelCount == 2,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        let gain = chordGain(n)
        let l = ch[0]
        let r = ch[1]
        for i in 0..<frames {
            l[i] = scaled(wave.left[i], gain)
            r[i] = scaled(wave.right[i], gain)
        }
        return buf
    }

    /// 倍率を掛ける。大きくするとき (gain > 1) だけ、1.0 を越えそうな山を丸める
    private static func scaled(_ x: Float, _ gain: Float) -> Float {
        if gain <= 1 { return x * gain }
        return softLimit(x * gain)
    }

    /// limiterKnee までは何もしない。それより上は、1.0 に近づけながら (越えずに) なめらかに丸める。
    /// つなぎ目で傾きが連続している (tanh の根元の傾きが 1) ので、急に歪みが始まらない
    private static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        let k = limiterKnee
        if a <= k { return x }
        let y = k + (1 - k) * tanh((a - k) / (1 - k))
        return x < 0 ? -y : y
    }
}
