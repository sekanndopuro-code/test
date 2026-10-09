import SwiftUI
import UniformTypeIdentifiers

/// 起動画面: mc / ogg (/ 背景画像) を選んでエディタを開く
struct RootView: View {
    private enum PickTarget {
        case mc, ogg, bg
    }

    @State private var editor: EditorState? = nil
    @State private var showImporter = false
    @State private var target: PickTarget = .mc

    @State private var mcURL: URL? = nil
    @State private var mcData: Data? = nil
    @State private var mcName = ""
    @State private var oggData: Data? = nil
    @State private var oggName = ""
    @State private var bgData: Data? = nil
    @State private var bgName = ""

    @State private var busy = false
    @State private var message = ""

    var body: some View {
        ZStack {
            if let st = editor {
                EditorView(state: st)
                    // 本家と同じく、画面の下端 (ホームインジケータの下) までUIを続ける
                    .ignoresSafeArea(.container, edges: [.top, .leading, .trailing, .bottom])
            } else {
                importView
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            handle(result)
        }
    }

    private var importView: some View {
        VStack(spacing: 18) {
            Text("Malody Slide Editor")
                .font(.system(size: 30, weight: .bold, design: .monospaced))
            Text("mc と ogg を読み込んでから編集に入ります")
                .foregroundColor(.secondary)

            fileRow(title: "譜面 (.mc)", name: mcName, required: true) {
                target = .mc
                showImporter = true
            }
            fileRow(title: "音源 (.ogg)", name: oggName, required: false) {
                target = .ogg
                showImporter = true
            }
            fileRow(title: "背景画像 (任意)", name: bgName, required: false) {
                target = .bg
                showImporter = true
            }

            Button {
                openEditor()
            } label: {
                Text(busy ? "読み込み中…" : "エディタを開く")
                    .font(.title3.bold())
                    .frame(width: 280, height: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mcData == nil || busy)

            if busy { ProgressView() }
            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .frame(maxWidth: 520)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func fileRow(title: String, name: String, required: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Text(title).frame(width: 130, alignment: .leading)
            Text(name.isEmpty ? (required ? "未選択 (必須)" : "未選択") : name)
                .foregroundColor(name.isEmpty ? .secondary : .green)
                .lineLimit(1)
                .frame(width: 280, alignment: .leading)
            Button("選択…", action: action).buttonStyle(.bordered)
        }
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            message = "ファイルを開けませんでした: \(e.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let ok = url.startAccessingSecurityScopedResource()
            do {
                let data = try Data(contentsOf: url)
                switch target {
                case .mc:
                    mcData = data
                    mcURL = url           // オートセーブで書き戻すため、アクセス権は開いたままにする
                    mcName = url.lastPathComponent
                case .ogg:
                    oggData = data
                    oggName = url.lastPathComponent
                    if ok { url.stopAccessingSecurityScopedResource() }
                case .bg:
                    bgData = data
                    bgName = url.lastPathComponent
                    if ok { url.stopAccessingSecurityScopedResource() }
                }
                message = ""
            } catch {
                message = "読込に失敗しました: \(error.localizedDescription)"
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private func openEditor() {
        guard let data = mcData, let url = mcURL else { return }
        busy = true
        message = ""
        Task { @MainActor in
            do {
                let chart = try ChartData.parse(data)
                var audio: AudioController? = nil
                var note = ""
                if let od = oggData {
                    let a = AudioController()
                    do {
                        try await a.load(data: od, fileName: oggName)
                        audio = a
                    } catch {
                        note = "音源を読み込めませんでした(無音で開きます): \(error.localizedDescription)"
                    }
                }
                let st = EditorState(
                    chart: chart, mcURL: url, mcName: mcName, audio: audio,
                    oggData: oggData, oggFileName: oggName,
                    bgData: bgData, bgFileName: bgName
                )
                st.onClose = {
                    editor = nil
                }
                if !note.isEmpty { st.showToast(note) }
                editor = st
                busy = false
            } catch {
                busy = false
                message = "mc を解析できませんでした。JSON形式の .mc を選んでください。"
            }
        }
    }
}
