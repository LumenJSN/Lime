import Foundation

/// Minimal protobuf wire-format reader/writer: enough to edit iWork archives
/// without their schemas. Unknown fields round-trip unchanged.
struct ProtoField: Equatable {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(Data)
        case bytes(Data)
        case fixed32(Data)
    }
    var number: Int
    var value: Value

    static func varint(_ number: Int, _ value: UInt64) -> ProtoField { ProtoField(number: number, value: .varint(value)) }
    static func bytes(_ number: Int, _ data: Data) -> ProtoField { ProtoField(number: number, value: .bytes(data)) }
    static func message(_ number: Int, _ fields: [ProtoField]) -> ProtoField { .bytes(number, Proto.encode(fields)) }

    var uint: UInt64? { if case .varint(let v) = value { return v }; return nil }
    var data: Data? { if case .bytes(let d) = value { return d }; return nil }
    var fields: [ProtoField]? { data.flatMap { try? Proto.parse($0) } }
}

enum Proto {
    struct Malformed: Error {}

    static func readVarint(_ data: Data, _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard index < data.endIndex, shift < 64 else { throw Malformed() }
            let byte = data[index]; index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
    }

    static func writeVarint(_ value: UInt64, into data: inout Data) {
        var v = value
        while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }

    static func parse(_ data: Data) throws -> [ProtoField] {
        var fields: [ProtoField] = []
        var i = data.startIndex
        while i < data.endIndex {
            let key = try readVarint(data, &i)
            let number = Int(key >> 3)
            guard number > 0 else { throw Malformed() }
            switch key & 7 {
            case 0: fields.append(.init(number: number, value: .varint(try readVarint(data, &i))))
            case 1:
                guard i + 8 <= data.endIndex else { throw Malformed() }
                fields.append(.init(number: number, value: .fixed64(data[i..<i + 8]))); i += 8
            case 2:
                let length = Int(try readVarint(data, &i))
                guard length >= 0, i + length <= data.endIndex else { throw Malformed() }
                fields.append(.init(number: number, value: .bytes(Data(data[i..<i + length])))); i += length
            case 5:
                guard i + 4 <= data.endIndex else { throw Malformed() }
                fields.append(.init(number: number, value: .fixed32(data[i..<i + 4]))); i += 4
            default: throw Malformed()
            }
        }
        return fields
    }

    static func encode(_ fields: [ProtoField]) -> Data {
        var out = Data()
        for field in fields {
            switch field.value {
            case .varint(let v): writeVarint(UInt64(field.number << 3), into: &out); writeVarint(v, into: &out)
            case .fixed64(let d): writeVarint(UInt64(field.number << 3 | 1), into: &out); out.append(d)
            case .bytes(let d): writeVarint(UInt64(field.number << 3 | 2), into: &out); writeVarint(UInt64(d.count), into: &out); out.append(d)
            case .fixed32(let d): writeVarint(UInt64(field.number << 3 | 5), into: &out); out.append(d)
            }
        }
        return out
    }

    /// Packed repeated varints (used for object reference lists).
    static func packed(_ data: Data) throws -> [UInt64] {
        var values: [UInt64] = [], i = data.startIndex
        while i < data.endIndex { values.append(try readVarint(data, &i)) }
        return values
    }

    static func packed(_ values: [UInt64]) -> Data {
        var out = Data()
        values.forEach { writeVarint($0, into: &out) }
        return out
    }
}

/// Snappy block format as used inside `.iwa` files.
enum Snappy {
    static func decompress(_ data: Data) throws -> Data {
        var i = data.startIndex
        let expected = Int(try Proto.readVarint(data, &i))
        var out = [UInt8](); out.reserveCapacity(expected)
        let bytes = [UInt8](data)
        var p = i - data.startIndex
        func le(_ count: Int) throws -> Int {
            guard p + count <= bytes.count else { throw Proto.Malformed() }
            var v = 0
            for k in 0..<count { v |= Int(bytes[p + k]) << (8 * k) }
            p += count
            return v
        }
        while p < bytes.count {
            let tag = bytes[p]; p += 1
            switch tag & 3 {
            case 0:
                var length = Int(tag >> 2)
                if length >= 60 { length = try le(length - 59) }
                length += 1
                guard p + length <= bytes.count else { throw Proto.Malformed() }
                out.append(contentsOf: bytes[p..<p + length]); p += length
            default:
                let length: Int, offset: Int
                switch tag & 3 {
                case 1: length = Int((tag >> 2) & 7) + 4; offset = (Int(tag >> 5) << 8) | (try le(1))
                case 2: length = Int(tag >> 2) + 1; offset = try le(2)
                default: length = Int(tag >> 2) + 1; offset = try le(4)
                }
                guard offset > 0, offset <= out.count else { throw Proto.Malformed() }
                let start = out.count - offset
                for k in 0..<length { out.append(out[start + k]) }
            }
        }
        guard out.count == expected else { throw Proto.Malformed() }
        return Data(out)
    }

