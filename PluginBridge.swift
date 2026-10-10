import Foundation

// Lua プラグイン (別スレッドで動く) から、メインスレッドの EditorState を触るための橋渡し。
//   ・Lua 側の Editor:〇〇() は、JavaScript 側で native("コマンド名", 引数…) に変換されて、ここの handle に届く
//   ・譜面を書き換えるコマンドは、メインスレッドで実行する (DispatchQueue.main.sync)
//   ・1回の Run() = Undo 1回分。最初に書き換えたときに pushUndo し、Run() が終わる (または画面にダイアログを出す) ときに chartChanged を1回だけ呼ぶ
//   ・ShowMessage / GetUserInput は、画面にダイアログを出して、答えが返るまで Lua 側を待たせる

/// 実行の中断 (停止ボタン) を、別スレッドから安全に読み書きするための旗
final class PluginCancel {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// プラグインが出した ShowMessage / GetUserInput の画面表示 (1つ出ている間、Lua は待っている)
final class PluginDialog: Identifiable {
    enum Kind {
        case message
        case input
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    let defaultText: String
    private var completion: ((String?) -> Void)?

    init(kind: Kind, title: String, message: String, defaultText: String = "", completion: ((String?) -> Void)? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.defaultText = defaultText
        self.completion = completion
    }

    /// 答えを返して、待っている Lua を再開させる。2回呼んでも、2回目は何もしない
    func finish(_ text: String?) {
        let c = completion
        completion = nil
        c?(text)
    }
}

final class PluginBridge {
    private weak var state: EditorState?
    let pluginName: String
    let assetDir: URL?                     // スプライトの画像を探すフォルダ (プラグインのファイルがあるフォルダ)
    let cancel = PluginCancel()

    // メインスレッドだけで触る
    private var undoPushed = false
    private var dirty = false
    private var indexMap: [UUID: Int] = [:]
    private var sortedCache: [UUID]? = nil
    private var pendingSlides = Set<UUID>()      // AddNote(2048) で作った、まだ seg を持たないスライド

    // 複数のスレッドから触る
    private let lock = NSLock()
    private var logText = ""
    private var unsupportedList: [String] = []
    private var notified = false                       // プラグイン自身が ShowMessage / ShowTip で知らせたか (終了時の「実行しました」で上書きしないため)
    private var clickXValue: Double = 127              // 操作型プラグインに渡す、いま触れているレーン上の位置
    private var clickBeatSnapped = Beat.zero
    private var clickBeatFreeValue: Double = 0
    private var deadline: Date? = nil                  // この時刻を過ぎたら、実行を止める (操作型の1イベントの時間制限)

    private let nullJSON = "[null]"

    init(state: EditorState?, pluginName: String, assetDir: URL? = nil) {
        self.state = state
        self.pluginName = pluginName
        self.assetDir = assetDir
    }

    /// 触れている位置を、プラグインに渡す値として覚える (GetClickX / GetClickBeat / GetClickBeatFree)
    func setClick(x: Double, snapped: Beat, free: Double) {
        lock.lock()
        clickXValue = x
        clickBeatSnapped = snapped
        clickBeatFreeValue = free
        lock.unlock()
    }

    func setDeadline(_ d: Date?) {
        lock.lock()
        deadline = d
        lock.unlock()
    }

    /// 新しい操作 (ドラッグなど) の始まり。この操作の最初の書き換えで、Undo を1つ積む
    func beginGesture() {
        undoPushed = false
    }

    // MARK: - Lua スレッドから呼ばれる入口

