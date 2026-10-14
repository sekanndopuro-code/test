import Foundation

// 譜面 (mc) の読み書きに使う、小さな JSON の値型。
//
// 以前は `[String: Any]` (JSONSerialization の結果) をそのまま持っていた。
//   ・Any は箱に入った値で重い (ノーツごとに NSNumber の箱が何個もできる)
//   ・Sendable ではないので、保存を別スレッドへ渡せない
// この型は enum なので軽く、Sendable (= 別スレッドへそのまま渡せる)。
// 読み込みも書き出しも、JSONSerialization を使わずに自前で行う (Foundation より速く、結果が決まっている)。

enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

enum JSONError: Error {
    case syntax(Int)          // 読めなかった位置 (バイト)
    case notFinite            // 書き出せない数 (nan / inf)
}

// MARK: - 取り出し (NSNumber 相当の読み方。以前の `as? NSNumber` → intValue / doubleValue と同じ結果にする)

extension JSONValue {
    /// 数 (整数・小数・true/false)。以前の `as? NSNumber` が通っていたものと同じ
    var isNumber: Bool {
        switch self {
        case .int, .double, .bool: return true
        default: return false
        }
    }

    /// NSNumber.intValue と同じ: 小数は 0 の方向へ切り捨て、true/false は 1/0
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return JSONValue.clampedInt(d)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// 要素が全部オブジェクトの配列なら、そのオブジェクトの配列。1つでも違えば nil
    /// (以前の `as? [[String: Any]]` と同じ。全部か、何もかを選ぶ)
    var arrayOfObjects: [[String: JSONValue]]? {
        guard case .array(let a) = self else { return nil }
        var out: [[String: JSONValue]] = []
        out.reserveCapacity(a.count)
        for v in a {
            guard case .object(let o) = v else { return nil }
            out.append(o)
        }
        return out
    }

    /// 要素が全部数の配列なら、その Int の配列。1つでも違えば nil (以前の `as? [NSNumber]` と同じ)
    var arrayOfInts: [Int]? {
        guard case .array(let a) = self else { return nil }
        var out: [Int] = []
        out.reserveCapacity(a.count)
        for v in a {
            guard let i = v.intValue else { return nil }
            out.append(i)
        }
        return out
    }

    static func clampedInt(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= 9.2e18 { return Int.max }
        if d <= -9.2e18 { return Int.min }
        return Int(d)
    }
}

// MARK: - 読み込み

extension JSONValue {
    /// JSON の文字列 (UTF-8) を読む。先頭の BOM は読み飛ばす。
    static func parse(_ data: Data) throws -> JSONValue {
        let bytes = [UInt8](data)
        return try bytes.withUnsafeBufferPointer { buf in
            var p = JSONParser(buf)
            return try p.parseDocument()
        }
    }
}

private struct JSONParser {
    let b: UnsafeBufferPointer<UInt8>
    var i = 0
    let n: Int
    static let maxDepth = 512

    init(_ buf: UnsafeBufferPointer<UInt8>) {
        b = buf
        n = buf.count
    }

    mutating func parseDocument() throws -> JSONValue {
        if n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { i = 3 }
        skipWS()
        let v = try parseValue(depth: 0)
        skipWS()
        if i != n { throw JSONError.syntax(i) }
        return v
    }

