import Foundation

/// Legacy Excel 97–2003 (BIFF8) reader: Compound File container, shared
/// strings, number/RK/label/formula-result cells and date formats.
enum XLSReader {
    static func read(_ url: URL) throws -> Workbook {
        let data = try Data(contentsOf: url)
        let file = try CompoundFile(data)
        guard let stream = file.stream(named: "Workbook") ?? file.stream(named: "Book") else {
            throw LimeError("This sheet is blank or larger than 128 MB.")
        }
        return try parse(stream)
    }

    // MARK: BIFF records

    private struct Record { let type: UInt16; let data: Data; let offset: Int }

    private static func records(_ stream: Data) -> [Record] {
        var result: [Record] = []
        var p = 0
        while p + 4 <= stream.count {
            let type = stream.u16(p), length = Int(stream.u16(p + 2))
            guard p + 4 + length <= stream.count else { break }
            result.append(Record(type: type, data: stream.subdata(in: (p + 4)..<(p + 4 + length)), offset: p))
            p += 4 + length
        }
        return result
    }

    private static func parse(_ stream: Data) throws -> Workbook {
        let all = records(stream)
        var sheets: [(name: String, offset: Int)] = []
        var shared: [String] = []
        var xfFormats: [Int] = []
        var dateFormats = Set<Int>(14...22).union(45...47)
        var i = 0
        while i < all.count {
            let r = all[i]
            switch r.type {
            case 0x0085 where r.data.count >= 8:
                let offset = Int(r.data.u32(0))
                let cch = Int(r.data[6]), flags = r.data[7]
                let name = r.data.string(at: 8, count: cch, wide: flags & 1 == 1)
                if r.data[5] == 0 { sheets.append((name, offset)) }
            case 0x00FC:
                // SST spans CONTINUE records; gather their payloads with boundaries.
                var chunks = [r.data]
                var j = i + 1
                while j < all.count, all[j].type == 0x003C { chunks.append(all[j].data); j += 1 }
                var reader = SSTReader(chunks: chunks)
                shared = reader.strings()
                i = j - 1
            case 0x041E where r.data.count >= 5:
                let index = Int(r.data.u16(0))
                let cch = Int(r.data.u16(2)), flags = r.data[4]
                let code = r.data.string(at: 5, count: cch, wide: flags & 1 == 1).lowercased()
                    .replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*""#, with: "", options: .regularExpression)
                if code.contains("y") || (code.contains("d") && code.contains("m")) || code.contains("h:mm") { dateFormats.insert(index) }
            case 0x00E0 where r.data.count >= 4:
                xfFormats.append(Int(r.data.u16(2)))
            default: break
            }
            i += 1
        }
        let offsets = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.offset, $0.offset) })
        var book = Workbook(sheets: [])
        for sheet in sheets {
            guard let start = offsets[sheet.offset] else { continue }
            var grid: [Int: [Int: String]] = [:]
            var maxRow = -1
            var pendingFormula: (Int, Int)?
            func set(_ row: Int, _ col: Int, _ value: String) {
                guard row < 1_048_576, col < 16_384 else { return }
                grid[row, default: [:]][col] = value
                maxRow = max(maxRow, row)
            }
            func number(_ value: Double, xf: Int) -> String {
                let format = xf < xfFormats.count ? xfFormats[xf] : 0
                if dateFormats.contains(format), value > 0, value < 2_958_466 { return excelDate(value) }
                if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
                return String(value)
            }
            var k = start + 1
            loop: while k < all.count {
                let r = all[k], d = r.data
                k += 1
                switch r.type {
                case 0x000A: break loop
                case 0x00FD where d.count >= 10:
                    let index = Int(d.u32(6))
                    set(Int(d.u16(0)), Int(d.u16(2)), index < shared.count ? shared[index] : "")
                case 0x0203 where d.count >= 14:
                    set(Int(d.u16(0)), Int(d.u16(2)), number(d.f64(6), xf: Int(d.u16(4))))
                case 0x027E where d.count >= 10:
                    set(Int(d.u16(0)), Int(d.u16(2)), number(rk(d.u32(6)), xf: Int(d.u16(4))))
                case 0x00BD where d.count >= 6:
                    let row = Int(d.u16(0)), first = Int(d.u16(2))
                    let count = (d.count - 6) / 6
                    for n in 0..<count {
                        let base = 4 + n * 6
                        set(row, first + n, number(rk(d.u32(base + 2)), xf: Int(d.u16(base))))
                    }
                case 0x0204 where d.count >= 9:
                    let cch = Int(d.u16(6)), flags = d[8]
                    set(Int(d.u16(0)), Int(d.u16(2)), d.string(at: 9, count: cch, wide: flags & 1 == 1))
                case 0x0205 where d.count >= 8:
                    let isError = d[7] == 1
                    set(Int(d.u16(0)), Int(d.u16(2)), isError ? "#ERROR" : (d[6] == 1 ? "TRUE" : "FALSE"))
                case 0x0006 where d.count >= 14:
                    let row = Int(d.u16(0)), col = Int(d.u16(2))
                    if d[12] == 0xFF, d[13] == 0xFF {
                        switch d[6] {
                        case 0: pendingFormula = (row, col)
                        case 1: set(row, col, d[8] == 1 ? "TRUE" : "FALSE")
                        case 2: set(row, col, "#ERROR")
                        default: break
                        }
                    } else {
                        set(row, col, number(d.f64(6), xf: Int(d.u16(4))))
                    }
                case 0x0207 where d.count >= 3:
                    if let (row, col) = pendingFormula {
                        let cch = Int(d.u16(0)), flags = d[2]
                        set(row, col, d.string(at: 3, count: cch, wide: flags & 1 == 1))
                        pendingFormula = nil
                    }
                default: break
                }
            }
            var rows: [[String]] = []
            if maxRow >= 0 {
                for row in 0...maxRow {
                    let cells = grid[row] ?? [:]
                    let width = (cells.keys.max() ?? -1) + 1
                    rows.append((0..<width).map { cells[$0] ?? "" })
                }
            }
            book.sheets.append(.init(name: sheet.name, rows: XLSX.trim(rows)))
        }
        guard !book.sheets.isEmpty else { throw LimeError("This sheet is blank or larger than 128 MB.") }
        return book
    }

    private static func rk(_ value: UInt32) -> Double {
        var result: Double
        if value & 0x02 != 0 { result = Double(Int32(bitPattern: value) >> 2) }
        else { result = Double(bitPattern: UInt64(value & 0xFFFF_FFFC) << 32) }
        if value & 0x01 != 0 { result /= 100 }
        return result
    }

    private static func excelDate(_ serial: Double) -> String {
        let base = Date(timeIntervalSince1970: -2_209_161_600) // 1899-12-30
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: base.addingTimeInterval(serial * 86_400))
    }

    /// Shared strings whose characters may continue in the next record,
    /// where each continuation restarts with its own encoding flag.
    private struct SSTReader {
        let chunks: [Data]
        var chunk = 0, pos = 8

        init(chunks: [Data]) { self.chunks = chunks }

        mutating func byte() -> UInt8? {
            while chunk < chunks.count, pos >= chunks[chunk].count { chunk += 1; pos = 0 }
            guard chunk < chunks.count else { return nil }
            defer { pos += 1 }
            return chunks[chunk][pos]
        }
        mutating func u16() -> Int? { guard let a = byte(), let b = byte() else { return nil }; return Int(a) | Int(b) << 8 }
        mutating func u32() -> Int? { guard let a = u16(), let b = u16() else { return nil }; return a | b << 16 }
        mutating func skip(_ n: Int) { for _ in 0..<n { _ = byte() } }

        mutating func strings() -> [String] {
            guard let first = chunks.first, first.count >= 8 else { return [] }
            let unique = Int(first.u32(4))
            var result: [String] = []
            result.reserveCapacity(min(unique, 1_000_000))
            for _ in 0..<unique {
                guard let cch = u16(), var flags = byte() else { break }
                let rich = flags & 0x08 != 0, ext = flags & 0x04 != 0
                let runs = rich ? (u16() ?? 0) : 0
                let extSize = ext ? (u32() ?? 0) : 0
                var scalars = String.UnicodeScalarView()
                var remaining = cch
                while remaining > 0 {
                    if pos >= (chunk < chunks.count ? chunks[chunk].count : 0) {
                        // Character data continues: a fresh flag byte leads the record.
                        chunk += 1; pos = 0
                        guard chunk < chunks.count, let f = byte() else { break }
                        flags = f
                    }
                    if flags & 1 == 1 {
                        guard let v = u16() else { break }
                        if let s = Unicode.Scalar(v) { scalars.append(s) }
                    } else {
                        guard let v = byte() else { break }
                        scalars.append(Unicode.Scalar(v))
                    }
                    remaining -= 1
                }
                result.append(String(scalars))
                skip(runs * 4 + extSize)
            }
            return result
        }
    }
}

