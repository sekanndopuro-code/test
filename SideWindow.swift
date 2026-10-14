import SwiftUI
import UIKit
import PhotosUI

// MARK: - 右からスライドして出るウィンドウ (BPM list / Effect list / Information / SETTING)
//
// シート (下からせり上がる) ではなく、EditorView の上に重ねる「ただのビュー」。
// 本家 (iPad Air 4 / 1180 × 820pt) の画面収録から測った値:
//   ・右の端から横に滑って入る。かかる時間は約 0.15 秒 (出るのを待たない)
//   ・ウィンドウは右のボタン列の上まで覆い、列のアイコンは見えなくなる。幅 445.5pt、
//     上は画面の上端から 23.4pt、下は画面の下端から 22.7pt (どちらも高さの 2.8%) まで
//   ・Add / Remove / 入力欄の高さは 44pt。入力欄と Add の間は 64pt あく
//   ・黒の半透明 (下のレーンとノーツが薄く透ける)。縁は白の細い線。右上と右下は斜めに欠け、左の上 (92pt まで) が 7.5pt 外に出る
//   ・Add / Remove / 入力欄は、白い縁取りの長方形
// 本家は「値を入れて Add すると勝手に閉じる」が、ここでは再現しない。
// 閉じるのは、ウィンドウより左 (範囲外) を触ったとき。閉じるときも横に滑って、すぐ消える。

extension EditorState {
    /// 右ウィンドウを開く。右の端から滑って入る
    func openSidePanel(_ panel: SidePanel) {
        popup = .none
        withAnimation(SideWindow.openAnimation) { sidePanel = panel }
    }

    /// 右ウィンドウを閉じる。右の端へ滑って消える
    func closeSidePanel() {
        withAnimation(SideWindow.closeAnimation) { sidePanel = nil }
    }
}

// MARK: - レイヤー (EditorView の overlay)

/// 範囲外タップで閉じるための透明な層と、右ウィンドウ本体をまとめる。
/// 開いていないときは、タッチを一切受けない (下のエディタにそのまま通る)。
struct SidePanelLayer: View {
    @ObservedObject var state: EditorState
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let globalBottom = proxy.frame(in: .global).maxY
            let width = min(SideWindow.width, size.width * 0.62)
            let top = size.height * SideWindow.topRatio
            // キーボードが出ているあいだは、ウィンドウの下端をキーボードの上へ上げる (入力欄が隠れない)
            let bottom = keyboardHeight > 0 ? keyboardHeight + 8 : size.height * SideWindow.bottomRatio
            let height = max(size.height - top - bottom, 240)

            ZStack(alignment: .topTrailing) {
                if let kind = state.sidePanel {
                    // ウィンドウの外 (左側) を触ると、すぐ閉じる
                    Color.black.opacity(0.001)
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { state.closeSidePanel() }
                        .transition(.identity)
                    SideWindow(state: state, kind: kind,
                               width: width, height: height, topGap: top,
                               compact: keyboardHeight > 0)
                        .zIndex(1)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topTrailing)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
                // 画面の下にくっついているキーボードだけ避ける (フローティングのキーボードは避けない)
                let docked = end.maxY >= globalBottom - 1
                let overlap = docked ? max(0, globalBottom - end.minY) : 0
                withAnimation(.easeOut(duration: 0.22)) { keyboardHeight = overlap }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .allowsHitTesting(state.sidePanel != nil)
    }
}

// MARK: - ウィンドウの枠

/// 本家の枠。右上と右下が斜めに欠け、左側の上 (92pt まで) が 7.5pt だけ外に出ている
private struct SideWindowShape: Shape {
    func path(in r: CGRect) -> Path {
        let cham: CGFloat = 12
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - cham, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cham))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cham))
        p.addLine(to: CGPoint(x: r.maxX - cham, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 7.5, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 7.5, y: r.minY + 99.75))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 92.25))
        p.closeSubpath()
        return p
    }
}

struct SideWindow: View {
    @ObservedObject var state: EditorState
    let kind: SidePanel
    let width: CGFloat
    let height: CGFloat
    let topGap: CGFloat
    /// キーボードが出ているとき (縦が足りないので、説明文を隠す)
    let compact: Bool

    /// 出る: 勢いよく入って、最後にすっと止まる / 閉じる: すぐ出ていく
    static let openAnimation = Animation.easeOut(duration: 0.16)
    static let closeAnimation = Animation.easeIn(duration: 0.12)

