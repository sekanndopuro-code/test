import SwiftUI
import UniformTypeIdentifiers

/// 起動画面: mc / 音源 (/ 背景画像) を選んでエディタを開く
///
/// ファイルは「種類ごとの選択ボタン」ではなく、1つのボタンでまとめて選ぶ。
/// 選んだファイルは **拡張子を見て** mc / 音源 / 背景画像に自動で振り分ける
/// (mc だけ・mc と音源だけ・3つ全部、どの組み合わせでも、順番が混ざっていてもよい)。
struct RootView: View {
    private enum FileKind {
        case mc, audio, image, mcz
    }

    /// 音源として扱う拡張子 (ここに無くても、システムが「音声」と判断する拡張子は音源にする)
    private static let audioExts: Set<String> = [
        "ogg", "mp3", "wav", "m4a", "aac", "flac", "aif", "aiff", "caf"
    ]
    /// 背景画像として扱う拡張子 (ここに無くても、システムが「画像」と判断する拡張子は画像にする)
    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "heif", "gif", "bmp", "tif", "tiff"
    ]

    /// 拡張子からファイルの種類を決める。判別できなければ nil
    private static func kind(of url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "mc" { return .mc }
        if ext == "mcz" { return .mcz }
        if audioExts.contains(ext) { return .audio }
        if imageExts.contains(ext) { return .image }
        if !ext.isEmpty, let t = UTType(filenameExtension: ext) {
            if t.conforms(to: .audio) { return .audio }
            if t.conforms(to: .image) { return .image }
        }
        return nil
    }

    @State private var editor: EditorState? = nil
    @State private var showImporter = false

    @State private var mcURL: URL? = nil
    @State private var mcScoped = false       // mcURL のアクセス権を開いたままにしているか
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
                    // ホームバー (画面下の白い横棒) を隠し、下端からの1回目の上スワイプではホームに戻らないようにする。
                    // (下端を触る操作 — ノーツ幅スライダーやレーン下側のドラッグ — で、うっかりホーム画面へ戻るのを防ぐ。
                    //  ホームへ戻るときは、下端から2回スワイプする)
                    .persistentSystemOverlays(.hidden)
                    .defersSystemGestures(on: .bottom)
            } else {
                importView
            }
        }
        // 複数選択OK。選んだものは handle → importFiles で拡張子ごとに振り分ける
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handle(result)
        }
    }

    private var importView: some View {
        VStack(spacing: 18) {
            Text("Malody Slide Editor")
                .font(.system(size: 30, weight: .bold, design: .monospaced))
            Text("mc・音源・背景画像を、まとめて選んでOK (拡張子で自動判別)")
                .foregroundColor(.secondary)

            Button {
                showImporter = true
            } label: {
                Label("ファイルを選択…", systemImage: "folder")
                    .font(.title3.bold())
                    .frame(width: 280, height: 50)
            }
            .buttonStyle(.bordered)

            VStack(spacing: 10) {
                fileRow(title: "譜面 (.mc)", name: mcName, required: true)
                fileRow(title: "音源 (.ogg 等)", name: oggName, required: false)
                fileRow(title: "背景画像 (任意)", name: bgName, required: false)
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

    /// 読み込み状況の表示だけ (選ぶのは上の「ファイルを選択…」ボタン)
    private func fileRow(title: String, name: String, required: Bool) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 150, alignment: .leading)
            Text(name.isEmpty ? (required ? "未選択 (必須)" : "未選択") : name)
                .foregroundColor(name.isEmpty ? .secondary : .green)
                .lineLimit(1)
                .frame(width: 280, alignment: .leading)
        }
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            if (e as? CocoaError)?.code == .userCancelled { return }
            message = "ファイルを開けませんでした: \(e.localizedDescription)"
        case .success(let urls):
            if urls.isEmpty { return }
            importFiles(urls)
        }
    }

    /// セキュリティスコープのアクセス権を開いて読み込み、すぐ閉じる (mc 以外のファイル用)
    private func readOnce(_ url: URL) throws -> Data {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// 選ばれたファイルを、拡張子で mc / 音源 / 背景画像に振り分けて読み込む。
    /// - 今回の選択に **mc が入っている** → 別の譜面に切り替えたものとして、前の音源・背景は引き継がない
    ///   (mc だけ選べば、音源・背景なしで開く。今回いっしょに選んだものだけが付く)
    /// - mc が入っていない → いま選んでいる mc はそのままで、音源 / 背景画像だけ入れ替える (足す) 
    /// - 同じ種類が複数あったときは、最初の 1 つだけ使う
    private func importFiles(_ urls: [URL]) {
        var mcs: [URL] = []
        var audios: [URL] = []
        var images: [URL] = []
        var skipped: [String] = []
        var notes: [String] = []

        for url in urls {
            switch Self.kind(of: url) {
            case .mc?:
                mcs.append(url)
            case .audio?:
                audios.append(url)
            case .image?:
                images.append(url)
            case .mcz?:
                notes.append("\(url.lastPathComponent): mcz は読み込めません。展開した mc / 音源 / 画像を選んでください")
            case nil:
                skipped.append(url.lastPathComponent)
            }
        }
        if !skipped.isEmpty {
            notes.append("種類を判別できなかったので無視しました: " + skipped.joined(separator: ", "))
        }
        for (label, list) in [("mc", mcs), ("音源", audios), ("画像", images)] where list.count > 1 {
            notes.append("\(label)が \(list.count) 個選ばれたので、最初の「\(list[0].lastPathComponent)」だけ使います")
        }

        // mc: オートセーブで書き戻すため、アクセス権は開いたままにする
        if let url = mcs.first {
            let ok = url.startAccessingSecurityScopedResource()
            do {
                let data = try Data(contentsOf: url)
                if mcScoped, let old = mcURL {
                    old.stopAccessingSecurityScopedResource()   // 前に選んでいた mc のアクセス権を閉じる
                }
                mcData = data
                mcURL = url
                mcScoped = ok
                mcName = url.lastPathComponent
                // 別の譜面に切り替えたので、前の音源・背景は外す (今回いっしょに選んだものは、この下で入る)
                oggData = nil
                oggName = ""
                bgData = nil
                bgName = ""
            } catch {
                notes.append("\(url.lastPathComponent) の読込に失敗しました: \(error.localizedDescription)")
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }

        if let url = audios.first {
            do {
                oggData = try readOnce(url)
                oggName = url.lastPathComponent
            } catch {
                notes.append("\(url.lastPathComponent) の読込に失敗しました: \(error.localizedDescription)")
            }
        }

        if let url = images.first {
            do {
                bgData = try readOnce(url)
                bgName = url.lastPathComponent
            } catch {
                notes.append("\(url.lastPathComponent) の読込に失敗しました: \(error.localizedDescription)")
            }
        }

        message = notes.joined(separator: "\n")
    }

    private func openEditor() {
        guard let url = mcURL else { return }
        // 最初に選んだ時点の mcData は、編集前の古い内容。Quit で戻ってきたあとにそれで開き直すと、
        // 編集した内容が消えるうえ、オートセーブ (アプリを離れたときの保存も) で、保存済みのファイルが古い内容で上書きされてしまう。
        // → 開くたびに、ファイルから読み直す (読めなかったときだけ、選んだときの内容を使う)
        guard let data = (try? Data(contentsOf: url)) ?? mcData else { return }
        mcData = data
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
