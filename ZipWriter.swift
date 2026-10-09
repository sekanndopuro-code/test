import Foundation

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func u32(_ v: UInt32) {
        for i in 0..<4 {
            append(UInt8((v >> UInt32(8 * i)) & 0xFF))
        }
    }
}

/// 無圧縮(stored)の最小 ZIP ライタ。mcz(=zip) の書き出し用
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0

    init() {}

    mutating func add(name: String, data: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let size = UInt32(data.count)
        let offset = UInt32(body.count)

        var h = Data()
        h.u32(0x04034b50)
        h.u16(20)
        h.u16(0x0800)           // UTF-8 ファイル名
        h.u16(0)                // stored
        h.u16(0)
        h.u16(0x0021)           // 1980-01-01
        h.u32(crc)
        h.u32(size)
        h.u32(size)
        h.u16(UInt16(nameData.count))
        h.u16(0)
        body.append(h)
        body.append(nameData)
        body.append(data)

        var c = Data()
        c.u32(0x02014b50)
        c.u16(20)
        c.u16(20)
        c.u16(0x0800)
        c.u16(0)
        c.u16(0)
        c.u16(0x0021)
        c.u32(crc)
        c.u32(size)
        c.u32(size)
        c.u16(UInt16(nameData.count))
        c.u16(0)
        c.u16(0)
        c.u16(0)
        c.u16(0)
        c.u32(0)
        c.u32(offset)
        central.append(c)
        central.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var out = body
        let cdOffset = UInt32(body.count)
        out.append(central)
        var e = Data()
        e.u32(0x06054b50)
        e.u16(0)
        e.u16(0)
        e.u16(UInt16(count))
        e.u16(UInt16(count))
        e.u32(UInt32(central.count))
        e.u32(cdOffset)
        e.u16(0)
        out.append(e)
        return out
    }
}
