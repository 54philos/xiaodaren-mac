import Foundation
import CryptoKit

// Generates binding from DAB + PRODUCT.INI only, with a fixed audit selector.
// No existing installed file or backup is opened by this audit.
@main struct UNBReadOnlyAudit {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw PenError("Usage: UNBReadOnlyAudit SOURCE.dab PEN_ROOT EXPECTED_SHA256") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let pen = try PenCore.inspect(URL(fileURLWithPath: CommandLine.arguments[2]))
        let sourceInfo = try PenCore.readPackage(source)
        let header = try PenCore.bind(sourceInfo.header, penID: pen.deviceID, slot: 169, route: .smart, cover: nil, content: nil, random: { 0x52 })
        var sha = SHA256()
        sha.update(data: header)
        let stream = try FileHandle(forReadingFrom: source)
        defer { try? stream.close() }
        try stream.seek(toOffset: UInt64(PenCore.headerSize))
        while let data = try stream.read(upToCount: PenCore.chunk), !data.isEmpty { sha.update(data: data) }
        let actual = sha.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == CommandLine.arguments[3].lowercased() else { throw PenError("Generated package does not match the known-working original") }
        print("Native independent UNB audit passed: \(sourceInfo.size) bytes, generated SHA256 \(actual); no installed package or backup read; no device files changed")
    }
}
