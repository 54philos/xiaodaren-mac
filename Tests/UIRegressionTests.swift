import Foundation
import AppKit

@main @MainActor struct UIRegressionTests {
    static var passed = 0
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw PenError("FAIL: \(label)") }
        passed += 1; print("PASS: \(label)")
    }
    static func waitUntil(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard predicate() else { throw PenError("Timed out waiting for model") }
    }
    static func main() throws {
        _ = NSApplication.shared
        let pen = Pen(root: URL(fileURLWithPath: "/tmp/diandu-ui-fixture"), deviceID: "fixture", model: "908", productData: Data())
        var books: [Book] = []
        for number in 1...40 {
            let url = pen.custom.appendingPathComponent(String(format: "%03d.dar", number))
            let title = "测试书目 \(number) " + String(repeating: "长书名测试", count: 12)
            books.append(Book(url: url, slot: number, size: UInt64(number * 1024 * 1024), title: title))
        }
        var ejections = 0, reads = 0
        let model = PenModel(startMonitoring: false, ejectDevice: { _ in ejections += 1 }, loadCatalog: { _ in
            reads += 1
            throw PenError("Unexpected read after eject")
        })
        model.pen = pen; model.devices = [pen]; model.books = books
        model.selection = [books[0].id]; model.freeBytes = 123
        model.eject()
        try waitUntil { !model.busy }
        try expect(ejections == 1 && reads == 0, "eject succeeds without refreshing unmounted catalog")
        try expect(model.pen == nil && model.devices.isEmpty && model.books.isEmpty && model.selection.isEmpty, "eject clears connected device and book selection")
        try expect(model.freeBytes == nil && !model.loadingBooks, "eject clears free space and loading state")
        try expect(model.ejectSucceeded && model.errorText == nil && model.status == "已安全推出，现在可以拔掉点读笔了。", "success displays concise Chinese unplug message")
        model.eject()
        try expect(ejections == 1, "eject cannot run again on disconnected device")

        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let stale = PenModel(startMonitoring: false, ejectDevice: { _ in }, loadCatalog: { _ in
            started.signal(); release.wait(); defer { finished.signal() }
            throw PenError("The file CUSTOM could not be opened")
        })
        stale.select(pen)
        guard started.wait(timeout: .now() + 3) == .success else { throw PenError("Catalog did not start") }
        stale.eject()
        try waitUntil { !stale.busy }
        release.signal()
        guard finished.wait(timeout: .now() + 3) == .success else { throw PenError("Catalog did not finish") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try expect(stale.pen == nil && stale.errorText == nil && stale.ejectSucceeded, "late catalog failure cannot replace successful eject with an error")

        let failure = PenModel(startMonitoring: false, ejectDevice: { _ in throw PenError("Resource busy") })
        failure.pen = pen; failure.books = books
        failure.eject()
        try waitUntil { !failure.busy }
        try expect(failure.pen != nil && failure.books.count == 40 && !failure.ejectSucceeded, "failed eject retains device and never claims success")
        try expect(failure.errorText == "未能安全推出。请关闭正在使用点读笔的其他程序后，再试一次。", "failed eject gives Chinese retry guidance")

        let single = RemovalConfirmation.makeAlert(books: [books[0]])
        try expect(single.messageText == "移除 001.dar？" && single.accessoryView == nil && single.informativeText.contains(books[0].title), "single removal preserves existing confirmation")
        let pair = RemovalConfirmation.makeAlert(books: Array(books.prefix(2)))
        let many = RemovalConfirmation.makeAlert(books: books)
        pair.layout(); many.layout()
        try expect(pair.messageText == "移除 2 个文件？" && many.messageText == "移除 40 个文件？", "batch removal title reflects selection count")
        try expect(pair.window.frame.size == many.window.frame.size, "batch dialog size stays fixed for two or forty long book names")
        let scroll = many.accessoryView as! NSScrollView
        let text = scroll.documentView as! NSTextView
        try expect(scroll.frame.size == NSSize(width: 260, height: 112) && scroll.hasVerticalScroller && !scroll.hasHorizontalScroller, "batch details use compact fixed size vertical scrolling")
        try expect(books.allSatisfy { text.string.contains($0.url.lastPathComponent) && text.string.contains($0.title) }, "batch detail lists every filename and book title")
        try expect(text.string.contains(ByteCountFormatter.string(fromByteCount: Int64(books[0].size), countStyle: .file)) && text.frame.height > scroll.contentSize.height, "batch details include sizes and overflow remains scrollable")
        try expect(many.buttons.map(\.title) == ["取消", "移除"], "destructive confirmation retains cancel as default first action")
        print("\(passed) UI regression checks passed")
    }
}
