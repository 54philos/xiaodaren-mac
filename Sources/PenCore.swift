import Foundation
import CoreFoundation
import CryptoKit

struct PenError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Route: String, CaseIterable, Identifiable {
    case smart, ordinary, direct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: return "智能点读包（DAS）"
        case .ordinary: return "普通内容贴（DAR）"
        case .direct: return "书本封面直接进入（DAS）"
        }
    }
    var ext: String { self == .ordinary ? "dar" : "das" }
}

struct PackageInfo {
    let url: URL
    let size: UInt64
    let header: Data
    let title: String
    var isSmart: Bool { header.prefix(3) == Data("deb".utf8) }
    var isUNB: Bool { PenCore.isUNB(header) }
    var cover: UInt32 { header.u32(0x14c) }
    var content: UInt32 { isUNB ? UInt32(header.u16(0x8d) ^ header.u16(0xa1)) : header.u32(0x17b) }
    var unbDefaultRoute: Route { header.u16(0x5f) == 0 ? .ordinary : .smart }
    var declared: (cover: UInt32, slot: Int)? {
        let regex = try! NSRegularExpression(pattern: #"\((\d{1,10})\)\s*(\d{3})\s*$"#)
        let ns = title as NSString
        guard let match = regex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)),
              let cover = UInt32(ns.substring(with: match.range(at: 1))), (1...65535).contains(cover),
              let slot = Int(ns.substring(with: match.range(at: 2))), (1...999).contains(slot) else { return nil }
        return (cover, slot)
    }
}

struct Book: Identifiable, Hashable {
    let url: URL
    let slot: Int
    let size: UInt64
    let title: String
    var id: String { url.path }
    var ext: String { url.pathExtension.lowercased() }
}

struct Pen {
    let root: URL
    let deviceID: String
    let model: String
    let productData: Data
    var custom: URL { root.appendingPathComponent("USER/CUSTOM", isDirectory: true) }
}

struct CatalogEntry: Equatable {
    let url: URL
    let size: UInt64
    let modified: Date?
}

extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | (UInt16(self[offset+1]) << 8) }
    mutating func put16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset+1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    func u32(_ offset: Int) -> UInt32 {
        var result: UInt32 = 0
        for i in 0..<4 { result |= UInt32(self[offset+i]) << (i*8) }
        return result
    }
    mutating func put32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
}

