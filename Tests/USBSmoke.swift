import Foundation

// Explicit, temporary hardware test. Never replaces an occupied slot.
@main struct USBSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw PenError("Usage: USBSmoke /Volumes/PEN SOURCE.dab") }
        let pen = try PenCore.inspect(URL(fileURLWithPath: CommandLine.arguments[1]))
        let source = URL(fileURLWithPath: CommandLine.arguments[2])
        let sourceInfo = try PenCore.readPackage(source)
        let route: Route = sourceInfo.isUNB ? sourceInfo.unbDefaultRoute : .ordinary
        let before = try PenCore.books(pen)
        let slots = Set(before.filter { $0.ext == route.ext }.map(\.slot))
        guard let slot = (1...998).reversed().first(where: { !slots.contains($0) }) else { throw PenError("没有空闲测试贴号。") }
        let sourceHash = try PenCore.digest(source)
        let destination = try PenCore.install(source: source, pen: pen, slot: slot, route: route, cover: nil, content: route == .ordinary ? 1 : nil) { _ in }
        let installedHash = try PenCore.digest(destination)
        var removed = false
        defer {
            if !removed, (try? PenCore.digest(destination)) == installedHash { try? FileManager.default.removeItem(at: destination) }
        }
        let installed = try PenCore.readPackage(destination)
        if sourceInfo.isUNB {
            let expectedHeader = try PenCore.bind(sourceInfo.header, penID: pen.deviceID, slot: slot, route: route, cover: nil, content: route == .ordinary ? 1 : nil, random: { installed.header[0x95] })
            guard expectedHeader == installed.header else { throw PenError("Independent UNB token verification failed") }
        }
        guard try PenCore.unchanged(source, destination, header: installed.header, route: route),
              try PenCore.digest(source) == sourceHash else { throw PenError("USB round trip verification failed") }
        try PenCore.revalidate(pen)
        guard try PenCore.digest(destination) == installedHash else { throw PenError("测试文件发生变化，停止清理。") }
        try FileManager.default.removeItem(at: destination)
        removed = true
        let after = try PenCore.books(pen)
        guard before == after else { throw PenError("测试前后书目列表不同，请检查。") }
        let report: [String: Any] = [
            "test": "temporary USB install/readback/remove",
            "temporary_slot": slot,
            "format": sourceInfo.isUNB ? "UNB independent install" : "common DAB",
            "extension": route.ext,
            "bytes": installed.size,
            "source_sha256": sourceHash.map { String(format: "%02x", $0) }.joined(),
            "usb_sha256": installedHash.map { String(format: "%02x", $0) }.joined(),
            "payload_verified": true,
            "temporary_file_removed": removed,
            "existing_books_unchanged": true,
            "existing_book_count": after.count,
            "physical_playback_test": "pending"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
