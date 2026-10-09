import SwiftUI

extension Beat {
    /// "8:0/4" / "8" 形式を解釈 (0拍始まり)
    static func parse(_ s: String) -> Beat? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(whereSeparator: { $0 == ":" || $0 == "/" }).map { String($0) }
        let nums = parts.compactMap { Int($0) }
        if parts.isEmpty || nums.count != parts.count { return nil }
        if nums.count == 1 { return Beat(nums[0], 0, 1) }
        if nums.count == 3 && nums[2] > 0 { return Beat(nums[0], nums[1], nums[2]) }
        return nil
    }
}

// MARK: - BPM list

struct BPMListSheet: View {
    @ObservedObject var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0
    @State private var beatText = ""
    @State private var bpmText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                List {
                    ForEach(Array(state.chart.times.enumerated()), id: \.offset) { entry in
                        Button {
                            selected = entry.offset
                            beatText = entry.element.beat.label
                            bpmText = String(format: "%.3f", entry.element.bpm)
                        } label: {
                            HStack {
                                Text(entry.element.beat.label)
                                Spacer()
                                Text(String(format: "%.3f", entry.element.bpm))
                            }
                            .foregroundColor(entry.offset == selected ? Color.cyan : Color.primary)
                        }
                    }
                }
                .frame(minHeight: 160)

                VStack(spacing: 10) {
                    HStack {
                        Text("Beat").frame(width: 60, alignment: .leading)
                        TextField("例 8:0/4", text: $beatText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button("現在位置") {
                            beatText = state.snapBeat(state.currentBeat()).label
                        }
                    }
                    HStack {
                        Text("BPM").frame(width: 60, alignment: .leading)
                        TextField("例 132", text: $bpmText)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                    }
                    HStack(spacing: 16) {
                        Button("Add / 更新") {
                            if let b = Beat.parse(beatText), let v = Double(bpmText) {
                                state.addOrReplaceBPM(beat: b, bpm: v)
                            } else {
                                state.showToast("Beat か BPM の形式が不正です")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Remove", role: .destructive) {
                            state.removeBPM(at: selected)
                            selected = 0
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                Spacer(minLength: 0)
            }
            .navigationTitle("BPM list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .onAppear {
            beatText = state.snapBeat(state.currentBeat()).label
            if let f = state.chart.times.first {
                bpmText = String(format: "%.3f", f.bpm)
            }
        }
    }
}

// MARK: - Effect list (scroll / jump)

struct EffectListSheet: View {
    @ObservedObject var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var selected = -1
    @State private var beatText = ""
    @State private var kind: EffectPoint.Kind = .scroll
    @State private var valueText = "1"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                List {
                    if state.chart.effects.isEmpty {
                        Text("effect はまだありません")
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(state.chart.effects.enumerated()), id: \.offset) { entry in
                        Button {
                            selected = entry.offset
                            beatText = entry.element.beat.label
                            kind = entry.element.kind
                            valueText = entry.element.valueText
                        } label: {
                            HStack {
                                Text(entry.element.beat.label)
                                Spacer()
                                Text(entry.element.kind.label)
                                    .foregroundColor(.secondary)
                                Text(entry.element.valueText)
                                    .frame(minWidth: 90, alignment: .trailing)
                            }
                            .foregroundColor(entry.offset == selected ? Color.cyan : Color.primary)
                        }
                    }
                }
                .frame(minHeight: 160)

                VStack(spacing: 10) {
                    HStack {
                        Text("Beat").frame(width: 60, alignment: .leading)
                        TextField("例 8:0/4", text: $beatText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button("現在位置") {
                            beatText = state.snapBeat(state.currentBeat()).label
                        }
                    }
                    Picker("種類", selection: $kind) {
                        Text("scroll").tag(EffectPoint.Kind.scroll)
                        Text("jump").tag(EffectPoint.Kind.jump)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("値").frame(width: 60, alignment: .leading)
                        TextField(kind == .scroll ? "例 0.5 / -1" : "例 10000000", text: $valueText)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    }
                    Text(kind == .scroll
                         ? "scroll: その拍から、譜面の流れる速さが 値 倍になります (1 = 普通 / 0 = 止まる / マイナス = 逆走)。"
                         : "jump: その拍になった瞬間、譜面が先へ一気に飛びます。値は ms で、1000 = 1 秒間に進む距離ぶん (そのときの scroll の値に比例: scroll 0 なら飛ばず、2 なら 2 倍飛びます)。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 16) {
                        Button("Add / 更新") {
                            let text = valueText.trimmingCharacters(in: .whitespaces)
                            if let b = Beat.parse(beatText), b.value >= 0, let v = Double(text), v.isFinite {
                                state.addOrReplaceEffect(beat: b, kind: kind, value: v)
                                if let i = state.chart.effects.firstIndex(where: { $0.beat == b && $0.kind == kind }) {
                                    selected = i
                                }
                            } else {
                                state.showToast("Beat か 値の形式が不正です")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Remove", role: .destructive) {
                            if selected >= 0 && selected < state.chart.effects.count {
                                state.removeEffect(at: selected)
                                selected = -1
                            } else {
                                state.showToast("消す effect を一覧から選んでください")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                Spacer(minLength: 0)
            }
            .navigationTitle("Effect list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .onAppear {
            beatText = state.snapBeat(state.currentBeat()).label
        }
    }
}

// MARK: - Grid settings

struct GridSettingsSheet: View {
    @ObservedObject var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var lines = 16
    @State private var align = true

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Grid lines (縦線の分割数)")) {
                    HStack {
                        Slider(value: Binding(get: { Double(lines) }, set: { lines = Int($0.rounded()) }), in: 1...64)
                        Text("\(lines)").frame(width: 40, alignment: .trailing)
                    }
                    Stepper("分割数", value: $lines, in: 1...64)
                }
                Section {
                    Toggle("Grid align (ノーツをグリッドに合わせる)", isOn: $align)
                } footer: {
                    Text("座標は 0〜255 のため、割り切れない分割数では端数を四捨五入して隙間・重なりを最小にします。")
                }
            }
            .navigationTitle("Grid settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("戻る") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        state.gridLines = lines
                        state.gridAlign = align
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            lines = state.gridLines
            align = state.gridAlign
        }
    }
}

// MARK: - Slide modify (レーンに重ねる窓)

/// Slide modify を選んでいる間、レーンの上に出る横長の細い窓 (「Slide modify」の表示と「完了」だけ)。
/// シートではないので背景は暗くならず、窓の外のレーンはそのまま触れる。
/// 編集はすべてレーン上で行う (EditorState+Tools.swift の「Slide modify (レーン上の操作)」):
///   スライドをタップして選ぶ / 点 (seg) をドラッグで動かす / 点をタップすると隣に「削除」 / 空いている所をタップで seg を追加
struct SlideModifyWindow: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 10) {
            Text("Slide modify")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Text(hint)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 4)
            Button {
                state.finishSlideModify()
            } label: {
                Text("完了")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.laneCyan.opacity(0.9)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.35), lineWidth: 1))
    }

    /// 今の状態に合わせた操作のヒント
    private var hint: String {
        if state.modifySlideIndex == nil { return "スライドをタップして選択" }
        if state.modifySegIndex != nil { return "「削除」で消す / ドラッグで移動" }
        return "点: ドラッグで移動・タップで削除 / 空き: タップで追加"
    }
}