    func handle(_ name: String, _ argsJSON: String) -> String {
        switch name {
        case "poll":
            if cancel.isCancelled { return "[true]" }
            lock.lock()
            let limit = deadline
            lock.unlock()
            if let d = limit, Date() > d { return "[true]" }
            return "[false]"
        case "log":
            let a = parseArgs(argsJSON)
            lock.lock()
            logText += text(a, 0)
            lock.unlock()
            return nullJSON
        case "unsupported":
            let a = parseArgs(argsJSON)
            let n = text(a, 0)
            lock.lock()
            if !unsupportedList.contains(n) { unsupportedList.append(n) }
            lock.unlock()
            return nullJSON
        case "clickX":
            lock.lock()
            let v = clickXValue
            lock.unlock()
            return json(v)
        case "clickBeat":
            lock.lock()
            let b = clickBeatSnapped
            lock.unlock()
            return json(beatArr(b))
        case "clickBeatFree":
            lock.lock()
            let f = clickBeatFreeValue
            lock.unlock()
            return json(beatArr(Beat.nearest(f, den: 1_048_576)))
        case "message":
            // ShowMessage: OK を押させて止めると、作譜の邪魔になる。答えは要らないので、画面の下に出すだけで、すぐ続ける
            // (長い文章は、Adv. メニューの「出力」欄にも残す)
            let s = text(parseArgs(argsJSON), 0)
            if s.isEmpty { return nullJSON }
            lock.lock()
            logText += "[メッセージ] " + s + "\n"
            notified = true
            lock.unlock()
            notice(s)
            return nullJSON
        case "input":
            // 操作型プラグインはメインスレッドで動くので、答えを待てない: 表示だけして、すぐ続ける (入力は nil になる)
            if Thread.isMainThread { return dialogOnMain(parseArgs(argsJSON)) }
            return dialogCall(name, parseArgs(argsJSON))
        case "tip":
            let a = parseArgs(argsJSON)
            let s = text(a, 0)
            if s.isEmpty { return nullJSON }
            lock.lock()
            notified = true
            lock.unlock()
            notice(s)
            return nullJSON
        default:
            if state == nil { return nullJSON }
            let a = parseArgs(argsJSON)
            if Thread.isMainThread { return handleMain(name, a) }
            var out = nullJSON
            DispatchQueue.main.sync {
                out = self.handleMain(name, a)
            }
            return out
        }
    }

    func takeLog() -> String {
        lock.lock()
        defer { lock.unlock() }
        return logText
    }

    func takeUnsupported() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return unsupportedList
    }

    /// 実行中に、プラグイン自身が ShowMessage / ShowTip で知らせたか
    func wasNotified() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return notified
    }

