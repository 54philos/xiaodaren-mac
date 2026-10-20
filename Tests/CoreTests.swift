import Foundation

@main struct CoreTests {
    static var passed = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw PenError("FAIL: \(label)") }
        passed += 1; print("PASS: \(label)")
    }
    static func rejects(_ label: String, _ work: () throws -> Void) throws {
        do { try work() } catch { passed += 1; print("PASS: \(label)"); return }
        throw PenError("FAIL: should reject \(label)")
    }
    static func fixture(_ directory: URL) throws -> (Pen, URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("SYS/INI"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("USER/CUSTOM"), withIntermediateDirectories: true)
        try Data("_iTaRcGaLeD\nfixture-908\n2026-10-20\n".utf8).write(to: directory.appendingPathComponent("SYS/INI/PRODUCT.INI"))
        let source = directory.appendingPathComponent("book.dab")
        var data = Data(repeating: 0xa5, count: PenCore.headerSize)
        data.replaceSubrange(0..<4, with: Data("deb3".utf8))
        data.append(Data((0..<(9*1024*1024)).map { UInt8(truncatingIfNeeded: $0) }))
        data.append(Data("EOID".utf8))
        try data.write(to: source)
        return (try PenCore.inspect(directory), source)
    }
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("pen-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let (pen, source) = try fixture(root)
        let info = try PenCore.readPackage(source)
        let sourceHash = try PenCore.digest(source)
        try expect(PenCore.deviceBase("_iTaRcGaLeD") == [0x32,0x38,0x34,0xce,0xba,0], "independent device-ID reference vector")
        var count: UInt8 = 0
        let bound = try PenCore.bind(info.header, penID: pen.deviceID, slot: 340, route: .direct, cover: 64570, content: nil) { count += 1; return count }
        try expect(bound.u32(0x150) == 0xfc3a && bound.u32(0x14c) == 64570, "direct route code at slot 340")
        try expect(Array(bound[0x175..<0x179]) == [0xc0,0x06,0xfa,0xfa], "book-token reference vector")
        try expect(Array(bound[0x159..<0x15d]) == [0xf1,0xfd,0x07,0x73], "device-token reference vector")
        let low = try PenCore.bind(info.header, penID: pen.deviceID, slot: 302, route: .smart, cover: nil, content: nil)
        let high = try PenCore.bind(info.header, penID: pen.deviceID, slot: 303, route: .smart, cover: nil, content: nil)
        try expect(low.u32(0x150) == 0xfffc && high.u32(0x150) == 0xfc15, "DAS slot-code boundary 302 / 303")
        try rejects("invalid slot refused") { _ = try PenCore.bind(info.header, penID: pen.deviceID, slot: 1000, route: .smart, cover: nil, content: nil) }
        try rejects("invalid device encoding refused") { _ = try PenCore.deviceBase("invalid-device-id") }
        var installationProgress: [Double] = []
        let output = try PenCore.install(source: source, pen: pen, slot: 340, route: .direct, cover: 64570, content: nil) { installationProgress.append($0) }
        try expect(zip(installationProgress, installationProgress.dropFirst()).allSatisfy { $0 <= $1 } && installationProgress.last == 1, "install progress stays monotonic and completes")
        try expect(installationProgress.filter { $0 > 0.75 && $0 < 1 }.count >= 2, "full readback reports progress across chunks")
        let written = try PenCore.readPackage(output)
        try expect(PenCore.unchanged(source, output, header: written.header, route: .direct), "stream install preserves all immutable bytes across chunks")
        try expect(PenCore.digest(source) == sourceHash, "source DAB unchanged")
        let originalInstalledHash = try PenCore.digest(output)
        for (label, offset) in [("header", UInt64(20)), ("payload", UInt64(PenCore.headerSize + PenCore.chunk + 8))] {
            var corrupted = false
            var injectionError: Error?
            try rejects("single-pass verification detects corrupted \(label)") {
                _ = try PenCore.install(source: source, pen: pen, slot: 339, route: .direct, cover: 64570, content: nil) { value in
                    guard value == 0.75, !corrupted else { return }
                    do {
                        let temporary = try fm.contentsOfDirectory(at: pen.custom, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".xdr-") }!
                        let handle = try FileHandle(forUpdating: temporary)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: offset)
                        let byte = try handle.read(upToCount: 1)!.first!
                        try handle.seek(toOffset: offset)
                        try handle.write(contentsOf: Data([byte ^ 1]))
                        try handle.synchronize()
                        corrupted = true
                    } catch { injectionError = error }
                }
            }
            try expect(corrupted && injectionError == nil, "\(label) corruption injected after copy and before readback")
            try expect(!fm.fileExists(atPath: pen.custom.appendingPathComponent("339.das").path) && fm.contentsOfDirectory(atPath: pen.custom.path).allSatisfy { !$0.hasPrefix(".xdr-") }, "failed \(label) verification leaves no installed or temporary file")
        }
        try rejects("occupied slot refused without overwrite") { _ = try PenCore.install(source: source, pen: pen, slot: 340, route: .direct, cover: 64570, content: nil) { _ in } }
        try expect(PenCore.digest(output) == originalInstalledHash, "occupied content preserved")
        let book = try PenCore.books(pen).first!
        try fm.createSymbolicLink(at: pen.custom.appendingPathComponent("001.das"), withDestinationURL: source)
        try expect(PenCore.books(pen).count == 1, "symlink content ignored")
        let linked = Book(url: pen.custom.appendingPathComponent("001.das"), slot: 1, size: info.size, title: "symlink")
        try rejects("removal refuses symlink") { try PenCore.remove(book: linked, pen: pen) }
        let outside = root.appendingPathComponent("169.das")
        try Data("keep".utf8).write(to: outside)
        try rejects("removal refuses file outside content directory") { try PenCore.remove(book: Book(url: outside, slot: 169, size: 4, title: "outside"), pen: pen) }
        try expect(fm.fileExists(atPath: outside.path), "out-of-directory file retained")
        try rejects("removal refuses mismatched slot") { try PenCore.remove(book: Book(url: book.url, slot: 341, size: book.size, title: book.title), pen: pen) }
        let changing = pen.custom.appendingPathComponent("003.dar")
        try Data("old".utf8).write(to: changing)
        let stale = Book(url: changing, slot: 3, size: 3, title: "stale")
        try Data("changed".utf8).write(to: changing)
        try rejects("removal refuses stale file size") { try PenCore.remove(book: stale, pen: pen) }
        try expect(fm.fileExists(atPath: changing.path) && fm.fileExists(atPath: book.url.path), "failed removal retains content")
        try rejects("batch preflight refuses symlink before deleting any selected file") { try PenCore.remove(books: [book, linked], pen: pen) }
        try expect(fm.fileExists(atPath: book.url.path), "batch preflight retains earlier valid selection")
        try rejects("batch refuses duplicate selection") { try PenCore.remove(books: [book, book], pen: pen) }
        let stamp = try PenCore.catalog(pen)
        try expect(PenCore.catalog(pen) == stamp, "unchanged library has stable metadata stamp")
        try Data("changed again".utf8).write(to: changing)
        try expect(PenCore.catalog(pen) != stamp, "metadata stamp detects external content change")
        let corrupt = root.appendingPathComponent("corrupt.dab")
        try Data("deb".utf8).write(to: corrupt)
        try rejects("truncated DAB refused") { _ = try PenCore.readPackage(corrupt) }
        let badTail = root.appendingPathComponent("badtail.dab")
        try fm.copyItem(at: source, to: badTail)
        let file = try FileHandle(forWritingTo: badTail)
        try file.seek(toOffset: info.size-4); try file.write(contentsOf: Data("FAIL".utf8)); try file.close()
        try rejects("missing EOID refused") { _ = try PenCore.readPackage(badTail) }
        var unbBytes = try Data(contentsOf: source)
        unbBytes.replaceSubrange(0..<4, with: Data("UNB1".utf8))
        unbBytes.replaceSubrange(0x3f..<0x5f, with: Data("FA92B0895F1142D3B81A0E7389D41345".utf8))
        unbBytes.put16(168, at: 0x5f)
        unbBytes[0x61] = 2
        unbBytes.put16(0x5728, at: 0xa1)
        let unbSource = root.appendingPathComponent("169-test.dab")
        try unbBytes.write(to: unbSource)
        let unbInfo = try PenCore.readPackage(unbSource)
        try expect(unbInfo.isUNB && unbInfo.unbDefaultRoute == .smart, "UNB format and smart default recognized")
        let tokenVector = try PenCore.bind(unbInfo.header, penID: pen.deviceID, slot: 169, route: .smart, cover: nil, content: nil, random: { 37 })
        try expect(Array(tokenVector[0x95..<0x9a]) == [0x25,0xf1,0xfd,0x07,0x73], "UNB independent device binding reference vector")
        try expect(tokenVector.u16(0x5f) == 168, "UNB preserves embedded book/OID code")
        try expect((0..<PenCore.headerSize).allSatisfy { (0x95..<0x9a).contains($0) || tokenVector[$0] == unbInfo.header[$0] }, "UNB smart binder changes only five device-binding bytes")
        let otherDevice = try PenCore.bind(unbInfo.header, penID: "_iUaRcGaLeD", slot: 169, route: .smart, cover: nil, content: nil, random: { 37 })
        try expect(otherDevice[0x96..<0x9a] != tokenVector[0x96..<0x9a], "UNB binding responds to device identity")
        let unbBookURL = pen.custom.appendingPathComponent("169.das")
        try expect(!fm.fileExists(atPath: unbBookURL.path), "UNB target absent before fresh install")
        _ = try PenCore.install(source: unbSource, pen: pen, slot: 169, route: .smart, cover: nil, content: nil) { _ in }
        let independentlyInstalled = try PenCore.readPackage(unbBookURL)
        let expectedInstalled = try PenCore.bind(unbInfo.header, penID: pen.deviceID, slot: 169, route: .smart, cover: nil, content: nil, random: { independentlyInstalled.header[0x95] })
        try expect(independentlyInstalled.header == expectedInstalled, "UNB fresh install needs no previous installed file")
        try expect(PenCore.unchanged(unbSource, unbBookURL, header: independentlyInstalled.header, route: .smart), "UNB fresh install preserves full payload")
        try expect(Data(contentsOf: unbSource) == unbBytes, "UNB source DAB retained")
        let unbHash = try PenCore.digest(unbBookURL)
        try rejects("UNB occupied target preserved") { _ = try PenCore.install(source: unbSource, pen: pen, slot: 169, route: .smart, cover: nil, content: nil) { _ in } }
        try expect(PenCore.digest(unbBookURL) == unbHash, "UNB occupied file unchanged")
        var ordinaryHeader = unbInfo.header
        ordinaryHeader.put16(0, at: 0x5f)
        let ordinaryBound = try PenCore.bind(ordinaryHeader, penID: pen.deviceID, slot: 459, route: .ordinary, cover: nil, content: 1, random: { 37 })
        try expect(ordinaryBound.u16(0x8d) == 0x5729, "UNB ordinary content XOR reference vector")
        try expect(ordinaryBound.u16(0x5f) == 0, "UNB ordinary preserves embedded book field")
        try rejects("UNB content code overflow refused") { _ = try PenCore.bind(ordinaryHeader, penID: pen.deviceID, slot: 459, route: .ordinary, cover: nil, content: 65536) }
        try rejects("UNB cover rewriting refused") { _ = try PenCore.bind(unbInfo.header, penID: pen.deviceID, slot: 169, route: .direct, cover: 123, content: nil) }
        try rejects("UNB invalid binding selector refused") { _ = try PenCore.bind(unbInfo.header, penID: pen.deviceID, slot: 169, route: .smart, cover: nil, content: nil, random: { 0 }) }
        try expect(fm.contentsOfDirectory(atPath: pen.custom.path).allSatisfy { !$0.hasPrefix(".xdr-") }, "UNB fresh install cleans temporary file")
        let emptyRoot = root.appendingPathComponent("empty-pen", isDirectory: true)
        let (emptyPen, _) = try fixture(emptyRoot)
        try expect(PenCore.books(emptyPen).isEmpty, "UNB independent test begins with an entirely empty content library")
        let firstBook = try PenCore.install(source: unbSource, pen: emptyPen, slot: 169, route: .smart, cover: nil, content: nil) { _ in }
        try expect(PenCore.books(emptyPen).count == 1 && PenCore.unchanged(unbSource, firstBook, header: PenCore.readPackage(firstBook).header, route: .smart), "UNB first install succeeds with no old package of any kind")
        let extraBook = emptyPen.custom.appendingPathComponent("002.dar")
        try fm.copyItem(at: firstBook, to: extraBook)
        let bulkSelection = try PenCore.books(emptyPen)
        try expect(bulkSelection.map(\.slot) == [2, 169], "default library order uses numeric slot across content types")
        var removalProgress: [Int] = []
        try PenCore.remove(books: bulkSelection, pen: emptyPen) { done, _ in removalProgress.append(done) }
        try expect(PenCore.books(emptyPen).isEmpty && removalProgress == [1, 2], "batch removes all selected content and reports completion")
        for slot in 1...3 {
            try Data("fixture".utf8).write(to: emptyPen.custom.appendingPathComponent(String(format: "%03d.das", slot)))
        }
        let interruptedSelection = try PenCore.books(emptyPen)
        var batchFailure = ""
        do {
            try PenCore.remove(books: interruptedSelection, pen: emptyPen) { done, _ in
                if done == 1 { try? Data("externally changed".utf8).write(to: interruptedSelection[1].url) }
            }
        } catch { batchFailure = error.localizedDescription }
        try expect(batchFailure.contains("已移除 1/3") && batchFailure.contains("002.das"), "batch reports exact partial completion on external change")
        try expect(!fm.fileExists(atPath: interruptedSelection[0].url.path) && fm.fileExists(atPath: interruptedSelection[1].url.path) && fm.fileExists(atPath: interruptedSelection[2].url.path), "batch stops after failure and leaves remaining files")
        let (quickPen, _) = try fixture(root.appendingPathComponent("quick-pen"))
        var quickProgress: [Double] = []
        let quickBook = try PenCore.install(source: source, pen: quickPen, slot: 12, route: .direct, cover: 64570, content: nil, fullVerification: false) { quickProgress.append($0) }
        try expect(PenCore.unchanged(source, quickBook, header: PenCore.readPackage(quickBook).header, route: .direct), "quick installation preserves all payload bytes and binding")
        try expect(quickProgress.contains(0.98) && quickProgress.last == 1 && zip(quickProgress, quickProgress.dropFirst()).allSatisfy { $0 <= $1 }, "quick installation finishes with monotonic copy and commit progress")
        let quickUNB = try PenCore.install(source: unbSource, pen: quickPen, slot: 169, route: .smart, cover: nil, content: nil, fullVerification: false) { _ in }
        try expect(PenCore.unchanged(unbSource, quickUNB, header: PenCore.readPackage(quickUNB).header, route: .smart), "quick UNB install needs no previous package")
        for damage in ["header", "length"] {
            var injected = false
            try rejects("quick installation rejects damaged \(damage)") {
                _ = try PenCore.install(source: source, pen: quickPen, slot: 13, route: .smart, cover: nil, content: nil, fullVerification: false) { value in
                    guard value == 0.98 else { return }
                    do {
                        let temporary = try fm.contentsOfDirectory(at: quickPen.custom, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".xdr-") }!
                        let file = try FileHandle(forWritingTo: temporary)
                        defer { try? file.close() }
                        if damage == "length" { try file.truncate(atOffset: info.size - 1) }
                        else { try file.seek(toOffset: 20); try file.write(contentsOf: Data([0])) }
                        try file.synchronize(); injected = true
                    } catch { }
                }
            }
            try expect(injected && !fm.fileExists(atPath: quickPen.custom.appendingPathComponent("013.das").path), "quick \(damage) check fails before publishing book")
        }
        try expect(PenCore.digest(source) == sourceHash && Data(contentsOf: unbSource) == unbBytes, "quick mode retains source packages")
        try expect(fm.contentsOfDirectory(atPath: quickPen.custom.path).allSatisfy { !$0.hasPrefix(".xdr-") }, "quick mode cleans failed temporary files")
        let removedBook = try PenCore.books(pen).first { $0.slot == 169 }!
        let beforeRemoval = Set(try fm.contentsOfDirectory(atPath: pen.custom.path))
        try PenCore.remove(book: removedBook, pen: pen)
        try expect(!fm.fileExists(atPath: unbBookURL.path), "direct removal deletes selected installed file")
        try expect(Set(fm.contentsOfDirectory(atPath: pen.custom.path)) == beforeRemoval.subtracting(["169.das"]), "direct removal leaves every other content file and creates no backup")
        try expect(PenCore.digest(source) == sourceHash && Data(contentsOf: unbSource) == unbBytes, "direct removal retains original source packages")
        try expect(PenCore.digest(output) == originalInstalledHash, "direct removal retains other installed book byte-for-byte")
        _ = try PenCore.install(source: unbSource, pen: pen, slot: 169, route: .smart, cover: nil, content: nil) { _ in }
        try expect(PenCore.unchanged(unbSource, unbBookURL, header: PenCore.readPackage(unbBookURL).header, route: .smart), "UNB independently reinstalls after direct removal")
        try Data("_aAaAaAaAaA\nchanged\n".utf8).write(to: pen.root.appendingPathComponent("SYS/INI/PRODUCT.INI"))
        try rejects("device identity change detected") { try PenCore.revalidate(pen) }
        try rejects("removal refuses changed device identity") { try PenCore.remove(book: book, pen: pen) }
        print("\(passed) checks passed")
        if CommandLine.arguments.count == 3 {
            let real = try PenCore.inspect(URL(fileURLWithPath: CommandLine.arguments[1]))
            let source = URL(fileURLWithPath: CommandLine.arguments[2])
            let info = try PenCore.readPackage(source)
            let installed = real.custom.appendingPathComponent("570.dar")
            let existing = try PenCore.readPackage(installed)
            let generated = try PenCore.bind(info.header, penID: real.deviceID, slot: 570, route: .ordinary, cover: nil, content: 1)
            try expect(generated.u32(0x150) == existing.header.u32(0x150), "real 908 sample: book code matches existing 570.dar")
            let base = try PenCore.deviceBase(real.deviceID)
            for i in 0..<4 {
                try expect(existing.header[0x159+i] == base[i+1] ^ base[0] ^ existing.header[0x156] ^ 0xde, "real 908 device token byte \(i)")
            }
            let local = root.appendingPathComponent("570-offline.dar")
            try fm.copyItem(at: source, to: local)
            let handle = try FileHandle(forWritingTo: local)
            try handle.write(contentsOf: generated); try handle.synchronize(); try handle.close()
            try expect(PenCore.unchanged(source, local, header: generated, route: .ordinary), "real DAB offline binding preserves payload")
            try expect(PenCore.unchanged(source, installed, header: existing.header, route: .ordinary), "real DAB matches device package outside binding fields")
            try expect(info.title.contains("Wow English"), "Chinese GB18030 title decoding")
            print("Real device inventory: \(try PenCore.books(real).count) packages")
            print("Read-only device audit complete; \(passed) total checks passed")
        }
    }
}
