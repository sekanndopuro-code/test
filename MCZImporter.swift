import Foundation

/// 展開し終わった mcz。中身は、アプリ内の Documents/MalodySlideEditor/<mcz の名前>/ に書き出してある
/// (Files アプリの「このiPad内 > (アプリ名)」から見える)。
struct MCZUnpacked: Identifiable {
    /// mcz に入っていた譜面 (.mc) 1 つぶん
    struct ChartFile: Identifiable {
        let name: String        // mc のファイル名
        let label: String       // 選ぶ画面に出す補足 (Version / Creator)
        var id: String { name }
    }

    let folder: URL             // 展開先のフォルダ
    let fileNames: [String]     // 展開したファイル名 (フォルダ階層は取り除いてある)
    let charts: [ChartFile]     // その中の .mc (名前順)
    var id: String { folder.path }
}

enum MCZImporter {
    /// mcz (zip) を展開して、アプリ内の新しいフォルダに全部書き出す。
    /// - すでに同じ名前のフォルダがあるときは「名前 2」「名前 3」… にする (前に編集した mc を上書きしないため)
    /// - zip の中のフォルダ階層は取り除いて、ファイルを 1 つのフォルダに並べる (同じ名前のファイルは最初の 1 つだけ)
    /// - `__MACOSX` や `._` で始まるファイルは無視する
    static func unpack(data: Data, mczName: String) throws -> MCZUnpacked {
        let zip = try ZipReader(data: data)
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("MalodySlideEditor", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let base = (mczName as NSString).deletingPathExtension
        let folder = uniqueFolder(in: root, base: base)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)

        var names: [String] = []
        var mcBytes: [String: Data] = [:]
        do {
            for e in zip.entries where !e.isDirectory {
                let parts = e.name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { String($0) }
                guard let leaf = parts.last, !leaf.isEmpty, leaf != ".", leaf != ".." else { continue }
                if parts.contains("__MACOSX") || leaf.hasPrefix("._") || leaf == ".DS_Store" { continue }
                if names.contains(leaf) { continue }
                let bytes = try zip.extract(e)
                try bytes.write(to: folder.appendingPathComponent(leaf), options: .atomic)
                names.append(leaf)
                if (leaf as NSString).pathExtension.lowercased() == "mc" { mcBytes[leaf] = bytes }
            }
        } catch {
            try? fm.removeItem(at: folder)      // 途中で失敗したら、書きかけのフォルダは残さない
            throw error
        }

        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        let charts = mcBytes.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { MCZUnpacked.ChartFile(name: $0, label: label(of: mcBytes[$0] ?? Data())) }
        return MCZUnpacked(folder: folder, fileNames: names, charts: charts)
    }

    /// 譜面を選ぶ画面に出す補足。meta の version と creator
    private static func label(of data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["meta"] as? [String: Any] else { return "" }
        var parts: [String] = []
        if let v = meta["version"] as? String, !v.isEmpty { parts.append(v) }
        if let c = meta["creator"] as? String, !c.isEmpty { parts.append("by \(c)") }
        return parts.joined(separator: "  ")
    }

    private static func uniqueFolder(in root: URL, base: String) -> URL {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var b = base.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty || b == "." || b == ".." { b = "mcz" }
        var url = root.appendingPathComponent(b, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(b) \(n)", isDirectory: true)
            n += 1
        }
        return url
    }
}
