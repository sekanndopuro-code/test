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

    /// 「ファイルを選択…」(拡張子で振り分け) と「mczを展開して読み込む…」で、同じ fileImporter を使い分ける
    private enum ImportMode {
        case files, mcz
    }

    @State private var editor: EditorState? = nil
    @State private var showImporter = false
    @State private var importMode: ImportMode = .files
    @State private var pendingMCZ: MCZUnpacked? = nil   // 譜面が複数入っていた mcz。どれを開くか選んでもらうまで置いておく

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
        // 「ファイル」アプリや共有メニューの「このアプリで開く」で渡された .mc / .mcz を読み込む。
        // 読み込みは「ファイルを選択…」と同じ importFiles を使う (mcz だけなら展開して読み込む)。
        // エディタを開いている最中は、編集中の譜面を守るため無視する (Quit してから開き直す)。
        .onOpenURL { url in
            guard editor == nil else { return }
            importMode = .files
            importFiles([url])
        }
        // mcz に譜面 (.mc) が複数入っていたとき、どれを開くか選ぶ
        .sheet(item: $pendingMCZ) { packed in
            MCZChartPicker(folderName: packed.folder.lastPathComponent, charts: packed.charts) { chart in
                pendingMCZ = nil
                loadFromMCZ(packed, chartName: chart.name)
            } onCancel: {
                pendingMCZ = nil
                message = "展開しました (Documents/MalodySlideEditor/\(packed.folder.lastPathComponent)/)。譜面は選ばれていません"
            }
        }
    }

    private var importView: some View {
        VStack(spacing: 18) {
            Text("Malody Slide Editor")
                .font(.system(size: 30, weight: .bold, design: .monospaced))
            Text("mc・音源・背景画像を、まとめて選んでOK (拡張子で自動判別)")
                .foregroundColor(.secondary)

            Button {
                importMode = .files
                showImporter = true
            } label: {
                Label("ファイルを選択…", systemImage: "folder")
                    .font(.title3.bold())
                    .frame(width: 280, height: 50)
            }
            .buttonStyle(.bordered)

            // mcz を展開して、中の mc・音源・背景画像をまとめて読み込む
            Button {
                importMode = .mcz
                showImporter = true
            } label: {
                Label("mczを展開して読み込む…", systemImage: "archivebox")
                    .font(.title3.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
            if importMode == .mcz {
                importMCZ(from: urls)
            } else {
                importFiles(urls)
            }
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
        var mczs: [URL] = []
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
                mczs.append(url)
            case nil:
                skipped.append(url.lastPathComponent)
            }
        }
        // mcz だけを選んだときは、「mczを展開して読み込む…」と同じ (展開して、中の mc / 音源 / 背景を読み込む)
        if !mczs.isEmpty && mcs.isEmpty && audios.isEmpty && images.isEmpty {
            importMCZ(from: mczs)
            return
        }
        if !mczs.isEmpty {
            notes.append("mcz は mc などと同時には読めないので無視しました。「mczを展開して読み込む…」から、mcz だけ選んでください")
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

    // MARK: - mcz を展開して読み込む

    /// 選んだ mcz を展開して (アプリ内 Documents/MalodySlideEditor/<mcz名>/ に書き出す)、中の mc・音源・背景画像を読み込む。
    /// mc が 1 つならそのまま、複数なら選ぶ画面を出す。
    private func importMCZ(from urls: [URL]) {
        let mczs = urls.filter { Self.kind(of: $0) == .mcz }
        guard let url = mczs.first else {
            message = "mcz ファイルを選んでください"
            return
        }
        var note = ""
        if mczs.count > 1 {
            note = "mcz が \(mczs.count) 個選ばれたので、最初の「\(url.lastPathComponent)」だけ使います"
        }
        let name = url.lastPathComponent
        busy = true
        message = ""
        Task { @MainActor in
            do {
                // 読み込みと展開は重いことがあるので、画面を止めないよう別スレッドで行う
                let packed = try await Task.detached(priority: .userInitiated) { () throws -> MCZUnpacked in
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    return try MCZImporter.unpack(data: data, mczName: name)
                }.value
                busy = false
                if packed.charts.isEmpty {
                    message = "「\(name)」の中に .mc が見つかりませんでした"
                } else if packed.charts.count == 1 {
                    loadFromMCZ(packed, chartName: packed.charts[0].name, extraNote: note)
                } else {
                    message = note
                    pendingMCZ = packed
                }
            } catch {
                busy = false
                message = "「\(name)」を展開できませんでした: \(error.localizedDescription)"
            }
        }
    }

    /// 展開したフォルダの中から、選んだ mc と、その音源・背景画像を読み込む。
    /// mc は展開先のフォルダのものを開く (オートセーブもそこへ書き戻す)。前に選んでいた音源・背景は外す。
    private func loadFromMCZ(_ packed: MCZUnpacked, chartName: String, extraNote: String = "") {
        let mcFile = packed.folder.appendingPathComponent(chartName)
        guard let data = try? Data(contentsOf: mcFile) else {
            message = "\(chartName) を読み込めませんでした"
            return
        }
        let media = pickMedia(chartData: data, among: packed.fileNames)

        if mcScoped, let old = mcURL {
            old.stopAccessingSecurityScopedResource()   // 前に選んでいた mc のアクセス権を閉じる
        }
        mcURL = mcFile
        mcScoped = false                                // アプリ内のファイルなので、アクセス権は要らない
        mcData = data
        mcName = chartName
        oggData = nil
        oggName = ""
        bgData = nil
        bgName = ""

        var notes: [String] = []
        if !extraNote.isEmpty { notes.append(extraNote) }
        if let a = media.audio {
            if let d = try? Data(contentsOf: packed.folder.appendingPathComponent(a)) {
                oggData = d
                oggName = a
            } else {
                notes.append("\(a) を読み込めませんでした")
            }
        } else {
            notes.append("mcz の中に音源が見つかりませんでした (無音で開きます)")
        }
        if let b = media.image {
            if let d = try? Data(contentsOf: packed.folder.appendingPathComponent(b)) {
                bgData = d
                bgName = b
            } else {
                notes.append("\(b) を読み込めませんでした")
            }
        }
        notes.append("展開先: Documents/MalodySlideEditor/\(packed.folder.lastPathComponent)/")
        message = notes.joined(separator: "\n")
    }

    /// 展開したファイルから、この mc の音源と背景画像を決める。
    /// mc に書いてある名前 (音源 = 曲のファイル / 背景 = meta.background) と同じ名前のファイルを優先し、
    /// 無ければ、拡張子で最初に見つかった音源 / 画像にする。
    private func pickMedia(chartData: Data, among names: [String]) -> (audio: String?, image: String?) {
        var wantAudio = ""
        var wantImage = ""
        if let c = try? ChartData.parse(chartData) {
            wantAudio = c.soundFile
            wantImage = c.metaString(["background"])
        }
        func find(_ want: String, _ wanted: FileKind) -> String? {
            let w = (want as NSString).lastPathComponent.lowercased()
            if !w.isEmpty, let m = names.first(where: { $0.lowercased() == w }) { return m }
            return names.first(where: { Self.kind(of: URL(fileURLWithPath: $0)) == wanted })
        }
        return (find(wantAudio, .audio), find(wantImage, .image))
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
                // 曲は、ここで 1 回だけ PCM に展開する (SongPCM)。エディタの再生・テストプレイ・曲の長さは、これを共有する。
                // 重い処理なので、メインスレッドを止めないよう別スレッドで行う (その間は busy の表示)
                var song: SongPCM? = nil
                var note = ""
                if let od = oggData {
                    let name = oggName
                    do {
                        song = try await Task.detached(priority: .userInitiated) {
                            try SongPCM.decode(data: od, fileName: name)
                        }.value
                    } catch {
                        note = "音源を読み込めませんでした(無音で開きます): \(error.localizedDescription)"
                    }
                }
                let st = EditorState(
                    chart: chart, mcURL: url, mcName: mcName, song: song,
                    oggData: oggData, oggFileName: oggName,
                    bgData: bgData, bgFileName: bgName
                )
                st.onClose = { [weak st] in
                    // 写真から入れ替えた背景は、閉じたあとに開き直しても残す
                    if let st = st {
                        bgData = st.bgData
                        bgName = st.bgFileName
                    }
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

/// mcz に譜面 (.mc) が複数入っていたときに、どれを開くか選ぶ画面 (難易度ごとの mc など)
private struct MCZChartPicker: View {
    let folderName: String
    let charts: [MCZUnpacked.ChartFile]
    let onPick: (MCZUnpacked.ChartFile) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List(charts) { chart in
                Button {
                    onPick(chart)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chart.name)
                            .font(.headline)
                        if !chart.label.isEmpty {
                            Text(chart.label)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .navigationTitle("開く譜面を選ぶ (\(folderName))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
