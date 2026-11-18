import Foundation
import SwiftUI
import UIKit

// Adv. メニューに並ぶプラグインの一覧。
//   ・内蔵プラグイン (BuiltinPlugins) は常に先頭に並ぶ
//   ・「プラグイン(lua)を読み込む」で入れたものは、Documents/Plugins/ に保存される (次回起動時も自動で読み直す)
//       - Info.plist に UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace を入れると、Files アプリの「このiPad内 > (アプリ名) > Plugins」に見える。
//         Files アプリで .lua / フォルダを入れたり消したりしたら、アプリに戻ったとき・Adv. を開いたときに一覧を読み直す (reload)
//       - .lua を選ぶ → Plugins/<ファイル名>/ に保存。一緒に選んだ画像などもそこに入る
//       - .zip を選ぶ → 中身を Plugins/<zip の名前>/ に展開する (.lua と画像など。Malody V のプラグインの配り方)
//       - フォルダを選ぶ → 中の .lua / .zip / 画像 (サブフォルダも) を、フォルダの並びのまま Plugins/<フォルダ名>/ に入れる
//       - 画像だけを選ぶ → Plugins/ の直下に入れる。どのプラグインからも探せる共通の置き場 (PluginImageCache が、.lua のフォルダに無いときここまで探す)
//       - プラグインが読む画像 (AddSprite の画像・PluginIcon) は、その .lua と同じフォルダから探す
//   ・読み込むときと起動時に、プラグインのトップレベルを一度実行して PluginName などの情報を取り出す (譜面には触らない)

struct PluginItem: Identifiable {
    let id: String             // "builtin/ファイル名" または "user/<Plugins フォルダからの相対パス>"
    var fileName: String
    var source: String
    var isBuiltin: Bool
    var baseDir: URL?          // この .lua があるフォルダ (画像はここから探す)。内蔵は nil
    var relPath: String        // Plugins フォルダからの相対パス。内蔵は ""
    var info: PluginInfo?      // nil = 検査中

    var title: String {
        if let n = info?.name, !n.isEmpty { return n }
        return (fileName as NSString).deletingPathExtension
    }

    var subtitle: String {
        guard let i = info else { return "読み込み中…" }
        if !i.error.isEmpty { return "エラー: " + i.error }
        var parts: [String] = []
        if isInteractive { parts.append("操作型") }
        if let m = i.mode { parts.append("mode \(m)") }
        if !i.require.isEmpty { parts.append("v" + i.require) }
        parts.append(fileName)
        return parts.joined(separator: " · ")
    }

    /// 押して使える状態か (検査が済んでいて、エラーがなく、Run() か OnActive などがある)
    var isRunnable: Bool {
        guard let i = info else { return false }
        return i.error.isEmpty && (i.hasRun || i.hasTool)
    }

    /// 操作型 (PluginType 2): 押すと「アクティブ」になり、レーンのタッチを受け取る。もう一度押すと終わる
    var isInteractive: Bool {
        guard let i = info else { return false }
        return i.hasTool && (i.type == 2 || !i.hasRun)
    }

    var hasError: Bool {
        guard let i = info else { return false }
        return !i.error.isEmpty
    }
}