    @inline(__always)
    mutating func skipWS() {
        while i < n {
            let c = b[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { break }
        }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        if depth > JSONParser.maxDepth { throw JSONError.syntax(i) }
        guard i < n else { throw JSONError.syntax(i) }
        switch b[i] {
        case 0x7B: return try parseObject(depth: depth)       // {
        case 0x5B: return try parseArray(depth: depth)        // [
        case 0x22: return .string(try parseString())          // "
        case 0x74: try expect("true"); return .bool(true)
        case 0x66: try expect("false"); return .bool(false)
        case 0x6E: try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: StaticString) throws {
        let len = word.utf8CodeUnitCount
        guard i + len <= n else { throw JSONError.syntax(i) }
        let w = word.utf8Start
        for k in 0..<len where b[i + k] != w[k] { throw JSONError.syntax(i) }
        i += len
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        i += 1   // {
        var out: [String: JSONValue] = [:]
        skipWS()
        if i < n && b[i] == 0x7D { i += 1; return .object(out) }
        while true {
            skipWS()
            guard i < n, b[i] == 0x22 else { throw JSONError.syntax(i) }
            let key = try parseString()
            skipWS()
            guard i < n, b[i] == 0x3A else { throw JSONError.syntax(i) }   // :
            i += 1
            skipWS()
            out[key] = try parseValue(depth: depth + 1)
            skipWS()
            guard i < n else { throw JSONError.syntax(i) }
            if b[i] == 0x2C { i += 1; continue }     // ,
            if b[i] == 0x7D { i += 1; return .object(out) }
            throw JSONError.syntax(i)
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        i += 1   // [
        var out: [JSONValue] = []
        skipWS()
        if i < n && b[i] == 0x5D { i += 1; return .array(out) }
        while true {
            skipWS()
            out.append(try parseValue(depth: depth + 1))
            skipWS()
            guard i < n else { throw JSONError.syntax(i) }
            if b[i] == 0x2C { i += 1; continue }
            if b[i] == 0x5D { i += 1; return .array(out) }
            throw JSONError.syntax(i)
        }
    }

    mutating func parseString() throws -> String {
        i += 1   // 開きの "
        let start = i
        // エスケープの無い文字列は、そのまま切り出す (ほとんどの文字列はこちら)
        while i < n {
            let c = b[i]
            if c == 0x22 {
                let s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
                i += 1
                return s
            }
            if c == 0x5C { break }
            if c < 0x20 { throw JSONError.syntax(i) }
            i += 1
        }
        // エスケープがある文字列
        var out = [UInt8](UnsafeBufferPointer(rebasing: b[start..<i]))
        while i < n {
            let c = b[i]
            if c == 0x22 {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c < 0x20 { throw JSONError.syntax(i) }
            if c != 0x5C { out.append(c); i += 1; continue }
            i += 1
            guard i < n else { throw JSONError.syntax(i) }
            let e = b[i]
            i += 1
            switch e {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                var u = try hex4()
                if u >= 0xD800 && u < 0xDC00 {
                    // 上位サロゲート。続く \uXXXX が下位サロゲートなら合わせて 1 文字にする
                    if i + 1 < n, b[i] == 0x5C, b[i + 1] == 0x75 {
                        let save = i
                        i += 2
                        let lo = try hex4()
                        if lo >= 0xDC00 && lo < 0xE000 {
                            u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                        } else {
                            i = save
                            u = 0xFFFD
                        }
                    } else {
                        u = 0xFFFD
                    }
                } else if u >= 0xDC00 && u < 0xE000 {
                    u = 0xFFFD
                }
                let scalar = Unicode.Scalar(u) ?? Unicode.Scalar(0xFFFD)!
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                throw JSONError.syntax(i)
            }
        }
        throw JSONError.syntax(i)
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= n else { throw JSONError.syntax(i) }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]
            var d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw JSONError.syntax(i)
            }
            v = (v << 4) | d
            i += 1
        }
        return v
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = i
        var neg = false
        if i < n && b[i] == 0x2D { neg = true; i += 1 }
        let digitsStart = i
        var acc: UInt64 = 0
        var overflow = false
        while i < n, b[i] >= 0x30, b[i] <= 0x39 {
            let d = UInt64(b[i] - 0x30)
            let (m, o1) = acc.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(d)
            if o1 || o2 { overflow = true } else { acc = a }
            i += 1
        }
        guard i > digitsStart else { throw JSONError.syntax(start) }
        var isFloat = false
        if i < n && b[i] == 0x2E {            // .
            isFloat = true
            i += 1
            let fs = i
            while i < n, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            guard i > fs else { throw JSONError.syntax(i) }
        }
        if i < n && (b[i] == 0x65 || b[i] == 0x45) {   // e E
            isFloat = true
            i += 1
            if i < n && (b[i] == 0x2B || b[i] == 0x2D) { i += 1 }
            let es = i
            while i < n, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            guard i > es else { throw JSONError.syntax(i) }
        }
        if !isFloat && !overflow {
            if neg {
                if acc <= UInt64(Int.max) { return .int(-Int(acc)) }
                if acc == UInt64(Int.max) + 1 { return .int(Int.min) }
            } else if acc <= UInt64(Int.max) {
                return .int(Int(acc))
            }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
        guard let d = Double(text) else { throw JSONError.syntax(start) }
        return .double(d)
    }
}

// MARK: - 書き出し

extension JSONValue {
    /// JSON にして out の後ろへ足す。キーは並べ替える (JSONSerialization の .sortedKeys と同じ)。
    /// スラッシュは「\/」にしない (.withoutEscapingSlashes と同じ)。
    func write(into out: inout [UInt8]) throws {
        switch self {
        case .null:
            out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
        case .bool(let v):
            out.append(contentsOf: v ? [0x74, 0x72, 0x75, 0x65] : [0x66, 0x61, 0x6C, 0x73, 0x65])
        case .int(let v):
            JSONValue.writeInt(v, into: &out)
        case .double(let v):
            try JSONValue.writeDouble(v, into: &out)
        case .string(let s):
            JSONValue.writeString(s, into: &out)
        case .array(let a):
            out.append(0x5B)
            var first = true
            for v in a {
                if !first { out.append(0x2C) }
                first = false
                try v.write(into: &out)
            }
            out.append(0x5D)
        case .object(let o):
            try JSONValue.writeObject(o, into: &out)
        }
    }

    static func writeObject(_ o: [String: JSONValue], into out: inout [UInt8]) throws {
        out.append(0x7B)
        var first = true
        for k in o.keys.sorted() {
            if !first { out.append(0x2C) }
            first = false
            writeString(k, into: &out)
            out.append(0x3A)
            try o[k]!.write(into: &out)
        }
        out.append(0x7D)
    }

    static func writeInt(_ v: Int, into out: inout [UInt8]) {
        if v >= 0 && v < 10 {
            out.append(UInt8(0x30 + v))
            return
        }
        var mag = v.magnitude
        var tmp: [UInt8] = []
        tmp.reserveCapacity(20)
        while mag > 0 {
            tmp.append(UInt8(0x30 + mag % 10))
            mag /= 10
        }
        if v < 0 { out.append(0x2D) }
        out.append(contentsOf: tmp.reversed())
    }

    /// 整数と同じ値の小数 (120.0 など) は整数で書く (JSONSerialization と同じ)。それ以外は、最短で元に戻る表記
    static func writeDouble(_ d: Double, into out: inout [UInt8]) throws {
        guard d.isFinite else { throw JSONError.notFinite }
        if d == d.rounded() && abs(d) < 1e15 {
            writeInt(Int(d), into: &out)
            return
        }
        out.append(contentsOf: Array("\(d)".utf8))
    }

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        for c in s.utf8 {
            switch c {
            case 0x22: out.append(0x5C); out.append(0x22)
            case 0x5C: out.append(0x5C); out.append(0x5C)
            case 0x08: out.append(0x5C); out.append(0x62)
            case 0x0C: out.append(0x5C); out.append(0x66)
            case 0x0A: out.append(0x5C); out.append(0x6E)
            case 0x0D: out.append(0x5C); out.append(0x72)
            case 0x09: out.append(0x5C); out.append(0x74)
            case 0..<0x20:
                let hex: [UInt8] = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(c >> 4)], hex[Int(c & 15)]])
            default:
                out.append(c)
            }
        }
        out.append(0x22)
    }
}