/// Minimal reader for Microsoft Compound File Binary (OLE2) streams.
struct CompoundFile {
    private let data: Data
    private let sectorSize: Int, miniSectorSize: Int
    private var fat: [UInt32] = [], miniFAT: [UInt32] = []
    private var entries: [(name: String, type: UInt8, start: UInt32, size: Int)] = []
    private var miniStream = Data()
    private let miniCutoff: Int

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 512, data.prefix(8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else {
            throw LimeError("Lime doesn't know this kind of file.")
        }
        sectorSize = 1 << Int(data.u16(30))
        miniSectorSize = 1 << Int(data.u16(32))
        miniCutoff = Int(data.u32(56))
        guard [512, 4096].contains(sectorSize) else { throw LimeError("Lime doesn't know this kind of file.") }
        // DIFAT: 109 entries in the header, then a chain of DIFAT sectors.
        var fatSectors: [UInt32] = (0..<109).map { data.u32(76 + $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
        var difat = data.u32(68), guardCount = 0
        while difat < 0xFFFF_FFFA, guardCount < 10_000 {
            let base = offset(difat)
            guard base + sectorSize <= data.count else { break }
            for k in 0..<(sectorSize / 4 - 1) { let v = data.u32(base + k * 4); if v < 0xFFFF_FFFA { fatSectors.append(v) } }
            difat = data.u32(base + sectorSize - 4); guardCount += 1
        }
        for s in fatSectors {
            let base = offset(s)
            guard base + sectorSize <= data.count else { continue }
            for k in 0..<(sectorSize / 4) { fat.append(data.u32(base + k * 4)) }
        }
        let directory = chain(data.u32(48))
        for k in 0..<(directory.count / 128) {
            let e = directory.subdata(in: (k * 128)..<(k * 128 + 128))
            let nameLength = max(0, min(64, Int(e.u16(64))) - 2)
            let name = String(decoding: stride(from: 0, to: nameLength, by: 2).map { e.u16($0) }, as: UTF16.self)
            entries.append((name, e[66], e.u32(116), Int(e.u32(120))))
        }
        if let root = entries.first(where: { $0.type == 5 }) {
            miniStream = chain(root.start, limit: root.size)
            let miniFATData = chain(data.u32(60))
            miniFAT = (0..<(miniFATData.count / 4)).map { miniFATData.u32($0 * 4) }
        }
    }

    private func offset(_ sector: UInt32) -> Int { (Int(sector) + 1) * sectorSize }

    private func chain(_ start: UInt32, limit: Int? = nil) -> Data {
        var result = Data(), sector = start, steps = 0
        while sector < 0xFFFF_FFFA, Int(sector) < fat.count || fat.isEmpty, steps < 2_000_000 {
            let base = offset(sector)
            guard base + sectorSize <= data.count else { break }
            result.append(data.subdata(in: base..<(base + sectorSize)))
            if let limit, result.count >= limit { break }
            guard Int(sector) < fat.count else { break }
            sector = fat[Int(sector)]; steps += 1
        }
        if let limit, result.count > limit { result = result.prefix(limit) }
        return result
    }

    private func miniChain(_ start: UInt32, size: Int) -> Data {
        var result = Data(), sector = start, steps = 0
        while sector < 0xFFFF_FFFA, steps < 2_000_000 {
            let base = Int(sector) * miniSectorSize
            guard base + miniSectorSize <= miniStream.count else { break }
            result.append(miniStream.subdata(in: base..<(base + miniSectorSize)))
            if result.count >= size { break }
            guard Int(sector) < miniFAT.count else { break }
            sector = miniFAT[Int(sector)]; steps += 1
        }
        return result.prefix(size)
    }

    func stream(named name: String) -> Data? {
        guard let entry = entries.first(where: { $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return entry.size < miniCutoff ? miniChain(entry.start, size: entry.size) : chain(entry.start, limit: entry.size)
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 { guard i + 2 <= count else { return 0 }; return UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func f64(_ i: Int) -> Double { Double(bitPattern: UInt64(u32(i)) | UInt64(u32(i + 4)) << 32) }
    func string(at i: Int, count n: Int, wide: Bool) -> String {
        let length = wide ? n * 2 : n
        guard i >= 0, i + length <= count else { return "" }
        let slice = subdata(in: (startIndex + i)..<(startIndex + i + length))
        return wide ? String(decoding: Swift.stride(from: 0, to: length, by: 2).map { slice.u16($0) }, as: UTF16.self)
            : String(slice.map { Character(Unicode.Scalar($0)) })
    }
}
