import SwiftUI

// META (Back / Information / More / Quit) は、シートをやめて右ボタン列 + 右ウィンドウになった。
// 列の動きは EditorState+Meta.swift、Information の窓は SideWindow.swift (InformationWindowContent)。
// このファイルには、拍の入力 (Beat.parse) だけが残っている。

extension String {
    /// 数や拍の入力欄の文字を、半角の `0-9 : / - . +` にそろえる (空白は全部取る)。
    /// 全角の数字・記号 (０-９ ： ／ ． ＋) と、いろいろなマイナス記号 (－ − ‐ ‑ ‒ – — ー ｰ) を、半角に直す。
    /// 日本語キーボードだと、マイナスが半角の「-」とは別の文字で入ることがあるため
    var normalizedForNumberInput: String {
        var out = String.UnicodeScalarView()
        for u in unicodeScalars {
            switch u.value {
            case 0xFF10...0xFF19:                                   // ０-９
                out.append(Unicode.Scalar(u.value - 0xFF10 + 0x30)!)
            case 0xFF0D, 0x2212, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x30FC, 0xFF70:   // マイナス / ハイフン / ダッシュ / 長音
                out.append("-")
            case 0xFF0B:                                            // ＋
                out.append("+")
            case 0xFF1A:                                            // ：
                out.append(":")
            case 0xFF0F:                                            // ／
                out.append("/")
            case 0xFF0E:                                            // ．
                out.append(".")
            default:
                if !u.properties.isWhitespace { out.append(u) }
            }
        }
        return String(out)
    }
}

extension Beat {
    /// "8:0/4" / "8" 形式を解釈 (0拍始まり)。
    /// マイナスをつけられるのは整数部だけ (値は 整数部 + 分子/分母。本家 Malody と同じ決まり):
    ///   "-50:0/1" = -50 拍 / "-1:1/4" = -0.75 拍 は OK。
    ///   "0:-1/4" (分子がマイナス) と "0:1/-4" (分母がマイナス) は、本家が対応していないので nil (入力エラー)
    static func parse(_ s: String) -> Beat? {
        let t = s.normalizedForNumberInput
        let parts = t.split(whereSeparator: { $0 == ":" || $0 == "/" }).map { String($0) }
        let nums = parts.compactMap { Int($0) }
        if parts.isEmpty || nums.count != parts.count { return nil }
        if nums.count == 1 { return Beat(nums[0], 0, 1) }
        if nums.count == 3 && nums[1] >= 0 && nums[2] > 0 { return Beat(nums[0], nums[1], nums[2]) }
        return nil
    }
}
