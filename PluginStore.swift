import Foundation
import SwiftUI

// Adv. メニューに並ぶプラグインの一覧。
//   ・内蔵プラグイン (BuiltinPlugins) は常に先頭に並ぶ
//   ・「プラグイン(lua)を読み込む」で入れたものは、Documents/MalodySlideEditor/Plugins/ に保存される (次回起動時も自動で読み直す)
//       - .lua を選ぶ → Plugins/<ファイル名>/ に保存。一緒に選んだ画像などもそこに入る
//       - .zip を選ぶ → 中身を Plugins/<zip の名前>/ に展開する (.lua と画像など。Malody V のプラグインの配り方)
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

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("MalodySlideEditor", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    private init() {
        var list: [PluginItem] = []
        for e in BuiltinPlugins.all {
            list.append(PluginItem(id: "builtin/" + e.fileName, fileName: e.fileName, source: e.source,
                                   isBuiltin: true, baseDir: nil, relPath: "", info: nil))
        }
        list.append(contentsOf: PluginStore.loadUserItems())
        items = list
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
            .filter { $0.info == nil }
            .map { LuaEngine.InspectInput(id: $0.id, name: $0.fileName, source: $0.source) }
        if todo.isEmpty { return }
        LuaEngine.inspect(todo) { [weak self] result in
            guard let self = self else { return }
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

    /// 選んだファイル (.lua / .zip / 画像など) を取り込む。検査に通ったプラグインだけ一覧に加えて、アプリ内に保存する。
    /// completion には、結果の説明文 (画面に出す) を渡す
    func importFiles(_ urls: [URL], completion: @escaping (String) -> Void) {
        var luaFiles: [ImportFile] = []
        var otherFiles: [ImportFile] = []
        var zipFiles: [ImportFile] = []
        var problems: [String] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
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

        // 取り込むファイルの束: (フォルダ名, 中のファイル)
        var packages: [(folder: String, files: [(path: String, data: Data)])] = []
        if !luaFiles.isEmpty {
            // .lua を直接選んだとき: 最初の .lua の名前のフォルダに、選んだ .lua と画像などをまとめて入れる
            var files: [(path: String, data: Data)] = []
            for f in luaFiles { files.append((path: f.name, data: f.data)) }
            for f in otherFiles { files.append((path: f.name, data: f.data)) }
            let folder = PluginStore.safeName((luaFiles[0].name as NSString).deletingPathExtension)
            packages.append((folder: folder, files: files))
        } else if !otherFiles.isEmpty && zipFiles.isEmpty {
            problems.append("lua ファイルが選ばれていません (画像だけは追加できません)")
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