    /// 画面の下に、止まらない知らせを出す (どのスレッドからでも呼べる)
    private func notice(_ s: String) {
        if Thread.isMainThread {
            state?.showPluginNotice(s)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.state?.showPluginNotice(s)
            }
        }
    }

    // MARK: - メインスレッドから呼ぶ

    /// 溜まっている変更を画面・保存に反映する (Run() が終わったとき / ダイアログを出す前)
    func flushMain() {
        guard dirty, let st = state else { return }
        dirty = false
        st.chartChanged()
    }

    // MARK: - ダイアログ

    /// メインスレッドで動く操作型プラグイン用。表示だけして、答えは待たない
    private func dialogOnMain(_ a: [Any]) -> String {
        guard let st = state else { return nullJSON }
        flushMain()
        st.pluginDialog = PluginDialog(kind: .message, title: pluginName, message: text(a, 0))
        return nullJSON
    }

    // Lua スレッドで答えが返るまで待つ

    private func dialogCall(_ name: String, _ a: [Any]) -> String {
        if state == nil { return nullJSON }
        let sem = DispatchSemaphore(value: 0)
        var answer: String? = nil
        let isInput = (name == "input")
        let msg = text(a, 0)
        let dflt = text(a, 1)
        DispatchQueue.main.async { [weak self] in
            guard let me = self, let st = me.state else {
                sem.signal()
                return
            }
            me.flushMain()
            let d = PluginDialog(kind: isInput ? .input : .message,
                                 title: me.pluginName,
                                 message: msg,
                                 defaultText: dflt) { r in
                answer = r
                sem.signal()
            }
            st.pluginDialog = d
        }
        sem.wait()
        if isInput, let s = answer { return json(s) }
        return nullJSON
    }

    // MARK: - 引数・戻り値の変換

    private func parseArgs(_ s: String) -> [Any] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let arr = obj as? [Any] else { return [] }
        return arr
    }

    private func arg(_ a: [Any], _ i: Int) -> Any? {
        return i >= 0 && i < a.count ? a[i] : nil
    }

    private func num(_ a: [Any], _ i: Int) -> Double {
        return (arg(a, i) as? NSNumber)?.doubleValue ?? 0
    }

    private func intv(_ a: [Any], _ i: Int) -> Int {
        let d = num(a, i)
        if !d.isFinite { return 0 }
        return Int(max(-1_000_000_000.0, min(1_000_000_000.0, d.rounded(.towardZero))))
    }

    private func text(_ a: [Any], _ i: Int) -> String {
        return (arg(a, i) as? String) ?? ""
    }

    private func flag(_ a: [Any], _ i: Int) -> Bool {
        return (arg(a, i) as? NSNumber)?.boolValue ?? false
    }

    /// 戻り値は常に [値] の形の JSON (JavaScript 側が [0] を取り出す)
    private func json(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject([v]),
              let data = try? JSONSerialization.data(withJSONObject: [v], options: []),
              let s = String(data: data, encoding: .utf8) else { return nullJSON }
        return s
    }

    private func beatArr(_ b: Beat) -> [Int] {
        return [b.m, b.n, b.d]
    }

    private func clampInt(_ v: Double, _ lo: Int, _ hi: Int) -> Int {
        if !v.isFinite { return lo }
        return Int(max(Double(lo), min(Double(hi), v.rounded())))
    }

    /// プラグインから来た [整数部, 分子, 分母] を Beat にする。
    /// 約分して分母を小さく保つ。極端に大きい値は 1/1048576 拍に丸める (Beat の計算で桁あふれしないように)
    static func makeBeat(_ m: Double, _ n: Double, _ d: Double) -> Beat {
        guard m.isFinite, n.isFinite, d.isFinite, d >= 1 else { return Beat.zero }
        if d > 4_194_304 || abs(m) > 100_000 || abs(n) > 4_000_000_000 {
            let v = max(-100_000.0, min(100_000.0, m + n / d))
            return reduced(Int((v * 1_048_576.0).rounded()), 1_048_576)
        }
        let mi = Int(m.rounded(.towardZero))
        let ni = Int(n.rounded(.towardZero))
        let di = Int(d.rounded(.towardZero))
        return reduced(mi * di + ni, di)
    }

    private static func reduced(_ t: Int, _ d: Int) -> Beat {
        let g = gcdInt(t, d)
        return Beat.ticks(t / g, den: d / g)
    }

    // MARK: - ノーツの探索

    private func noteIndex(_ st: EditorState, _ idText: String) -> Int? {
        guard let u = UUID(uuidString: idText) else { return nil }
        if let i = indexMap[u], i < st.chart.notes.count, st.chart.notes[i].id == u { return i }
        indexMap.removeAll(keepingCapacity: true)
        for (i, n) in st.chart.notes.enumerated() {
            indexMap[n.id] = i
        }
        return indexMap[u]
    }

    private func sortedIDs(_ st: EditorState) -> [UUID] {
        if let c = sortedCache { return c }
        let ids = st.chart.notes
            .sorted { x, y in x.beat == y.beat ? x.x < y.x : x.beat < y.beat }
            .map { $0.id }
        sortedCache = ids
        return ids
    }

    /// ノーツの終点の拍 (スライドなら、始点 + 最後の seg の相対 beat)
    private func tailBeat(_ n: Note) -> Beat {
        if let last = n.segs.last { return n.beat + last.beat }
        return n.beat
    }

    private func typeCode(_ n: Note) -> Int {
        if n.isSlide || pendingSlides.contains(n.id) { return 2048 }
        return n.isWipe ? 1024 : 1
    }

    /// 譜面を書き換える前に呼ぶ (最初の1回だけ Undo を積む)
    private func touch(_ st: EditorState) {
        if !undoPushed {
            st.pushUndo()
            undoPushed = true
        }
        dirty = true
        sortedCache = nil
    }

    // MARK: - コマンド (メインスレッド)

    private func handleMain(_ name: String, _ a: [Any]) -> String {
        guard let st = state else { return nullJSON }
        switch name {

        // ---- 情報の取得 ----
        case "currentTimeMs":
            return json(st.currentSec() * 1000.0)
        case "currentBeat":
            return json(beatArr(st.snapBeat(st.currentBeat())))
        case "divide":
            return json(st.snapDen)
        case "ordered":
            // 「順番に選択」(Order ボタン) で選んだスライド。タップした順。消えたものは含めない
            var ids: [String] = []
            for id in st.orderIDs where noteIndex(st, id.uuidString) != nil {
                ids.append(id.uuidString)
            }
            return json(ids)
        case "clearOrder":
            if !st.orderIDs.isEmpty { st.orderIDs = [] }
            return nullJSON
        case "selected":
            let ids = st.chart.notes
                .filter { st.selectedIDs.contains($0.id) }
                .sorted { x, y in x.beat == y.beat ? x.x < y.x : x.beat < y.beat }
                .map { $0.id.uuidString }
            return json(ids)
        case "noteCount":
            return json(st.chart.notes.count)
        case "noteAt":
            let ids = sortedIDs(st)
            let i = intv(a, 0)
            if i >= 0 && i < ids.count { return json(ids[i].uuidString) }
            return nullJSON
        case "noteTime":
            guard let i = noteIndex(st, text(a, 0)) else { return json(0.0) }
            let n = st.chart.notes[i]
            let b = flag(a, 1) ? n.beat : tailBeat(n)               // 2つ目の引数: true = 始点 / false = 終点
            return json(st.timeMap.sec(atBeat: b.value) * 1000.0)
        case "noteBeat":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            let n = st.chart.notes[i]
            return json(beatArr(flag(a, 1) ? n.beat : tailBeat(n)))
        case "noteX":
            guard let i = noteIndex(st, text(a, 0)) else { return json(0) }
            return json(st.chart.notes[i].x)
        case "noteW":
            guard let i = noteIndex(st, text(a, 0)) else { return json(0) }
            return json(st.chart.notes[i].w)
        case "noteType":
            guard let i = noteIndex(st, text(a, 0)) else { return json(1) }
            return json(typeCode(st.chart.notes[i]))
        case "segCount":
            guard let i = noteIndex(st, text(a, 0)) else { return json(0) }
            return json(st.chart.notes[i].segs.count)
        case "segBeat":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            let j = intv(a, 1)
            if j < 0 || j >= st.chart.notes[i].segs.count { return nullJSON }
            return json(beatArr(st.chart.notes[i].segs[j].beat))
        case "segX":
            guard let i = noteIndex(st, text(a, 0)) else { return json(0) }
            let j = intv(a, 1)
            if j < 0 || j >= st.chart.notes[i].segs.count { return json(0) }
            return json(st.chart.notes[i].segs[j].x)
        case "timeCount":
            return json(st.chart.times.count)
        case "timeAt":
            let i = intv(a, 0)
            if i < 0 || i >= st.chart.times.count { return nullJSON }
            let t = st.chart.times[i]
            let arr: [Any] = [t.beat.m, t.beat.n, t.beat.d, t.bpm]
            return json(arr)
        case "effectCount":
            return json(st.chart.effects.count)
        case "effectAt":
            let i = intv(a, 0)
            if i < 0 || i >= st.chart.effects.count { return nullJSON }
            let e = st.chart.effects[i]
            let arr: [Any] = [e.beat.m, e.beat.n, e.beat.d, e.kind.rawValue, e.value]
            return json(arr)

        // ---- ノーツの編集 ----
        case "addNote":
            touch(st)
            let t = intv(a, 0)
            let note = Note(beat: st.snapBeat(st.currentBeat()), x: 127, w: max(1, st.widthUnits), type: t == 1024 ? 4 : nil)
            st.chart.notes.append(note)
            indexMap[note.id] = st.chart.notes.count - 1
            if t == 2048 { pendingSlides.insert(note.id) }
            return json(note.id.uuidString)
        case "deleteNote":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            touch(st)
            let id = st.chart.notes[i].id
            st.chart.notes.remove(at: i)
            indexMap.removeAll(keepingCapacity: true)
            pendingSlides.remove(id)
            st.selectedIDs.remove(id)
            return nullJSON
        case "setNoteBeat":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            touch(st)
            var b = PluginBridge.makeBeat(num(a, 1), num(a, 2), num(a, 3))
            if b.value < 0 { b = Beat.zero }
            st.chart.notes[i].beat = b
            return nullJSON
        case "setNoteX":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            touch(st)
            st.chart.notes[i].x = clampInt(num(a, 1), 0, 255)
            return nullJSON
        case "setNoteW":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            touch(st)
            st.chart.notes[i].w = clampInt(num(a, 1), 1, 255)
            return nullJSON
        case "addSeg":
            // 本物の Malody と同じく、beat の順になる位置に挿入する (同じ beat なら、あとから足したほうが後ろ)。入れた位置 (0 始まり) を返す
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            touch(st)
            let b = PluginBridge.makeBeat(num(a, 1), num(a, 2), num(a, 3))
            var pos = st.chart.notes[i].segs.count
            while pos > 0 && st.chart.notes[i].segs[pos - 1].beat > b { pos -= 1 }
            st.chart.notes[i].segs.insert(Seg(beat: b, x: 0), at: pos)
            pendingSlides.remove(st.chart.notes[i].id)
            return json(pos)
        case "appendSeg":
            // このエディタ独自: 並べ替えず、足した順のまま末尾に足す (beat が行ったり来たりする「バグスライド」用)
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            touch(st)
            let b = PluginBridge.makeBeat(num(a, 1), num(a, 2), num(a, 3))
            st.chart.notes[i].segs.append(Seg(beat: b, x: 0))
            pendingSlides.remove(st.chart.notes[i].id)
            return json(st.chart.notes[i].segs.count - 1)
        case "setSegX":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            let j = intv(a, 1)
            if j < 0 || j >= st.chart.notes[i].segs.count { return nullJSON }
            touch(st)
            st.chart.notes[i].segs[j].x = clampInt(num(a, 2), -100_000, 100_000)
            return nullJSON
        case "delSeg":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            touch(st)
            let wasSlide = !st.chart.notes[i].segs.isEmpty
            if let j = (arg(a, 1) as? NSNumber)?.intValue {
                if j >= 0 && j < st.chart.notes[i].segs.count { st.chart.notes[i].segs.remove(at: j) }
            } else {
                st.chart.notes[i].segs.removeAll()
            }
            if wasSlide && st.chart.notes[i].segs.isEmpty { pendingSlides.insert(st.chart.notes[i].id) }
            return nullJSON
        case "select":
            guard let i = noteIndex(st, text(a, 0)) else { return nullJSON }
            let id = st.chart.notes[i].id
            if flag(a, 1) {
                st.selectedIDs.insert(id)
            } else {
                st.selectedIDs.remove(id)
            }
            return nullJSON

        // ---- BPM・エフェクト ----
        case "addTime":
            let b = PluginBridge.makeBeat(num(a, 0), num(a, 1), num(a, 2))
            if b.value < 0 { return nullJSON }
            touch(st)
            let bpm = max(10.0, min(3000.0, num(a, 3)))
            if let idx = st.chart.times.firstIndex(where: { $0.beat == b }) {
                st.chart.times[idx].bpm = bpm
            } else {
                st.chart.times.append(TimePoint(beat: b, bpm: bpm))
            }
            st.chart.times.sort { $0.beat < $1.beat }
            return nullJSON
        case "delTime":
            let idx = intv(a, 0)
            if idx <= 0 || idx >= st.chart.times.count { return nullJSON }
            touch(st)
            st.chart.times.remove(at: idx)
            return nullJSON
        case "addEffect":
            let b = PluginBridge.makeBeat(num(a, 0), num(a, 1), num(a, 2))
            let value = num(a, 4)
            guard b.value >= 0, value.isFinite, let kind = EffectPoint.Kind(rawValue: text(a, 3)) else { return nullJSON }
            touch(st)
            if let idx = st.chart.effects.firstIndex(where: { $0.beat == b && $0.kind == kind }) {
                st.chart.effects[idx].value = value
            } else {
                st.chart.effects.append(EffectPoint(beat: b, kind: kind, value: value))
            }
            st.chart.effects.sort { $0.beat < $1.beat }
            return nullJSON
        case "delEffect":
            let idx = intv(a, 0)
            if idx < 0 || idx >= st.chart.effects.count { return nullJSON }
            touch(st)
            st.chart.effects.remove(at: idx)
            return nullJSON

        // ---- スプライト (レーンの上に重ねる画像) ----
        case "spriteAdd":
            let spriteName = text(a, 0)
            let image = text(a, 1)
            if let idx = st.pluginSprites.firstIndex(where: { $0.id == spriteName }) {
                st.pluginSprites[idx].image = image
            } else {
                st.pluginSprites.append(PluginSprite(id: spriteName, image: image, dir: assetDir))
            }
            return nullJSON
        case "spriteSet":
            let spriteName = text(a, 0)
            guard let idx = st.pluginSprites.firstIndex(where: { $0.id == spriteName }) else { return nullJSON }
            let value = arg(a, 2)
            switch text(a, 1) {
            case "Beat":
                if let arr = value as? [Any], arr.count >= 3 {
                    let m = (arr[0] as? NSNumber)?.doubleValue ?? 0
                    let n = (arr[1] as? NSNumber)?.doubleValue ?? 0
                    let d = (arr[2] as? NSNumber)?.doubleValue ?? 1
                    st.pluginSprites[idx].beat = d > 0 ? m + n / d : m
                }
            case "X":
                if let d = (value as? NSNumber)?.doubleValue { st.pluginSprites[idx].x = d }
            case "Width":
                if let d = (value as? NSNumber)?.doubleValue { st.pluginSprites[idx].width = d }
            case "Visible":
                if let b = (value as? NSNumber)?.boolValue { st.pluginSprites[idx].visible = b }
            default:
                break
            }
            return nullJSON
        case "spriteRemove":
            let spriteName = text(a, 0)
            st.pluginSprites.removeAll { $0.id == spriteName }
            return nullJSON

        // ---- 画面 ----
        case "setGrid":
            st.gridLines = max(1, min(255, intv(a, 0)))
            return nullJSON
        case "seekTo":
            let b = PluginBridge.makeBeat(num(a, 0), num(a, 1), num(a, 2))
            st.setViewBeat(b.value)
            return nullJSON
        case "batch":
            return nullJSON

        default:
            return nullJSON
        }
    }
}
