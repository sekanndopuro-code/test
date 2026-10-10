import SwiftUI

// Adv. メニュー。
//   ・EDIT 中の右パネルにある「Adv.」を押すと開く。レーンは右端を固定したまま、左端が右へ動いて横に縮み、
//     再生ボタン(シークバー)とレーンの間にこのメニューが現れる
//   ・プラグインは縦にスクロールして並ぶ。押すとそのプラグインの Run() を実行する
//   ・一番下の「プラグイン(lua)を読み込む」で、.lua ファイルを追加できる (複数選択可・次回起動時も残る)

struct AdvPanel: View {
    /// メニューを開いたときの幅 (レーンはこの分だけ細くなる)
    static let width: CGFloat = 196

    @ObservedObject var state: EditorState
    @ObservedObject private var store = PluginStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    ForEach(store.items) { item in
                        row(item)
                    }
                }
                .padding(8)
            }
            if !state.pluginLog.isEmpty {
                logView
            }
            Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
            importButton
        }
        .frame(width: AdvPanel.width)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.06))
        .overlay(Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1), alignment: .trailing)
        .onChange(of: state.advOpen) { open in
            if open { store.reload() }      // Files アプリで Plugins フォルダをいじったあと、開いたときに読み直す
        }
    }

    // MARK: - 部品

    private var header: some View {
        HStack(spacing: 6) {
            Text("Adv.")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Color.laneCyan)
            Text("Lua plugins")
                .font(.system(size: 9))
                .foregroundColor(Color.white.opacity(0.5))
            Spacer(minLength: 0)
            if state.pluginRunning {
                ProgressView()
                    .scaleEffect(0.6)
                Button {
                    state.stopPlugin()
                } label: {
                    Text("停止")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.red.opacity(0.7)))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { state.advOpen = false }
                } label: {
                    Text("✕")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }

    @ViewBuilder
    private func row(_ item: PluginItem) -> some View {
        let isActive = state.activePluginID == item.id
        // 操作型は、実行中のプラグイン (Run) が無ければ、いつでも ON/OFF できる。Run 型は、何も実行していないときだけ
        let runnable = item.isRunnable && !state.pluginRunning
        Button {
            if item.isInteractive {
                state.toggleInteractivePlugin(item)
            } else {
                state.runPlugin(item)
            }
        } label: {
            HStack(spacing: 8) {
                if let name = item.info?.icon, !name.isEmpty,
                   let ui = PluginImageCache.shared.image(dir: item.baseDir, name: name) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(item.hasError ? Color.red.opacity(0.9) : Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.subtitle)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.5))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isActive {
                    Text("ON")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.laneCyan))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(isActive ? Color.laneCyan.opacity(0.18) : Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isActive ? Color.laneCyan : Color.white.opacity(0.25), lineWidth: isActive ? 2 : 1))
            .opacity(runnable || item.info == nil ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!runnable)
        .contextMenu {
            if !item.isBuiltin {
                Button(role: .destructive) {
                    store.remove(item)
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("出力")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.55))
                Spacer()
                Button {
                    state.pluginLog = ""
                } label: {
                    Text("消す")
                        .font(.system(size: 9))
                        .foregroundColor(Color.laneCyan)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.vertical) {
                Text(state.pluginLog)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 72)
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
    }

    private var importButton: some View {
        Button {
            openFilePicker()
        } label: {
            Text("プラグイン(lua)を読み込む")
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(Color.laneCyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.laneCyan, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(state.pluginRunning)
        .padding(8)
    }

    /// 「ファイル」アプリを開いて、プラグイン (.lua / .zip / 画像) を選ばせる
    private func openFilePicker() {
        PluginFilePicker.present { urls in
            if urls.isEmpty { return }
            store.importFiles(urls) { summary in
                state.pluginDialog = PluginDialog(kind: .message, title: "プラグインの読み込み", message: summary)
            }
        }
    }
}

// MARK: - プラグインが出すダイアログ (ShowMessage / GetUserInput / エラー表示)

/// 画面全体の上に重ねる。出ている間はほかの操作を受けない (プラグインはここで答えを待っている)
struct PluginDialogLayer: View {
    @ObservedObject var state: EditorState

    var body: some View {
        if let d = state.pluginDialog {
            PluginDialogCard(state: state, dialog: d)
                .id(d.id)
        }
    }
}

struct PluginDialogCard: View {
    @ObservedObject var state: EditorState
    let dialog: PluginDialog
    @State private var text: String
    @FocusState private var focused: Bool

    init(state: EditorState, dialog: PluginDialog) {
        _state = ObservedObject(wrappedValue: state)
        self.dialog = dialog
        _text = State(initialValue: dialog.defaultText)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(spacing: 12) {
                Text(dialog.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.laneCyan)
                    .multilineTextAlignment(.center)
                if !dialog.message.isEmpty {
                    ScrollView(.vertical) {
                        Text(dialog.message)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                }
                if dialog.kind == .input {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { state.resolvePluginDialog(text) }
                        .onAppear { focused = true }
                }
                HStack(spacing: 12) {
                    if dialog.kind == .input {
                        Button("キャンセル") { state.resolvePluginDialog(nil) }
                            .buttonStyle(.bordered)
                    }
                    Button("OK") {
                        state.resolvePluginDialog(dialog.kind == .input ? text : "")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.35), lineWidth: 1))
            .padding(.top, 24)
            .padding(.horizontal, 16)
        }
    }
}
