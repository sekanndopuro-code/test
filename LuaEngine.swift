import Foundation
import JavaScriptCore

// Lua プラグインを動かす部分。
// Swift Playgrounds のアプリには Lua 本体 (C 言語) を入れられないので、
// 「Lua → JavaScript 変換器 + Lua 標準ライブラリ」(LuaEngineSource.swift) を JavaScriptCore で動かしている。
//   ・プラグインの実行は、専用の別スレッドで行う (画面は固まらない・「停止」で止められる)
//   ・Editor:〇〇() は PluginBridge 経由でエディタの譜面を操作する

/// プラグインの先頭にある PluginName などの情報
struct PluginInfo {
    var name: String
    var mode: Int?
    var type: Int?
    var require: String
    var hasRun: Bool           // Run() がある (1回実行する型)
    var hasTool: Bool          // OnActive / OnDragMove などがある (操作型。PluginType 2)
    var icon: String           // PluginIcon (プラグインのフォルダにある画像のファイル名)
    var error: String          // 空でなければ、読み込み時のエラー (構文エラーなど)
}

enum PluginRunResult {
    case ok
    case aborted
    case failed(String)
}

final class ExceptionBox {
    var text = ""
}

enum LuaEngine {
    struct InspectInput {
        let id: String
        let name: String
        let source: String
    }

    /// 大きな再帰にも耐えられるよう、スタックを大きくした専用スレッドで動かす
    private static func spawn(_ body: @escaping () -> Void) {
        let t = Thread(block: body)
        t.stackSize = 16 * 1024 * 1024
        t.qualityOfService = .userInitiated
        t.start()
    }

    static func makeContext(bridge: PluginBridge, box: ExceptionBox) -> JSContext? {
        guard let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, value in
            box.text = value?.toString() ?? "JavaScript error"
        }
        let native: @convention(block) (String, String) -> String = { name, args in
            return bridge.handle(name, args)
        }
        ctx.setObject(native, forKeyedSubscript: "__native" as NSString)
        ctx.evaluateScript(LuaEngineSource.js)
        return ctx
    }

    // MARK: - 読み込み時の検査 (PluginName などを読む。譜面には触らない)

    static func inspect(_ inputs: [InspectInput], completion: @escaping ([String: PluginInfo]) -> Void) {
        spawn {
            var out: [String: PluginInfo] = [:]
            let box = ExceptionBox()
            let bridge = PluginBridge(state: nil, pluginName: "")
            // 10秒たっても終わらないとき (トップレベルで無限ループなど) は打ち切る
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                bridge.cancel.cancel()
            }
            if let ctx = makeContext(bridge: bridge, box: box) {
                let host = ctx.objectForKeyedSubscript("LuaHost")
                for input in inputs {
                    box.text = ""
                    let payload: [[String: String]] = [["id": input.id, "name": input.name, "src": input.source]]
                    var info = PluginInfo(name: "", mode: nil, type: nil, require: "", hasRun: false,
                                          hasTool: false, icon: "", error: "検査に失敗しました")
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let json = String(data: data, encoding: .utf8),
                       let res = host?.objectForKeyedSubscript("inspect")?.call(withArguments: [json]),
                       let s = res.toString(),
                       let rd = s.data(using: .utf8),
                       let arr = (try? JSONSerialization.jsonObject(with: rd)) as? [[String: Any]],
                       let item = arr.first {
                        let ok = (item["ok"] as? Bool) ?? false
                        info = PluginInfo(
                            name: (item["name"] as? String) ?? "",
                            mode: (item["mode"] as? NSNumber)?.intValue,
                            type: (item["type"] as? NSNumber)?.intValue,
                            require: (item["require"] as? String) ?? "",
                            hasRun: (item["hasRun"] as? Bool) ?? false,
                            hasTool: (item["hasTool"] as? Bool) ?? false,
                            icon: (item["icon"] as? String) ?? "",
                            error: ok ? "" : ((item["error"] as? String) ?? "エラー"))
                    } else if !box.text.isEmpty {
                        info.error = box.text
                    }
                    out[input.id] = info
                }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    // MARK: - zip の解凍 (プラグインのパッケージ: .lua + 画像)

    struct ZipEntry {
        let name: String       // zip の中のパス (例: "GizaSlide.lua" / "img/grip.png")
        let data: Data
    }

    /// zip を解凍する (別スレッド)。completion には (ファイルの一覧, エラーの説明) を渡す。エラーがなければ説明は空
    static func unzip(_ data: Data, completion: @escaping ([ZipEntry], String) -> Void) {
        spawn {
            var entries: [ZipEntry] = []
            var error = ""
            let box = ExceptionBox()
            let bridge = PluginBridge(state: nil, pluginName: "")
            if let ctx = makeContext(bridge: bridge, box: box) {
                let b64 = data.base64EncodedString()
                let res = ctx.objectForKeyedSubscript("LuaHost")?.objectForKeyedSubscript("unzip")?
                    .call(withArguments: [b64])
                if let s = res?.toString(),
                   let rd = s.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any] {
                    if (obj["ok"] as? Bool) == true {
                        let files = (obj["files"] as? [[String: Any]]) ?? []
                        for f in files {
                            if let n = f["name"] as? String, let b = f["data"] as? String, let bytes = Data(base64Encoded: b) {
                                entries.append(ZipEntry(name: n, data: bytes))
                            }
                        }
                    } else {
                        error = (obj["error"] as? String) ?? "zip を読めませんでした"
                    }
                } else {
                    error = box.text.isEmpty ? "zip を読めませんでした" : box.text
                }
            } else {
                error = "JavaScript エンジンを起動できませんでした"
            }
            DispatchQueue.main.async { completion(entries, error) }
        }
    }

    // MARK: - 実行

    static func run(source: String, name: String, bridge: PluginBridge,
                    completion: @escaping (PluginRunResult) -> Void) {
        spawn {
            let box = ExceptionBox()
            var result = PluginRunResult.failed("JavaScript エンジンを起動できませんでした")
            if let ctx = makeContext(bridge: bridge, box: box) {
                let host = ctx.objectForKeyedSubscript("LuaHost")
                let res = host?.objectForKeyedSubscript("run")?.call(withArguments: [source, name])
                if let s = res?.toString(),
                   let data = s.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if (obj["ok"] as? Bool) == true {
                        result = .ok
                    } else if (obj["aborted"] as? Bool) == true {
                        result = .aborted
                    } else {
                        result = .failed((obj["error"] as? String) ?? "不明なエラー")
                    }
                } else {
                    result = .failed(box.text.isEmpty ? "実行結果を読み取れませんでした" : box.text)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