    /// 本家の幅 (pt)。画面が狭いときは、画面の 62% までに収める (SidePanelLayer)
    static let width: CGFloat = 445.5
    /// 画面の高さに対する、上と下の空き (本家: 23.4 / 820 と 22.7 / 820。2360 x 1640 のスクリーンショットから実測)
    static let topRatio: CGFloat = 23.4 / 820
    static let bottomRatio: CGFloat = 22.7 / 820

    /// 枠の左端 / 右端から、一覧の行 (選んだ行の灰色の帯) までの空き (本家の実測)。
    /// 下の入力欄とボタンだけは、右がさらに 12pt 内側 (formTrailingExtra)
    private static let leadingPad: CGFloat = 34
    private static let trailingPad: CGFloat = 34
    fileprivate static let formTrailingExtra: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            switch kind {
            case .bpm:
                BPMWindowContent(state: state, compact: compact)
            case .effect:
                EffectWindowContent(state: state, compact: compact)
            case .information:
                InformationWindowContent(state: state)
            case .setting:
                SettingWindowContent(state: state)
            }
        }
        .padding(.leading, Self.leadingPad)
        .padding(.trailing, Self.trailingPad)
        // 枠の中の何もないところを触ったら、キーボードだけ下げる (ウィンドウは閉じない)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }
        )
        .frame(width: width, height: height, alignment: .top)
        .background(SideWindowShape().fill(Color.black.opacity(0.72)))
        .overlay(SideWindowShape().stroke(Color.white.opacity(0.35), lineWidth: 1))
        .padding(.top, topGap)
    }
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - 部品 (白い縁取りの長方形が基本)

private struct SidePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

private struct SideTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(PanelFont.label(22))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 47)
            .padding(.bottom, 2)
    }
}

/// 一覧の 1 行。選んでいる行は灰色に塗る
private struct SideListRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .font(PanelFont.label(15))
                .foregroundColor(selected ? Color.white : Color.panelBlue)
                .padding(.leading, 16.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 31)
                .background(selected ? Color.white.opacity(0.41) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 左に名前、右に中身 (入力欄など)
private struct SideFormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(PanelFont.label(22))
                .foregroundColor(.white)
                .frame(width: 70, alignment: .leading)
            Spacer(minLength: 0)
            content()
        }
    }
}

private struct SideField: View {
    @Binding var text: String
    let placeholder: String
    let keyboard: UIKeyboardType

    var body: some View {
        TextField("", text: $text)
            .font(PanelFont.label(22))
            .foregroundColor(.white)
            .tint(.white)
            .multilineTextAlignment(.center)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 6)
            .frame(width: 170, height: 44)
            .overlay(
                Text(placeholder)
                    .font(PanelFont.label(18))
                    .foregroundColor(Color.white.opacity(0.3))
                    .opacity(text.isEmpty ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .overlay(Rectangle().stroke(Color.white, lineWidth: 2))
    }
}

/// Add / Remove
private struct SideButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PanelFont.label(26))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .overlay(Rectangle().stroke(Color.white, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(SidePressStyle())
    }
}

/// 「現在位置」のような、小さな縁取りボタン
private struct SideSmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PanelFont.label(16))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(SidePressStyle())
    }
}

