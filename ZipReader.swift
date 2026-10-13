import Foundation
import Compression

/// mcz(=zip) を読むだけの最小 ZIP リーダ。ZipWriter の逆。
/// 無圧縮 (stored) と deflate に対応。ZIP64 / パスワード付きには対応しない。
/// 大きさ・位置は、ファイルの先頭ではなく末尾の「セントラルディレクトリ」から読む
/// (データ記述子つきの zip でも、サイズが正しく取れる)。
struct ZipReader {
    struct Entry {
        let name: String            // zip の中のパス (/ 区切り。フォルダは末尾が /)
        let flags: Int
        let method: Int             // 0 = stored / 8 = deflate
        let compressedSize: Int
        let size: Int
        let localOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    enum ZipError: LocalizedError {
        case notZip
        case zip64
        case encrypted
        case unsupportedMethod(Int)
        case broken

        var errorDescription: String? {
            switch self {
            case .notZip: return "zip (mcz) として読めませんでした"
            case .zip64: return "ZIP64 形式の mcz には対応していません"
            case .encrypted: return "パスワード付きの mcz には対応していません"
            case .unsupportedMethod(let m): return "未対応の圧縮方式です (method \(m))"
            case .broken: return "mcz の中身が壊れています"
            }
        }
    }

    private let data: Data
    let entries: [Entry]

    init(data source: Data) throws {
        // Data のスライスだと添字が 0 から始まらないので、そのときだけ作り直す
        let d = source.startIndex == 0 ? source : Data(source)
        self.data = d
        let n = d.count
        guard n >= 22 else { throw ZipError.notZip }

        // 末尾から End of Central Directory (0x06054b50) を探す (コメントがあっても最大 65535 バイト手前)
        var eocd = -1
        var i = n - 22
        let lowest = max(0, n - 22 - 65535)
        while i >= lowest {
            if Self.u32(d, i) == 0x06054b50 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }

        let total = Self.u16(d, eocd + 10)
        let cdOffset = Self.u32(d, eocd + 16)
        if total == 0xFFFF || cdOffset == 0xFFFFFFFF { throw ZipError.zip64 }

        var list: [Entry] = []
        var p = cdOffset
        for _ in 0..<total {
            guard p + 46 <= n, Self.u32(d, p) == 0x02014b50 else { throw ZipError.broken }
            let flags = Self.u16(d, p + 8)
            let method = Self.u16(d, p + 10)
            let csize = Self.u32(d, p + 20)
            let usize = Self.u32(d, p + 24)
            let nameLen = Self.u16(d, p + 28)
            let extraLen = Self.u16(d, p + 30)
            let commentLen = Self.u16(d, p + 32)
            let localOffset = Self.u32(d, p + 42)
            guard p + 46 + nameLen <= n else { throw ZipError.broken }
            if csize == 0xFFFFFFFF || usize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                throw ZipError.zip64
            }
            let nameData = d.subdata(in: (p + 46)..<(p + 46 + nameLen))
            list.append(Entry(name: Self.decodeName(nameData),
                              flags: flags, method: method,
                              compressedSize: csize, size: usize,
                              localOffset: localOffset))
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = list
    }

    /// 1 ファイルぶんの中身を取り出す
    func extract(_ e: Entry) throws -> Data {
        if e.flags & 1 != 0 { throw ZipError.encrypted }
        let n = data.count
        let lo = e.localOffset
        guard lo + 30 <= n, Self.u32(data, lo) == 0x04034b50 else { throw ZipError.broken }
        // ローカルヘッダの名前・extra の長さは、セントラルディレクトリのものと違うことがあるので、ここで読み直す
        let start = lo + 30 + Self.u16(data, lo + 26) + Self.u16(data, lo + 28)
        guard start + e.compressedSize <= n else { throw ZipError.broken }
        if e.compressedSize == 0 && e.size == 0 { return Data() }
        let raw = data.subdata(in: start..<(start + e.compressedSize))
        switch e.method {
        case 0:
            return raw
        case 8:
            return try Self.inflate(raw, expectedSize: e.size)
        default:
            throw ZipError.unsupportedMethod(e.method)
        }
    }

    // MARK: - 内部

    /// raw deflate (RFC 1951) を展開する。Apple の Compression の COMPRESSION_ZLIB は、zip の deflate をそのまま読める
    private static func inflate(_ src: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var out = Data(count: expectedSize)
        let written: Int = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                guard let dp = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sp = s.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(dp, expectedSize, sp, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.broken }
        return out
    }

    /// ファイル名の文字コード。UTF-8 で読めればそれ、だめなら Shift_JIS (古い日本語 Windows の zip)
    private static func decodeName(_ d: Data) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = String(data: d, encoding: .shiftJIS) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    private static func u16(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 2 <= d.count else { return 0 }
        return Int(d[o]) | (Int(d[o + 1]) << 8)
    }

    private static func u32(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24)
    }
}
