import UIKit
import ImageIO

// 本家のスキン画像 (SlideSkinData*.swift に base64 で埋め込んである) を、CGImage にして配る。
//  ・初回アクセスのときにデコードして、以後は使い回す (ヒット光のような大きい画像を、プレイ中に初めてデコードしないよう
//    prepare() でまとめて先に済ませる。別スレッドで呼んでよい)
//  ・数字の画像は白なので、色 (score = 青、acc = 赤) を付けた版を作って持つ

final class SlideSkin: @unchecked Sendable {
    static let shared = SlideSkin()

    private let lock = NSLock()
    private var raw: [String: Data] = [:]
    private var images: [String: CGImage] = [:]
    private var tintedNumbers: [UInt32: [CGImage?]] = [:]

    private init() {
        for table in [SlideSkinDataUI.table, SlideSkinDataLight.table, SlideSkinDataLight2.table] {
            for line in table.split(separator: "\n") {
                guard let sp = line.firstIndex(of: " ") else { continue }
                let name = String(line[line.startIndex..<sp])
                let b64 = line[line.index(after: sp)...]
                if let d = Data(base64Encoded: String(b64)) { raw[name] = d }
            }
        }
    }

    /// 名前 → 画像。名前は SlideSkinData*.swift の見出し (bar0, judge, note0, num3, combo5, score0, light7, light2_3 ...)
    func image(_ name: String) -> CGImage? {
        lock.lock()
        if let i = images[name] { lock.unlock(); return i }
        lock.unlock()
        guard let d = raw[name], let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else { return nil }
        lock.lock()
        images[name] = img
        lock.unlock()
        return img
    }

    func light(_ i: Int) -> CGImage? { image("light\(i)") }
    func light2(_ i: Int) -> CGImage? { image("light2_\(i)") }
    func combo(_ i: Int) -> CGImage? { image("combo\(i)") }

    /// 判定文字 (番号は SlideJudgeText.frame)
    func judge(_ i: Int) -> CGImage? { image("score\(i)") }

    /// 色を付けた数字 (0-9 = 数字, 10 = "%", 11 = ".", 12 = "-")。color は 0xRRGGBB
    func number(_ glyph: Int, color: UInt32) -> CGImage? {
        lock.lock()
        if let t = tintedNumbers[color], glyph >= 0, glyph < t.count { let r = t[glyph]; lock.unlock(); return r }
        lock.unlock()
        var list: [CGImage?] = []
        for g in 0...12 { list.append(image("num\(g)").flatMap { SlideSkin.tint($0, color: color) }) }
        lock.lock()
        tintedNumbers[color] = list
        lock.unlock()
        return glyph >= 0 && glyph < list.count ? list[glyph] : nil
    }

    /// すべて先にデコードしておく (別スレッドで呼んでよい)
    func prepare() {
        for name in raw.keys { _ = image(name) }
        _ = number(0, color: 0x6ECAEE)
        _ = number(0, color: 0xC24954)
    }

    /// 白い画像に色を付ける (形 = 透明度は変えない)
    static func tint(_ src: CGImage, color: UInt32) -> CGImage? {
        let w = src.width, h = src.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(src, in: rect)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
                         blue: CGFloat(color & 0xFF) / 255, alpha: 1)
        ctx.fill(rect)
        return ctx.makeImage()
    }
}