/// scroll / jump の切り替え (選んでいるほうが水色)
private struct SideChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PanelFont.label(22))
                .foregroundColor(selected ? Color.panelBlue : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .overlay(Rectangle().stroke(selected ? Color.panelBlue : Color.white, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(SidePressStyle())
    }
}

// MARK: - BPM list

private struct BPMWindowContent: View {
    @ObservedObject var state: EditorState
    /// キーボードが出ているとき (縦が足りないので、入力欄とボタンの間をつめる)
    let compact: Bool
    @State private var selected = 0
    @State private var beatText: String
    @State private var bpmText: String

    init(state: EditorState, compact: Bool) {
        self._state = ObservedObject(wrappedValue: state)
        self.compact = compact
        // 開いた最初のフレームから値が入っているように、onAppear ではなくここで決める
        self._beatText = State(initialValue: state.snapBeat(state.currentBeat()).label)
        let first = state.chart.times.first.map { String(format: "%.3f", $0.bpm) } ?? ""
        self._bpmText = State(initialValue: first)
    }

    var body: some View {
        VStack(spacing: 0) {
            SideTitle(text: "BPM list")

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(state.chart.times.enumerated()), id: \.offset) { entry in
                        SideListRow(selected: entry.offset == selected, action: {
                            selected = entry.offset
                            beatText = entry.element.beat.label
                            bpmText = String(format: "%.3f", entry.element.bpm)
                        }) {
                            // 本家: 値 (BPM) の中心は、行の左端から 225.6pt。Beat は行の左端から 16.5pt
                            HStack(spacing: 0) {
                                Text(entry.element.beat.label)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .frame(width: 57, alignment: .leading)
                                Text(String(format: "%.3f", entry.element.bpm))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // 本家: Beat と BPM の行の間は 56pt、BPM の入力欄と Add / Remove の間は 64pt、ボタンの下は 35pt
            VStack(spacing: 12) {
                SideFormRow(label: "Beat") {
                    HStack(spacing: 8) {
                        SideSmallButton(title: "現在位置") {
                            beatText = state.snapBeat(state.currentBeat()).label
                        }
                        SideField(text: $beatText, placeholder: "8:0/4", keyboard: .numbersAndPunctuation)
                    }
                }
                SideFormRow(label: "BPM") {
                    SideField(text: $bpmText, placeholder: "132", keyboard: .decimalPad)
                }
                HStack(spacing: 24) {
                    SideButton(title: "Add") {
                        if let b = Beat.parse(beatText), let v = Double(bpmText) {
                            state.addOrReplaceBPM(beat: b, bpm: v)
                        } else {
                            state.showToast("Beat か BPM の形式が不正です")
                        }
                    }
                    SideButton(title: "Remove") {
                        state.removeBPM(at: selected)
                        selected = 0
                    }
                }
                .padding(.top, compact ? 0 : 52)
            }
            .padding(.trailing, SideWindow.formTrailingExtra)
            .padding(.top, 10)
            .padding(.bottom, compact ? 15 : 35)
        }
    }
}

// MARK: - Effect list (scroll / jump)

private struct EffectWindowContent: View {
    @ObservedObject var state: EditorState
    let compact: Bool
    @State private var selected = -1
    @State private var beatText: String
    @State private var kind: EffectPoint.Kind = .scroll
    @State private var valueText = "1"

    init(state: EditorState, compact: Bool) {
        self._state = ObservedObject(wrappedValue: state)
        self.compact = compact
        self._beatText = State(initialValue: state.snapBeat(state.currentBeat()).label)
    }

    var body: some View {
        VStack(spacing: 0) {
            SideTitle(text: "Effect list")

            ScrollView {
                VStack(spacing: 0) {
                    if state.chart.effects.isEmpty {
                        Text("effect はまだありません")
                            .font(PanelFont.label(15))
                            .foregroundColor(Color.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16.5)
                            .frame(height: 31)
                    }
                    ForEach(Array(state.chart.effects.enumerated()), id: \.offset) { entry in
                        SideListRow(selected: entry.offset == selected, action: {
                            selected = entry.offset
                            beatText = entry.element.beat.label
                            kind = entry.element.kind
                            valueText = entry.element.valueText
                        }) {
                            HStack(spacing: 0) {
                                Text(entry.element.beat.label)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .frame(width: 100, alignment: .leading)
                                Text(entry.element.kind.label)
                                    .frame(width: 70, alignment: .leading)
                                Text(entry.element.valueText)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.trailing, 16.5)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 12) {
                SideFormRow(label: "Beat") {
                    HStack(spacing: 8) {
                        SideSmallButton(title: "現在位置") {
                            beatText = state.snapBeat(state.currentBeat()).label
                        }
                        SideField(text: $beatText, placeholder: "8:0/4", keyboard: .numbersAndPunctuation)
                    }
                }
                HStack(spacing: 24) {
                    SideChoice(title: "scroll", selected: kind == .scroll) { kind = .scroll }
                    SideChoice(title: "jump", selected: kind == .jump) { kind = .jump }
                }
                SideFormRow(label: "Value") {
                    SideField(text: $valueText,
                              placeholder: kind == .scroll ? "0.5 / -1" : "10000000",
                              keyboard: .numbersAndPunctuation)
                }
                if !compact {
                    Text(kind == .scroll
                         ? "scroll: その拍から、譜面の流れる速さが 値 倍になります (1 = 普通 / 0 = 止まる / マイナス = 逆走)。"
                         : "jump: その拍になった瞬間、譜面が先へ一気に飛びます。値は ms で、1000 = 1 秒間に進む距離ぶん (そのときの scroll の値に比例: scroll 0 なら飛ばず、2 なら 2 倍飛びます)。")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 24) {
                    SideButton(title: "Add") {
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
                    SideButton(title: "Remove") {
                        if selected >= 0 && selected < state.chart.effects.count {
                            state.removeEffect(at: selected)
                            selected = -1
                        } else {
                            state.showToast("消す effect を一覧から選んでください")
                        }
                    }
                }
            }
            .padding(.trailing, SideWindow.formTrailingExtra)
            .padding(.top, 10)
            .padding(.bottom, compact ? 15 : 35)
        }
    }
}

// MARK: - Information (META → Information)
//
// 本家の Information と同じく、ラベルを上に、白い縁取りの入力欄を下に並べた縦長のウィンドウ。
// 入力欄は、触ったら編集できる (打つたびに譜面へ反映して、オートセーブする)。縦にスクロールできる。
// 曲のファイル / 背景ファイルは、mc に書いてあるファイル名の入力欄 (打つたびに譜面へ反映して、オートセーブする)。
//   書き換えても、付属の音源・画像のファイル名そのものは変わらない (mc の記述だけが変わる。mcz に書き出すときは、新しい名前で入る)。
// 背景ファイルの下の「写真から読み込む」は、写真アプリから選んだ画像に背景を入れ替える (すでに背景があれば置き換える)。

/// 幅いっぱいの入力欄 (左そろえ)。BPM / Effect の SideField (170pt・中央そろえ) とは別
private struct SideWideField: View {
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var isFileName = false      // ファイル名の欄は、先頭を勝手に大文字にしない

    var body: some View {
        TextField("", text: $text)
            .font(PanelFont.label(22))
            .foregroundColor(.white)
            .tint(.white)
            .multilineTextAlignment(.leading)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(isFileName ? TextInputAutocapitalization.never : nil)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .overlay(Rectangle().stroke(Color.white, lineWidth: 2))
    }
}

private struct InformationWindowContent: View {
    @ObservedObject var state: EditorState
    @State private var offsetText: String
    @State private var soundText: String        // 曲のファイル (mc の sound)
    @State private var backgroundText: String   // 背景ファイル (mc の meta.background)
    @State private var photoItem: PhotosPickerItem? = nil

    init(state: EditorState) {
        self._state = ObservedObject(wrappedValue: state)
        // 開いた最初のフレームから値が入っているように、ここで決める
        self._offsetText = State(initialValue: String(state.chart.offsetMs))
        // mc に名前が書いていないときは、読み込んだファイルの名前を出す
        let sound = state.chart.soundFile
        self._soundText = State(initialValue: sound.isEmpty ? state.oggFileName : sound)
        let bg = state.chart.metaString(["background"])
        self._backgroundText = State(initialValue: bg.isEmpty ? state.bgFileName : bg)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    labeled("曲名") { SideWideField(text: metaBinding(["song", "title"])) }
                    labeled("Original Title") { SideWideField(text: metaBinding(["song", "titleorg"])) }
                    labeled("アーティスト") { SideWideField(text: metaBinding(["song", "artist"])) }
                    labeled("Original Artist") { SideWideField(text: metaBinding(["song", "artistorg"])) }
                    labeled("Version") { SideWideField(text: metaBinding(["version"])) }
                    labeled("Creator") { SideWideField(text: metaBinding(["creator"])) }
                }
                Group {
                    labeled("曲のファイル") { SideWideField(text: $soundText, isFileName: true) }
                    labeled("背景ファイル") {
                        VStack(alignment: .leading, spacing: 8) {
                            SideWideField(text: $backgroundText, isFileName: true)
                            photoButton
                        }
                    }
                    labeled("オフセット (ms)") {
                        HStack(spacing: 8) {
                            SideWideField(text: $offsetText, keyboard: .numbersAndPunctuation)
                            SideSmallButton(title: "-10") { nudgeOffset(-10) }
                            SideSmallButton(title: "+10") { nudgeOffset(10) }
                        }
                    }
                }
                Text(audioInfo)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)
            .padding(.bottom, 35)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxHeight: .infinity)
        // 打っている途中の "-" だけなどは数として読めないので、読めたときだけ反映する (マイナスのオフセットも打てる)
        .onChange(of: offsetText) { text in
            if let v = Int(text.trimmingCharacters(in: .whitespaces)), v != state.chart.offsetMs {
                state.setOffset(v)
            }
        }
        // ファイル名は、打った文字をそのまま mc に書く (空にもできる。空のときは、読み込んだファイルの名前が使われる)
        .onChange(of: soundText) { text in
            if text == state.chart.soundFile { return }
            if text.isEmpty && state.chart.soundEntries.isEmpty { return }   // 無いものを、空の名前で作らない
            state.chart.soundFile = text
            state.metaChanged()
        }
        .onChange(of: backgroundText) { text in
            if text == state.chart.metaString(["background"]) { return }
            state.chart.setMetaString(["background"], text)
            state.metaChanged()
        }
        // 写真を選んだら、背景に入れ替える。変換 (HEIC → JPEG など) は重いので、別スレッドで行う
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            Task {
                let raw = try? await item.loadTransferable(type: Data.self)
                var jpeg: Data? = nil
                if let raw = raw {
                    jpeg = await Task.detached(priority: .userInitiated) {
                        EditorState.backgroundJPEG(fromPhoto: raw)
                    }.value
                }
                let result = jpeg
                await MainActor.run {
                    photoItem = nil
                    if let jpeg = result {
                        if let name = state.applyBackground(jpeg: jpeg) { backgroundText = name }
                    } else {
                        state.showToast("写真を読み込めませんでした")
                    }
                }
            }
        }
    }

    /// 背景ファイルの下の「写真から読み込む」(ファイルアプリではなく、写真アプリから選ぶ)
    private var photoButton: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Text("写真から読み込む")
                .font(PanelFont.label(22))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .overlay(Rectangle().stroke(Color.white, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(SidePressStyle())
    }

    private var audioInfo: String {
        if let a = state.song {
            return "音源読込: \(a.info) / 長さ \(state.timeString(a.duration))"
        }
        return "音源なし (無音で編集中)"
    }

    private func nudgeOffset(_ delta: Int) {
        offsetText = String(state.chart.offsetMs + delta)
    }

    /// 名前を上に、中身を下に (本家: 1 組 89pt おき)
    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(PanelFont.label(22))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 26)
            content()
        }
        .padding(.bottom, 13)
    }

    private func metaBinding(_ path: [String]) -> Binding<String> {
        Binding(
            get: { state.chart.metaString(path) },
            set: { newValue in
                state.chart.setMetaString(path, newValue)
                state.metaChanged()
            }
        )
    }
}

// MARK: - SETTING
//
// 本家に SETTING は無いので、BPM list / Effect list と同じ窓の中に、これまでの項目をそのまま並べている
// (曲の音量 / ノーツサウンドの音量 / 背景画像の暗さ / チェックボックス / 長押しで選択解除)。
// 文字・縁取り・選んでいる色 (panelBlue) は、他の右ウィンドウとそろえた。縦にスクロールできる。
// 窓は、ウィンドウより左 (レーンなど) を触ると閉じる。曲を再生したまま開いて、音量を聞き比べられる。

private struct SideDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1)
    }
}