final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    @Published private(set) var items: [PluginItem] = []

    /// プラグインの置き場所。Files アプリの「(アプリ名)」の直下に「Plugins」が見えるよう、Documents の直下に置く
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Plugins", isDirectory: true)
    }

    /// 前の版の置き場所 (Documents/MalodySlideEditor/Plugins)
    private static var legacyDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("MalodySlideEditor", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    /// 前の版の置き場所に入れてあったプラグインを、新しい置き場所へ移す (同じ名前が新しい方にあるときは、そちらを残す)
    private static func migrateLegacyDirectory() {
        let fm = FileManager.default
        let old = legacyDirectory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        for name in names {
            let dst = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.moveItem(at: old.appendingPathComponent(name), to: dst)
        }
        if let rest = try? fm.contentsOfDirectory(atPath: old.path), rest.isEmpty {
            try? fm.removeItem(at: old)
        }
    }

    /// 検査中のプラグインの id (同じものを二重に検査しないため)
    private var inspecting = Set<String>()

    private init() {
        PluginStore.migrateLegacyDirectory()
        var list: [PluginItem] = []
        for e in BuiltinPlugins.all {
            list.append(PluginItem(id: "builtin/" + e.fileName, fileName: e.fileName, source: e.source,
                                   isBuiltin: true, baseDir: nil, relPath: "", info: nil))
        }
        list.append(contentsOf: PluginStore.loadUserItems())
        items = list
        inspectPending()
        // Files アプリで Plugins フォルダをいじって戻ってきたとき、一覧を読み直す
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    /// Plugins フォルダの中身を読み直す (Files アプリで .lua やフォルダを足した / 消したあと)。
    /// 内蔵プラグインはそのまま。中身が変わっていないものは、検査の結果を使い回す (毎回 Lua を動かさない)
    func reload() {
        PluginImageCache.shared.reset()         // 画像を Files アプリで足した / 消したあとに、読み直せるように
        var old: [String: PluginItem] = [:]
        for it in items where !it.isBuiltin { old[it.id] = it }
        var user: [PluginItem] = []
        for var f in PluginStore.loadUserItems() {
            if let o = old[f.id], o.source == f.source { f.info = o.info }
            user.append(f)
        }
        items = items.filter { $0.isBuiltin } + user
        inspectPending()
    }

    // MARK: - 読み込み

    /// 文字コードは UTF-8 を基本に、だめなら Shift_JIS → Latin-1 の順に試す
    static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        if let s = String(data: data, encoding: .shiftJIS) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Plugins フォルダからの相対パス
    static func relPath(of url: URL) -> String {
        let base = directory.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        if p.hasPrefix(base) { return String(p.dropFirst(base.count)) }
        return url.lastPathComponent
    }

    /// フォルダ (の中のフォルダも) に .lua が1つでもあるか
    static func containsLua(_ folder: URL) -> Bool {
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        for case let u as URL in en {
            if u.pathExtension.lowercased() == "lua" { return true }
        }
        return false
    }

    /// フォルダ名に使えない文字を直す
    static func safeName(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "/\\:*?\"<>|".contains(ch) {
                out.append("_")
            } else {
                out.append(ch)
            }
        }
        let t = out.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "plugin" : t
    }

    private static func loadUserItems() -> [PluginItem] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let u as URL in en {
            if u.pathExtension.lowercased() == "lua" { urls.append(u) }
        }
        urls.sort { relPath(of: $0).localizedCaseInsensitiveCompare(relPath(of: $1)) == .orderedAscending }
        var out: [PluginItem] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url), let src = decode(data) else { continue }
            let rel = relPath(of: url)
            out.append(PluginItem(id: "user/" + rel, fileName: url.lastPathComponent, source: src, isBuiltin: false,
                                  baseDir: url.deletingLastPathComponent(), relPath: rel, info: nil))
        }
        return out
    }

    /// 検査が済んでいないプラグインの PluginName などを読む (別スレッド)
    private func inspectPending() {
        let todo = items
            .filter { $0.info == nil && !inspecting.contains($0.id) }
            .map { LuaEngine.InspectInput(id: $0.id, name: $0.fileName, source: $0.source) }
        if todo.isEmpty { return }
        for t in todo { inspecting.insert(t.id) }
        LuaEngine.inspect(todo) { [weak self] result in
            guard let self = self else { return }
            for t in todo { self.inspecting.remove(t.id) }
            for (id, info) in result {
                if let i = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[i].info = info
                }
            }
        }
    }

    // MARK: - 追加

    private struct ImportFile {
        let name: String
        let data: Data
    }

    /// フォルダを選んだときに読む、画像の拡張子
    private static let folderImageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff"]
    /// フォルダ 1 つから読むファイルの数の上限 (間違えて大きなフォルダを選んでも固まらないように)
    private static let folderFileLimit = 300

    /// フォルダの中 (サブフォルダも) の .lua / .zip / 画像を読む。files の path は、フォルダの中での相対パス
    private static func readFolder(_ folder: URL) -> (files: [(path: String, data: Data)], zips: [ImportFile], problems: [String]) {
        var files: [(path: String, data: Data)] = []
        var zips: [ImportFile] = []
        var problems: [String] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return (files, zips, [folder.lastPathComponent + ": 開けませんでした"])
        }
        let base = folder.standardizedFileURL.path + "/"
        var count = 0
        for case let u as URL in en {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { continue }
            let ext = u.pathExtension.lowercased()
            if ext != "lua" && ext != "zip" && !folderImageExts.contains(ext) { continue }
            if count >= folderFileLimit {
                problems.append(folder.lastPathComponent + ": ファイルが多いので、途中の \(folderFileLimit) 個までにしました")
                break
            }
            guard let data = try? Data(contentsOf: u) else {
                problems.append(u.lastPathComponent + ": 読み込めませんでした")
                continue
            }
            count += 1
            if ext == "zip" {
                zips.append(ImportFile(name: u.lastPathComponent, data: data))
                continue
            }
            let p = u.standardizedFileURL.path
            let rel = p.hasPrefix(base) ? String(p.dropFirst(base.count)) : u.lastPathComponent
            files.append((path: rel, data: data))
        }
        return (files, zips, problems)
    }

    /// 選んだファイル / フォルダ (.lua / .zip / 画像など) を取り込む。検査に通ったプラグインだけ一覧に加えて、アプリ内に保存する。
    ///   ・.lua と画像を一緒に選んだ → 最初の .lua の名前のフォルダに、まとめて入れる
    ///   ・フォルダを選んだ → 中身をフォルダの並びのまま、そのフォルダ名の下に入れる
    ///   ・画像だけを選んだ → Plugins フォルダの直下に入れる (どのプラグインからも使える)。.lua を先に入れて、画像をあとから足してもよい
    /// completion には、結果の説明文 (画面に出す) を渡す
    func importFiles(_ urls: [URL], completion: @escaping (String) -> Void) {
        var luaFiles: [ImportFile] = []
        var otherFiles: [ImportFile] = []
        var zipFiles: [ImportFile] = []
        var folderPackages: [(folder: String, files: [(path: String, data: Data)])] = []
        var problems: [String] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                // フォルダ: 中の .lua / 画像を 1 つの束にする。中の .zip は、選んだ zip と同じように展開する
                let r = PluginStore.readFolder(url)
                if !r.files.isEmpty {
                    folderPackages.append((folder: PluginStore.safeName(url.lastPathComponent), files: r.files))
                }
                zipFiles.append(contentsOf: r.zips)
                problems.append(contentsOf: r.problems)
                if r.files.isEmpty && r.zips.isEmpty && r.problems.isEmpty {
                    problems.append(url.lastPathComponent + ": .lua も画像も見つかりませんでした")
                }
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                problems.append(url.lastPathComponent + ": 読み込めませんでした")
                continue
            }
            let name = url.lastPathComponent
            switch (name as NSString).pathExtension.lowercased() {
            case "lua": luaFiles.append(ImportFile(name: name, data: data))
            case "zip": zipFiles.append(ImportFile(name: name, data: data))
            default: otherFiles.append(ImportFile(name: name, data: data))
            }
        }

        // 画像 (など) だけを選んだとき: プラグインのフォルダが決まらないので、Plugins フォルダの直下に入れる。
        // PluginImageCache は、.lua のフォルダに画像が無ければ、ここまで探す
        if luaFiles.isEmpty && zipFiles.isEmpty && folderPackages.isEmpty && !otherFiles.isEmpty {
            let fm = FileManager.default
            try? fm.createDirectory(at: PluginStore.directory, withIntermediateDirectories: true)
            var saved: [String] = []
            for f in otherFiles {
                let dest = PluginStore.directory.appendingPathComponent(PluginStore.safeName(f.name))
                do {
                    try f.data.write(to: dest, options: .atomic)
                    saved.append(f.name)
                } catch {
                    problems.append(f.name + ": 保存できませんでした")
                }
            }
            PluginImageCache.shared.reset()
            var lines: [String] = []
            if !saved.isEmpty {
                lines.append("画像を追加しました (どのプラグインからも使えます):")
                for s in saved { lines.append("・" + s) }
            }
            if !problems.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("追加できなかったファイル:")
                for p in problems { lines.append("・" + p) }
            }
            completion(lines.isEmpty ? "追加するファイルがありません" : lines.joined(separator: "\n"))
            return
        }

        // 取り込むファイルの束: (フォルダ名, 中のファイル)
        var packages: [(folder: String, files: [(path: String, data: Data)])] = folderPackages
        if !luaFiles.isEmpty {
            // .lua を直接選んだとき: 最初の .lua の名前のフォルダに、選んだ .lua と画像などをまとめて入れる
            var files: [(path: String, data: Data)] = []
            for f in luaFiles { files.append((path: f.name, data: f.data)) }
            for f in otherFiles { files.append((path: f.name, data: f.data)) }
            let folder = PluginStore.safeName((luaFiles[0].name as NSString).deletingPathExtension)
            packages.append((folder: folder, files: files))
        }

        // zip は1つずつ解凍する (別スレッド)
        func unzipNext(_ i: Int) {
            if i >= zipFiles.count {
                self.install(packages, problems: problems, completion: completion)
                return
            }
            let zipName = zipFiles[i].name
            LuaEngine.unzip(zipFiles[i].data) { entries, err in
                if !err.isEmpty {
                    problems.append(zipName + ": " + err)
                } else {
                    var files: [(path: String, data: Data)] = []
                    for e in entries { files.append((path: e.name, data: e.data)) }
                    let folder = PluginStore.safeName((zipName as NSString).deletingPathExtension)
                    packages.append((folder: folder, files: files))
                }
                unzipNext(i + 1)
            }
        }
        unzipNext(0)
    }

    /// 取り込むファイルを Plugins フォルダに書き出して、.lua を検査して、一覧に加える
    private func install(_ packages: [(folder: String, files: [(path: String, data: Data)])],
                         problems initialProblems: [String], completion: @escaping (String) -> Void) {
        let fm = FileManager.default
        var problems = initialProblems
        var folders: [URL] = []
        var luaURLs: [URL] = []
        try? fm.createDirectory(at: PluginStore.directory, withIntermediateDirectories: true)

        for pkg in packages {
            let folderURL = PluginStore.directory.appendingPathComponent(pkg.folder, isDirectory: true)
            try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            folders.append(folderURL)
            for f in pkg.files {
                let parts = f.path.split(separator: "/").map { String($0) }.filter { $0 != "." && !$0.isEmpty }
                if parts.isEmpty || parts.contains("..") {
                    problems.append(f.path + ": 不正なファイル名です")
                    continue
                }
                var dir = folderURL
                for p in parts.dropLast() {
                    dir = dir.appendingPathComponent(p, isDirectory: true)
                }
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(parts[parts.count - 1])
                do {
                    try f.data.write(to: dest, options: .atomic)
                } catch {
                    problems.append(f.path + ": 保存できませんでした")
                    continue
                }
                if dest.pathExtension.lowercased() == "lua" { luaURLs.append(dest) }
            }
        }

        PluginImageCache.shared.reset()         // 画像が増えた / 入れ替わったので、覚えている画像と「見つからなかった」記録を捨てる

        var candidates: [PluginItem] = []
        for url in luaURLs {
            guard let data = try? Data(contentsOf: url), let src = PluginStore.decode(data) else {
                problems.append(url.lastPathComponent + ": 読み込めませんでした")
                try? fm.removeItem(at: url)
                continue
            }
            let rel = PluginStore.relPath(of: url)
            candidates.append(PluginItem(id: "user/" + rel, fileName: url.lastPathComponent, source: src,
                                         isBuiltin: false, baseDir: url.deletingLastPathComponent(), relPath: rel, info: nil))
        }

        if candidates.isEmpty {
            for f in folders where !PluginStore.containsLua(f) {
                try? fm.removeItem(at: f)
            }
            if problems.isEmpty { problems.append("lua ファイルがありません") }
            completion(PluginStore.summary(added: [], failed: problems))
            return
        }

        let inputs = candidates.map { LuaEngine.InspectInput(id: $0.id, name: $0.fileName, source: $0.source) }
        let allProblems = problems
        LuaEngine.inspect(inputs) { [weak self] result in
            guard let self = self else { return }
            var added: [String] = []
            var probs = allProblems
            for var item in candidates {
                let url = PluginStore.directory.appendingPathComponent(item.relPath)
                guard let info = result[item.id] else {
                    probs.append(item.fileName + ": 検査に失敗しました")
                    try? fm.removeItem(at: url)
                    continue
                }
                if !info.error.isEmpty {
                    probs.append(item.fileName + ": " + info.error)
                    try? fm.removeItem(at: url)
                    continue
                }
                if !info.hasRun && !info.hasTool {
                    probs.append(item.fileName + ": Run() も OnActive() もありません")
                    try? fm.removeItem(at: url)
                    continue
                }
                item.info = info
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[idx] = item
                } else {
                    self.items.append(item)
                }
                added.append(item.title)
            }
            for f in folders where !PluginStore.containsLua(f) {
                try? fm.removeItem(at: f)
            }
            self.sortUserItems()
            completion(PluginStore.summary(added: added, failed: probs))
        }
    }

    private static func summary(added: [String], failed: [String]) -> String {
        var lines: [String] = []
        if !added.isEmpty {
            lines.append("追加しました:")
            for a in added { lines.append("・" + a) }
        }
        if !failed.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("追加できなかったファイル:")
            for f in failed { lines.append("・" + f) }
        }
        if lines.isEmpty { lines.append("追加するファイルがありません") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 削除

    func remove(_ item: PluginItem) {
        guard !item.isBuiltin else { return }
        let fm = FileManager.default
        let url = PluginStore.directory.appendingPathComponent(item.relPath)
        try? fm.removeItem(at: url)
        items.removeAll { $0.id == item.id }
        // そのフォルダに .lua がもう無ければ、画像などごと消す (Plugins フォルダそのものは消さない)
        let folder = url.deletingLastPathComponent()
        let root = PluginStore.directory.standardizedFileURL.path
        if folder.standardizedFileURL.path != root && !PluginStore.containsLua(folder) {
            try? fm.removeItem(at: folder)
        }
    }

    /// 内蔵プラグインは先頭のまま、読み込んだものは名前順に並べ直す
    private func sortUserItems() {
        let builtin = items.filter { $0.isBuiltin }
        let user = items
            .filter { !$0.isBuiltin }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        items = builtin + user
    }
}