enum PenCore {
    static let fm = FileManager.default
    static let headerSize = 0x17f
    static let chunk = 4 * 1024 * 1024
    static let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
    static func regular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PenError("文件不是普通文件，或是符号链接：\(url.lastPathComponent)") }
    }
    static func size(_ url: URL) throws -> UInt64 {
        try (fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }
    static func readPackage(_ url: URL, requireTail: Bool = true) throws -> PackageInfo {
        try regular(url)
        let count = try size(url)
        guard count >= UInt64(headerSize + 4) else { throw PenError("点读包过短或为空。") }
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        let prefix = try stream.read(upToCount: 512) ?? Data()
        guard prefix.count >= headerSize, supportedHeader(prefix) else { throw PenError("暂不支持此点读包格式。当前支持 deb 智能包、标准版本 2/3 普通内容包和 UNB 包。") }
        if requireTail {
            try stream.seek(toOffset: count - 4)
            if try stream.read(upToCount: 4) != Data("EOID".utf8) { throw PenError("未找到 EOID 结束标记，请确认点读包完整。") }
        }
        let start = prefix.prefix(3) == Data("deb".utf8) ? 4 : 0
        var titleData = Data(prefix[start..<0xc8])
        if let stop = titleData.firstIndex(where: { $0 == 0 || $0 == 255 || $0 == 123 }) { titleData = Data(titleData[..<stop]) }
        let name = decode(titleData).trimmingCharacters(in: .whitespacesAndNewlines)
        return PackageInfo(url: url, size: count, header: Data(prefix.prefix(headerSize)), title: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name)
    }
    static func supportedHeader(_ header: Data) -> Bool {
        guard header.count >= headerSize else { return false }
        if isUNB(header) { return true }
        if header.prefix(3) == Data("deb".utf8) { return true }
        guard [2, 3].contains(header[0x154]), header[0x14a] == 1, header[0x14b] == 0 else { return false }
        let guid = String(data: header[0xc8..<0xee], encoding: .ascii) ?? ""
        return guid.range(of: #"^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$"#, options: .regularExpression) != nil
    }
    static func isUNB(_ header: Data) -> Bool {
        guard header.count >= headerSize, header.prefix(3) == Data("UNB".utf8) else { return false }
        let guid = String(data: header[0x3f..<0x5f], encoding: .ascii) ?? ""
        return guid.range(of: #"^[0-9A-Fa-f]{32}$"#, options: .regularExpression) != nil
    }
    static func displayTitle(_ url: URL) -> String {
        if let info = try? readPackage(url, requireTail: false) { return info.title }
        guard let file = try? FileHandle(forReadingFrom: url) else { return "无法读取标题" }
        defer { try? file.close() }
        var raw = (try? file.read(upToCount: 180)) ?? Data()
        if let stop = raw.firstIndex(where: { $0 == 0 || $0 == 255 || $0 == 123 }) { raw = Data(raw[..<stop]) }
        let title = decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "未识别格式" : title
    }
    static func inspect(_ root: URL) throws -> Pen {
        let root = root.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else { throw PenError("设备路径包含符号链接。请选择点读笔磁盘根目录。") }
        let product = root.appendingPathComponent("SYS/INI/PRODUCT.INI")
        let custom = root.appendingPathComponent("USER/CUSTOM", isDirectory: true)
        guard product.resolvingSymlinksInPath() == product, custom.resolvingSymlinksInPath() == custom else { throw PenError("设备目录包含符号链接。") }
        try regular(product)
        let values = try custom.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw PenError("未找到 USER/CUSTOM 内容目录。") }
        let data = try Data(contentsOf: product)
        let lines = decode(data).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let deviceID = lines.first, deviceID.utf8.count >= 9, deviceID.utf8.allSatisfy({ (33...126).contains($0) }) else { throw PenError("无法识别 PRODUCT.INI 的设备标识，暂不写入。") }
        return Pen(root: root, deviceID: deviceID, model: lines.dropFirst().joined(separator: " · "), productData: data)
    }
    static func discover() -> [Pen] {
        let volumes = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
        return volumes.compactMap { try? inspect($0) }.sorted { $0.root.path < $1.root.path }
    }
    static func catalog(_ pen: Pen) throws -> [CatalogEntry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try fm.contentsOfDirectory(at: pen.custom, includingPropertiesForKeys: Array(keys))
        return urls.compactMap { url in
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.utf8.count == 3, stem.utf8.allSatisfy({ (48...57).contains($0) }),
                  let slot = Int(stem), (1...999).contains(slot), ["das", "dar"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return CatalogEntry(url: url, size: UInt64(max(0, values.fileSize ?? 0)), modified: values.contentModificationDate)
        }.sorted { $0.url.path < $1.url.path }
    }
    static func books(_ pen: Pen) throws -> [Book] {
        try catalog(pen).map { entry in
            Book(url: entry.url, slot: Int(entry.url.deletingPathExtension().lastPathComponent)!, size: entry.size, title: displayTitle(entry.url))
        }.sorted { ($0.slot, $0.ext) < ($1.slot, $1.ext) }
    }
    static func deviceBase(_ id: String) throws -> [UInt8] {
        let chars = Array(id.utf8)
        guard let seed = chars.first else { throw PenError("设备标识为空。") }
        let key = [0x52, 0x7a, 0xa7, 0xde]
        var result = [UInt8](repeating: 0, count: 6)
        for i in 0..<min((chars.count-1)/2, 5) {
            let left = Int(chars[1+i*2])-97, right = Int(chars[2+i*2])-65
            guard (0..<26).contains(left), (0..<26).contains(right) else { throw PenError("此设备标识编码尚未支持，暂不写入。") }
            result[i] = UInt8(truncatingIfNeeded: left*26+right-Int(seed)-key[i%4])
        }
        return result
    }
    static func bind(_ original: Data, penID: String, slot: Int, route: Route, cover: UInt32?, content: UInt32?, random: () -> UInt8 = { UInt8.random(in: 1...254) }) throws -> Data {
        guard supportedHeader(original), (1...999).contains(slot) else { throw PenError("点读包头或书名贴号无效。") }
        if isUNB(original) {
            guard route != .direct else { throw PenError("UNB 包保留原书内编码，请选择智能点读包或普通内容贴。") }
            let base = try deviceBase(penID)
            let selector = random()
            guard (1...254).contains(selector) else { throw PenError("设备绑定随机值无效。") }
            var h = original
            h[0x95] = selector
            for i in 0..<4 { h[0x96+i] = base[i+1] ^ base[0] ^ selector ^ 0xde }
            if route == .ordinary {
                guard let content, content <= UInt32(UInt16.max) else { throw PenError("UNB 普通内容贴起始码应为 0–65535。") }
                h.put16(UInt16(content) ^ original.u16(0xa1), at: 0x8d)
            }
            return h
        }
        if original.prefix(3) != Data("deb".utf8), route != .ordinary { throw PenError("此包属于普通内容贴格式，请选择普通内容贴（DAR）。") }
        if route == .direct, !(1...65535).contains(cover ?? 0) { throw PenError("封面码应为 1–65535。") }
        if route == .ordinary, content == nil { throw PenError("普通内容贴需要起始内容码。") }
        let base = try deviceBase(penID)
        var h = original
        for i in 0x156..<0x179 { h[i] = random() }
        let code = UInt32((route == .ordinary ? 0xdac0 : (slot <= 302 ? 0xfece : 0xfae6)) + slot)
        h.put32(code, at: 0x150)
        if route == .direct { h.put32(cover!, at: 0x14c) }
        if route == .ordinary { h.put32(content!, at: 0x17b) }
        h[0x157] = random()
        for i in 0..<4 { h[0x175+i] = UInt8(truncatingIfNeeded: code >> (i*8)) ^ h[0x157] ^ 0xde }
        h[0x156] = random()
        for i in 0..<4 { h[0x159+i] = base[i+1] ^ base[0] ^ h[0x156] ^ 0xde }
        return h
    }
    static func digest(_ url: URL, progress: (UInt64) -> Void = { _ in }) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        var done: UInt64 = 0
        while let d = try handle.read(upToCount: chunk), !d.isEmpty {
            sha.update(data: d)
            done += UInt64(d.count)
            progress(done)
        }
        return sha.finalize()
    }
    static func preservesHeader(_ old: Data, bound header: Data, route: Route) -> Bool {
        guard old.count == headerSize, header.count == headerSize else { return false }
        let unb = isUNB(old)
        for i in 0..<headerSize {
            let mutable: Bool
            if unb {
                mutable = (0x95..<0x9a).contains(i) || (route == .ordinary && (0x8d..<0x8f).contains(i))
            } else {
                mutable = (0x150..<0x154).contains(i) || (0x156..<0x179).contains(i) || (route == .direct && (0x14c..<0x150).contains(i)) || (route == .ordinary && (0x17b..<0x17f).contains(i))
            }
            if !mutable, old[i] != header[i] { return false }
        }
        return true
    }
    static func unchanged(_ source: URL, _ target: URL, header: Data, route: Route) throws -> Bool {
        guard try size(source) == size(target) else { return false }
        let a = try FileHandle(forReadingFrom: source), b = try FileHandle(forReadingFrom: target)
        defer { try? a.close(); try? b.close() }
        let actualHeader = try b.read(upToCount: headerSize)
        guard actualHeader == header else { return false }
        let old = try a.read(upToCount: headerSize) ?? Data()
        guard preservesHeader(old, bound: header, route: route) else { return false }
        while true {
            let x = try a.read(upToCount: chunk) ?? Data(), y = try b.read(upToCount: chunk) ?? Data()
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }
    static func revalidate(_ pen: Pen) throws {
        let fresh = try inspect(pen.root)
        guard fresh.productData == pen.productData else { throw PenError("点读笔已断开或设备信息改变，请重新连接。") }
    }
    static func install(source: URL, pen: Pen, slot: Int, route: Route, cover: UInt32?, content: UInt32?, fullVerification: Bool = true, progress: (Double) -> Void) throws -> URL {
        try revalidate(pen)
        let info = try readPackage(source)
        guard ["dab", "das", "dar"].contains(source.pathExtension.lowercased()) else { throw PenError("请选择 DAB / DAS / DAR 文件。") }
        let collisions = try books(pen).filter { $0.slot == slot && $0.ext == route.ext }
        guard collisions.isEmpty else { throw PenError("\(String(format: "%03d", slot)).\(route.ext) 已占用。请换一个书名贴号，或先移除原内容。") }
        let space = try fm.attributesOfFileSystem(forPath: pen.root.path)[.systemFreeSize] as? NSNumber
        guard let space, space.uint64Value >= info.size + 16*1024*1024 else { throw PenError("点读笔剩余空间不足，需额外保留 16 MB。") }
        let header = try bind(info.header, penID: pen.deviceID, slot: slot, route: route, cover: cover, content: content)
        guard preservesHeader(info.header, bound: header, route: route) else { throw PenError("安装参数改变了受保护的包头，安装已停止。") }
        let output = pen.custom.appendingPathComponent(String(format: "%03d.%@", slot, route.ext))
        let temporary = pen.custom.appendingPathComponent(".xdr-\(UUID().uuidString).tmp")
        // FileManager.createFile tries to set metadata which FSKit-backed FAT
        // volumes may reject with EPERM. NSData's exclusive write creates only
        // the file and works on these removable devices.
        try Data().write(to: temporary, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: temporary) }
        let src = try FileHandle(forReadingFrom: source), dst = try FileHandle(forWritingTo: temporary)
        var expectedHash = SHA256()
        let copyWeight = fullVerification ? 0.7 : 0.95
        do {
            try dst.write(contentsOf: header)
            if fullVerification { expectedHash.update(data: header) }
            try src.seek(toOffset: UInt64(headerSize))
            var done = UInt64(headerSize)
            while let data = try src.read(upToCount: chunk), !data.isEmpty {
                try dst.write(contentsOf: data)
                if fullVerification { expectedHash.update(data: data) }
                done += UInt64(data.count)
                progress(min(copyWeight, Double(done)/Double(info.size)*copyWeight))
            }
            guard done == info.size else { throw PenError("复制长度不符，安装已停止。") }
            progress(copyWeight)
            try dst.synchronize()
            try dst.close(); try src.close()
        } catch { try? dst.close(); try? src.close(); throw error }
        progress(fullVerification ? 0.75 : 0.98)
        if fullVerification {
            let actualHash = try digest(temporary) { done in
                progress(0.75 + min(1, Double(done) / Double(info.size)) * 0.24)
            }
            guard actualHash == expectedHash.finalize() else { throw PenError("写入后校验失败，临时文件已清理，请重新安装。") }
        } else {
            // Quick installation checks metadata and the small bound header;
            // it deliberately does not read back or hash the audio payload.
            guard try size(temporary) == info.size else { throw PenError("写入长度不符，请重新安装。") }
            let check = try FileHandle(forReadingFrom: temporary)
            defer { try? check.close() }
            guard try check.read(upToCount: headerSize) == header else { throw PenError("包头写入检查失败，请重新安装。") }
        }
        try revalidate(pen)
        guard !fm.fileExists(atPath: output.path) else { throw PenError("此书名贴号已被占用，请刷新后重试。") }
        // moveItem refuses to replace an existing destination.
        try fm.moveItem(at: temporary, to: output)
        progress(1)
        return output
    }
    static func validateRemoval(book: Book, pen: Pen) throws {
        try revalidate(pen)
        guard (1...999).contains(book.slot), ["das", "dar"].contains(book.ext),
              book.url.lastPathComponent.lowercased() == String(format: "%03d.%@", book.slot, book.ext),
              book.url.deletingLastPathComponent().standardizedFileURL.path == pen.custom.standardizedFileURL.path
        else { throw PenError("内容位置异常，请刷新书目后重试。") }
        try regular(book.url)
        guard try size(book.url) == book.size else { throw PenError("内容已变化，请刷新书目后重新选择。") }
    }
    static func remove(book: Book, pen: Pen) throws {
        try validateRemoval(book: book, pen: pen)
        try fm.removeItem(at: book.url)
    }
    static func remove(books: [Book], pen: Pen, progress: (Int, Int) -> Void = { _, _ in }) throws {
        guard !books.isEmpty else { return }
        guard Set(books.map(\.id)).count == books.count else { throw PenError("移除列表包含重复文件，请重新选择。") }
        // Check the entire selection before the first irreversible operation.
        do { for book in books { try validateRemoval(book: book, pen: pen) } }
        catch { throw PenError("尚未移除任何文件。\n\(error.localizedDescription)") }
        for (index, book) in books.enumerated() {
            do { try remove(book: book, pen: pen) }
            catch {
                let removed = books.prefix(index).map { $0.url.lastPathComponent }.joined(separator: "、")
                throw PenError("已移除 \(index)/\(books.count) 个，操作停止。\n\(removed.isEmpty ? "尚未移除任何文件。" : "已移除：\(removed)")\n未能移除：\(book.url.lastPathComponent)\n其余文件未处理。\n\(error.localizedDescription)")
            }
            progress(index + 1, books.count)
        }
    }

}
