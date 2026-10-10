import SwiftUI

// META (Back / Information / More / Quit) は、シートをやめて右ボタン列 + 右ウィンドウになった。
// 列の動きは EditorState+Meta.swift、Information の窓は SideWindow.swift (InformationWindowContent)。
// このファイルには、拍の入力 (Beat.parse) だけが残っている。

extension Beat {
    /// "8:0/4" / "8" 形式を解釈 (0拍始まり)
    static func parse(_ s: String) -> Beat? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(whereSeparator: { $0 == ":" || $0 == "/" }).map { String($0) }
        let nums = parts.compactMap { Int($0) }
        if parts.isEmpty || nums.count != parts.count { return nil }
        if nums.count == 1 { return Beat(nums[0], 0, 1) }
        if nums.count == 3 && nums[2] > 0 { return Beat(nums[0], nums[1], nums[2]) }
        return nil
    }
}