// MARK: - メタデータ (Back / Information / More)

struct MetaSheet: View {
    @ObservedObject var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0            // 0: menu / 1: information
    @State private var exportURL: URL? = nil
    @State private var exportError: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case 1: infoPage
                default: menuPage
                }
            }
            .navigationTitle(page == 1 ? "Information" : "Metadata")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// META を押した直後の画面。以前は「More」を押した先にあった 2 項目 (エクスポート / エディタを閉じる) を、ここに直接並べている
    private var menuPage: some View {
        List {
            Section {
                Button("Back") { dismiss() }
                Button("Information") { page = 1 }
            }
            Section(footer: Text("mc / 音源 / 背景画像を mcz(zip) にまとめて共有します。")) {
                Button("譜面をパッケージ化してエクスポート") {
                    do {
                        exportURL = try state.exportPackage()
                        exportError = nil
                    } catch {
                        exportError = "エクスポートに失敗しました: \(error.localizedDescription)"
                    }
                }
                if let u = exportURL {
                    ShareLink(item: u) {
                        Label(u.lastPathComponent + " を共有 / 保存", systemImage: "square.and.arrow.up")
                    }
                }
                if let e = exportError {
                    Text(e).foregroundColor(.red).font(.footnote)
                }
            }
            Section {
                Button("エディタを閉じてファイル選択に戻る", role: .destructive) {
                    state.saveNow()
                    dismiss()
                    state.onClose?()
                }
            }
        }
    }

    private func field(_ title: String, _ path: [String]) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            TextField(title, text: Binding(
                get: { state.chart.metaString(path) },
                set: {
                    state.chart.setMetaString(path, $0)
                    state.metaChanged()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
        }
    }

    private var infoPage: some View {
        Form {
            Section(header: Text("曲情報")) {
                field("タイトル", ["song", "title"])
                field("原題", ["song", "titleorg"])
                field("アーティスト", ["song", "artist"])
            }
            Section(header: Text("譜面情報")) {
                field("作者", ["creator"])
                field("難易度名", ["version"])
            }
            Section(header: Text("音源")) {
                HStack {
                    Text("ファイル名").frame(width: 90, alignment: .leading)
                    Text(state.chart.soundFile.isEmpty ? state.oggFileName : state.chart.soundFile)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("オフセット").frame(width: 90, alignment: .leading)
                    TextField("ms", text: Binding(
                        get: { String(state.chart.offsetMs) },
                        set: { if let v = Int($0) { state.setOffset(v) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    Text("ms")
                }
                Stepper("オフセット ±10ms", onIncrement: {
                    state.setOffset(state.chart.offsetMs + 10)
                }, onDecrement: {
                    state.setOffset(state.chart.offsetMs - 10)
                })
                if let a = state.audio {
                    Text("音源読込: \(a.info) / 長さ \(state.timeString(a.duration))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("音源なし (無音で編集中)").font(.footnote).foregroundColor(.secondary)
                }
            }
            Section {
                Button("戻る") { page = 0 }
            }
        }
    }
}