    /// Valid Snappy made of literals only; iWork reads it like any other block.
    static func compressLiterals(_ data: Data) -> Data {
        var out = Data()
        Proto.writeVarint(UInt64(data.count), into: &out)
        var start = data.startIndex
        while start < data.endIndex {
            let length = min(65536, data.endIndex - start)
            let n = length - 1
            if n < 60 { out.append(UInt8(n << 2)) }
            else if n < 256 { out.append(60 << 2); out.append(UInt8(n)) }
            else { out.append(61 << 2); out.append(UInt8(n & 0xff)); out.append(UInt8(n >> 8)) }
            out.append(data[start..<start + length])
            start += length
        }
        return out
    }
}

/// One object of an `.iwa` stream: its `ArchiveInfo` header and messages.
struct IWAObject {
    var identifier: UInt64
    var header: [ProtoField]
    var payloads: [Data]

    var messageInfos: [[ProtoField]] { header.filter { $0.number == 2 }.compactMap(\.fields) }
    var types: [UInt64] { messageInfos.map { $0.first { $0.number == 1 }?.uint ?? 0 } }
}

enum IWAFile {
    static func read(_ data: Data) throws -> [IWAObject] {
        var stream = Data(), i = data.startIndex
        while i < data.endIndex {
            guard i + 4 <= data.endIndex, data[i] == 0 else { throw Proto.Malformed() }
            let length = Int(data[i + 1]) | Int(data[i + 2]) << 8 | Int(data[i + 3]) << 16
            i += 4
            guard i + length <= data.endIndex else { throw Proto.Malformed() }
            stream.append(try Snappy.decompress(Data(data[i..<i + length])))
            i += length
        }
        var objects: [IWAObject] = [], p = stream.startIndex
        while p < stream.endIndex {
            let headerLength = Int(try Proto.readVarint(stream, &p))
            guard p + headerLength <= stream.endIndex else { throw Proto.Malformed() }
            let header = try Proto.parse(Data(stream[p..<p + headerLength])); p += headerLength
            let identifier = header.first { $0.number == 1 }?.uint ?? 0
            var payloads: [Data] = []
            for info in header.filter({ $0.number == 2 }).compactMap(\.fields) {
                let length = Int(info.first { $0.number == 3 }?.uint ?? 0)
                guard p + length <= stream.endIndex else { throw Proto.Malformed() }
                payloads.append(Data(stream[p..<p + length])); p += length
            }
            objects.append(IWAObject(identifier: identifier, header: header, payloads: payloads))
        }
        return objects
    }

    /// Serialises objects, updating each message length in its header.
    static func write(_ objects: [IWAObject]) -> Data {
        var stream = Data()
        for object in objects {
            var payloadIndex = 0
            let header = object.header.map { field -> ProtoField in
                guard field.number == 2, var info = field.fields else { return field }
                let length = UInt64(object.payloads[payloadIndex].count)
                payloadIndex += 1
                if let k = info.firstIndex(where: { $0.number == 3 }) { info[k] = .varint(3, length) } else { info.append(.varint(3, length)) }
                return .message(2, info)
            }
            let encoded = Proto.encode(header)
            Proto.writeVarint(UInt64(encoded.count), into: &stream)
            stream.append(encoded)
            object.payloads.forEach { stream.append($0) }
        }
        var out = Data(), start = stream.startIndex
        repeat {
            let end = min(stream.endIndex, start + 65536)
            let block = Snappy.compressLiterals(Data(stream[start..<end]))
            out.append(0)
            out.append(UInt8(block.count & 0xff)); out.append(UInt8((block.count >> 8) & 0xff)); out.append(UInt8((block.count >> 16) & 0xff))
            out.append(block)
            start = end
        } while start < stream.endIndex
        return out
    }
}