private struct SettingWindowContent: View {
    @ObservedObject var state: EditorState

    // SwiftUI の VStack は 1 つのブロックに 10 個までしか並べられないので、まとまりごとに分けてある
    var body: some View {
        VStack(spacing: 0) {
            SideTitle(text: "SETTING")

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    volumeRows
                    SideDivider()
                    backgroundRows
                    checkRows
                    SideDivider()
                    holdRow
                    playInfoText
                }
                .padding(.top, 8)
                .padding(.bottom, 35)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// 曲の音量 / ノーツサウンドの音量
    private var volumeRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            sliderRow(title: "曲の音量", text: percent(state.musicVolume),
                      value: $state.musicVolume, range: 0...1, step: 0.05, onEditingChanged: nil)

            sliderRow(title: "ノーツサウンドの音量", text: percent(state.noteVolume),
                      value: $state.noteVolume, range: 0...1, step: 0.05) { editing in
                // 指を離した時に1回鳴らして、音量を確かめられるようにする
                if !editing { KeySound.shared.playNow() }
            }

            note("ノーツサウンドは、再生中にノーツが再生ラインに触れる瞬間と、テストプレイで叩いた瞬間に鳴ります。0% で消せます。")
        }
    }

    /// 背景画像の暗さ (背景画像を読み込んでいるときだけ)
    @ViewBuilder
    private var backgroundRows: some View {
        if state.bgImage != nil {
            VStack(alignment: .leading, spacing: 16) {
                sliderRow(title: "背景画像の暗さ", text: percent(state.bgDim),
                          value: $state.bgDim, range: 0...0.95, step: 0.05, onEditingChanged: nil)
                SideDivider()
            }
        }
    }

    /// チェックボックス 4 つ
    private var checkRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            checkRow(title: "立ち上がりをはっきりさせる (伸ばす窓を小さく)",
                     note: "伸ばした音の、ドラムなどの出だしのにじみが約半分になります (0.1倍で前46ms・後74ms → 前26ms・後36ms)。そのかわり 60Hz付近の低音が少しゆらぎます。次の再生から変わります。",
                     isOn: $state.sharpStretch)

            SideDivider()

            checkRow(title: "beatが時系列順でないsegを置くのを許可する",
                     note: "オフのとき (初期値): 直前に置いた seg (終点) より前の時間には、seg を置けません。Slide ツールでは、そこをタップすると「完」と同じく配置を終えます。Slide modify では、そこをタップすると選択が外れます。seg を縦にドラッグしても、前後の seg の時間を越えません。オンにすると、時間を行ったり来たりする seg や、始点より前 (beat がマイナス) の seg も置けます。",
                     isOn: $state.allowUnorderedSeg)

            SideDivider()

            checkRow(title: "slide modifyでのsegの移動で縦方向の移動を許可する",
                     note: "オフのとき (初期値): Slide modify で seg を動かしても、横 (x) にだけ動きます。時間 (拍) は変わりません。オンにすると、縦にも動かせます (1/n 拍に吸着)。",
                     isOn: $state.allowSegVerticalMove)

            SideDivider()

            checkRow(title: "grid alignがオンの時、グリッド上に常にノーツの中心を合わせる",
                     note: "オンのとき (初期値・本家と同じ): ノーツを動かすと、動かした先でいちばん近いグリッド線に中心が吸着します。置いたときと同じ座標になるので、グリッドに乗っていないノーツを動かして、置いたノーツに重ねても中心が必ずそろいます。スライドは始点と各 seg の中心がそれぞれ吸着します。オフにすると、動かす前の位置から「グリッド1マスの整数倍」だけずらす固定変位になります。",
                     isOn: $state.gridCenterAlign)
        }
    }

    /// 再生開始の下ごしらえの診断 (再生したあとに出る)
    @ViewBuilder
    private var playInfoText: some View {
        if !state.playInfo.isEmpty {
            Text(state.playInfo)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.laneCyan.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 名前と今の値 (水色) を 1 行に、その下にスライダー
    private func sliderRow(title: String, text: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double,
                           onEditingChanged: ((Bool) -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(PanelFont.label(21))
                    .foregroundColor(.white)
                Spacer(minLength: 8)
                Text(text)
                    .font(PanelFont.label(21))
                    .foregroundColor(Color.panelBlue)
            }
            Slider(value: value, in: range, step: step, onEditingChanged: { editing in
                onEditingChanged?(editing)
            })
            .tint(Color.panelBlue)
        }
    }

    /// 長押しで選択解除までの秒数 (1.0〜5.0 秒、0.1 秒刻み。保存される)
    private var holdRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            sliderRow(title: "長押しで選択解除", text: String(format: "%.1f 秒", state.holdDeselectSec),
                      value: $state.holdDeselectSec, range: EditorState.holdRange, step: 0.1,
                      onEditingChanged: nil)
            note("編集ツールを選んでいないとき、レーンを動かさずに押し続けると、選択中のノーツが全部解除されます。")
        }
    }

    /// 白い縁取りの四角 (BPM / Effect の入力欄と同じ線) のチェックボックス。オンのときは水色のチェック
    private func checkRow(title: String, note noteText: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Rectangle()
                            .stroke(isOn.wrappedValue ? Color.panelBlue : Color.white, lineWidth: 2)
                        if isOn.wrappedValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Color.panelBlue)
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(title)
                        .font(PanelFont.label(18))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            note(noteText)
        }
    }
}
