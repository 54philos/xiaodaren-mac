import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class PenModel: ObservableObject {
    @Published var devices: [Pen] = []
    @Published var pen: Pen?
    @Published var books: [Book] = []
    @Published var selection = Set<Book.ID>()
    @Published var sortOrder = [KeyPathComparator(\Book.slot), KeyPathComparator(\Book.ext)]
    @Published var package: PackageInfo?
    @Published var route = Route.smart
    @Published var slot = "001"
    @Published var cover = ""
    @Published var content = "1"
    @Published var search = ""
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "请关机后，用数据线连接小达人点读笔。"
    @Published var errorText: String?
    @Published var loadingBooks = false
    @Published var freeBytes: Int64?
    @Published var fullVerification = UserDefaults.standard.bool(forKey: "fullVerification") {
        didSet { UserDefaults.standard.set(fullVerification, forKey: "fullVerification") }
    }
    private var timer: Timer?
    private var discovering = false
    private var refreshTicket = UUID()
    private var catalogStamp: [CatalogEntry] = []
    var filteredBooks: [Book] {
        books.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.lastPathComponent.localizedCaseInsensitiveContains(search) }.sorted(using: sortOrder)
    }
    var selectedBooks: [Book] { filteredBooks.filter { selection.contains($0.id) } }
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.discover() }
        }
    }
    func discover() {
        guard !busy, !discovering, !loadingBooks else { return }
        discovering = true
        let current = pen
        let ticket = refreshTicket
        DispatchQueue.global(qos: .utility).async {
            let found = PenCore.discover()
            let fresh = current.flatMap { try? PenCore.inspect($0.root) }
            let currentValid = fresh?.productData == current?.productData && fresh != nil
            let stamp = currentValid ? current.flatMap { try? PenCore.catalog($0) } : nil
            DispatchQueue.main.async {
                self.discovering = false
                guard !self.busy, self.refreshTicket == ticket else { return }
                self.devices = found
                if current != nil, !currentValid {
                    self.refreshTicket = UUID(); self.loadingBooks = false; self.freeBytes = nil
                    self.pen = nil; self.books = []; self.selection = []; self.catalogStamp = []; self.status = "点读笔已断开。"
                } else if self.pen == nil, found.count == 1 {
                    self.select(found[0])
                } else if let current, let stamp, stamp != self.catalogStamp {
                    self.select(current, announce: false, preserveContent: true)
                }
            }
        }
    }
    func select(_ device: Pen, announce: Bool = true, preserveContent: Bool = false) {
        refreshTicket = UUID()
        let ticket = refreshTicket
        pen = device
        if !preserveContent { selection = []; books = []; freeBytes = nil }
        loadingBooks = true
        if announce { status = "已连接，正在后台读取书目…" }
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                let stamp = try PenCore.catalog(device)
                return (try PenCore.books(device), stamp)
            }
            let disk = try? FileManager.default.attributesOfFileSystem(forPath: device.root.path)
            let free = (disk?[.systemFreeSize] as? NSNumber)?.int64Value
            DispatchQueue.main.async {
                guard self.refreshTicket == ticket, !self.busy else { return }
                self.loadingBooks = false
                self.freeBytes = free
                switch result {
                case .success(let (list, stamp)):
                    self.books = list
                    self.catalogStamp = stamp
                    self.selection.formIntersection(Set(self.filteredBooks.map(\.id)))
                    if announce { self.status = "已连接 · \(list.count) 个点读包" }
                case .failure(let error): self.errorText = error.localizedDescription
                }
            }
        }
    }
    func refresh(announce: Bool = true) {
        guard !busy else { return }
        if let pen { select(pen, announce: announce) }
        else { discover() }
    }
    func chooseDevice() {
        let panel = NSOpenPanel()
        panel.title = "选择点读笔磁盘根目录"
        panel.message = "请选择包含 SYS 和 USER 文件夹的点读笔磁盘。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url {
            do { select(try PenCore.inspect(url)) } catch { errorText = error.localizedDescription }
        }
    }
    func openPackage(_ url: URL) {
        guard !busy else { return }
        do {
            guard ["dab", "das", "dar"].contains(url.pathExtension.lowercased()) else { throw PenError("请选择 .dab 点读包，或备份的 .das / .dar 文件。") }
            let info = try PenCore.readPackage(url)
            package = info
            selection = []
            if info.isUNB {
                route = info.unbDefaultRoute
                content = String(info.content)
                slot = ""
                search = ""
                if let number = Int(url.deletingPathExtension().lastPathComponent.prefix(while: { $0.isNumber })), (1...999).contains(number) {
                    slot = String(format: "%03d", number)
                    search = slot
                }
                status = "UNB 包已读取，可独立安装；请按原包编号和商家说明核对参数。"
                return
            }
            route = (url.pathExtension.lowercased() == "dar" || !info.isSmart) ? .ordinary : (info.declared == nil ? .smart : .direct)
            content = String(info.content)
            cover = info.cover > 0 && info.cover <= 65535 ? String(info.cover) : ""
            if let declared = info.declared { slot = String(format: "%03d", declared.slot); cover = String(declared.cover) }
            if !info.isSmart {
                let components = info.title.split(separator: "-", maxSplits: 2)
                if let first = components.first, let number = Int(first), (1...999).contains(number) { slot = String(format: "%03d", number) }
                if components.count >= 2, let number = UInt32(components[1]) { content = String(number) }
            }
            status = "点读包已读取，请核对书名贴号。"
        } catch { errorText = error.localizedDescription }
    }
    func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = "选择点读包"
        panel.allowedContentTypes = ["dab", "das", "dar"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { openPackage(url) }
    }
    func resetInstallForm() {
        package = nil
        route = .smart; slot = "001"; cover = ""; content = "1"
        search = ""; selection = []
        sortOrder = [KeyPathComparator(\Book.slot), KeyPathComparator(\Book.ext)]
    }
    func run(_ message: String, onSuccess: (() -> Void)? = nil, work: @escaping () throws -> String) {
        refreshTicket = UUID()
        loadingBooks = false
        busy = true; status = message; progress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let text):
                    onSuccess?()
                    self.status = text; self.progress = 1
                case .failure(let error): self.errorText = error.localizedDescription; self.status = "操作未完成 · 请查看提示"
                }
                self.refresh(announce: false)
            }
        }
    }
    func install() {
        guard !busy, let pen, let package else { return }
        guard let slotNumber = Int(slot), (1...999).contains(slotNumber) else { errorText = "书名贴号应为 001–999。"; return }
        let route = route, coverCode = UInt32(cover), contentNumber = UInt32(content)
        let verify = fullVerification
        if route == .direct, coverCode == nil { errorText = "请输入书本原有的封面码。"; return }
        if route == .ordinary, contentNumber == nil { errorText = "请输入有效的起始内容码。"; return }
        run("正在安装，请保持连接…", onSuccess: { self.resetInstallForm() }) {
            let url = try PenCore.install(source: package.url, pen: pen, slot: slotNumber, route: route, cover: coverCode, content: contentNumber, fullVerification: verify) { value in
                DispatchQueue.main.async {
                    self.progress = value
                    let copyWeight = verify ? 0.7 : 0.95
                    if value < copyWeight {
                        self.status = "正在复制点读包（\(min(100, Int(value / copyWeight * 100)))%），请保持连接…"
                    } else if value < (verify ? 0.75 : 0.98) {
                        self.status = "复制完成，正在将数据写入点读笔，请保持连接…"
                    } else if value < 1, verify {
                        self.status = "正在回读校验（\(min(100, Int(((value - 0.75) / 0.24 * 100).rounded())))%），请保持连接…"
                    } else if value < 1 {
                        self.status = "正在完成安装，请保持连接…"
                    }
                }
            }
            return "\(url.lastPathComponent) \(verify ? "安装并校验完成" : "安装完成") · 请安全推出后测试点读"
        }
    }
    func removeSelected() {
        let chosen = selectedBooks
        guard !busy, !chosen.isEmpty, let pen else { return }
        let count = chosen.count
        let total = chosen.reduce(UInt64(0)) { $0 + $1.size }
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "移除 \(chosen[0].url.lastPathComponent)？" : "移除所选 \(count) 个点读包？"
        alert.informativeText = "\(count == 1 ? chosen[0].title + "\n\n" : "")共 \(count) 个，\(size)。\n将直接删除点读笔中的所选文件，不会创建备份，移除后无法撤销。电脑上的源点读包不受影响。"
        if count > 1 {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: CGFloat(min(240, count * 40))))
            scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isSelectable = true
            text.font = .systemFont(ofSize: 12)
            text.string = chosen.map { "\($0.url.lastPathComponent)  ·  \($0.title)" }.joined(separator: "\n\n")
            text.isVerticallyResizable = true; text.autoresizingMask = .width
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        run("正在移除 \(count) 个点读包，请保持连接…") {
            try PenCore.remove(books: chosen, pen: pen) { done, total in
                DispatchQueue.main.async {
                    self.progress = Double(done) / Double(total)
                    self.status = "正在移除（\(done)/\(total)），请保持连接…"
                }
            }
            return "已移除 \(count) 个点读包 · \(size)"
        }
    }
    func eject() {
        guard let pen else { return }
        run("正在安全推出…") {
            try NSWorkspace.shared.unmountAndEjectDevice(at: pen.root)
            return "已安全推出，现在可以拔线并测试点读。"
        }
    }
}

struct PenView: View {
    @ObservedObject var model: PenModel
    private static let brandIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    if let icon = Self.brandIcon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 34, height: 34).accessibilityHidden(true)
                    }
                    Text("点读伙伴").font(.system(size: 23, weight: .bold)).foregroundStyle(.teal)
                }
                Text("小达人 Mac 助手").font(.subheadline).foregroundStyle(.secondary)
                Divider()
                Label(model.pen == nil ? "等待连接" : "点读笔已连接", systemImage: model.pen == nil ? "cable.connector" : "checkmark.circle.fill")
                    .foregroundStyle(model.pen == nil ? Color.secondary : Color.teal)
                if model.pen != nil {
                    Text("\(model.books.count) 个已装点读包").font(.subheadline)
                    if let free = model.freeBytes {
                        Text("剩余 \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("关机后连接数据线。\n请使用支持传输数据的线材。").font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                }
                if model.devices.count > 1 {
                    ForEach(model.devices, id: \.root) { pen in
                        Button(pen.root.lastPathComponent) { model.select(pen) }
                    }
                }
                Spacer()
                Button("安全推出", systemImage: "eject") { model.eject() }.disabled(model.pen == nil)
                Text("实验版 0.5.0").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(width: 220).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
            .disabled(model.busy)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("让好故事，回到点读笔里").font(.system(size: 25, weight: .semibold))
                        Text("导入点读包，核对贴号，安装后安全推出。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "book.closed.fill").font(.system(size: 35)).foregroundStyle(.teal)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Label("安装点读包", systemImage: "square.and.arrow.down").font(.headline)
                            Spacer()
                            Button("选择 DAB 文件…") { model.choosePackage() }
                        }
                        if let package = model.package {
                            Text(package.title).font(.headline).lineLimit(2).textSelection(.enabled)
                            Text("\(package.url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(package.size), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(package.url.path)
                            if package.isUNB {
                                Text("UNB 独立安装：请沿用商家提供的编号。书内原编码保留，设备绑定自动生成。").font(.subheadline).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(package.isUNB ? "原包文件编号" : "书名贴号")
                                TextField("001–999", text: $model.slot).frame(width: 80)
                                Picker("内容类型", selection: $model.route) {
                                    ForEach(package.isUNB ? [.smart, .ordinary] : Route.allCases) { route in Text(route.title).tag(route) }
                                }.frame(maxWidth: 340)
                            }
                            if model.route == .ordinary {
                                HStack { Text("起始内容码"); TextField("例如 25001", text: $model.content).frame(width: 130) }
                            }
                            if model.route == .direct {
                                HStack { Text("书本封面码"); TextField("1–65535", text: $model.cover).frame(width: 130) }
                            }
                            HStack {
                                Text("书名贴号请按商家说明填写，避免占用已有贴号。").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("安装到点读笔") { model.install() }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.pen == nil)
                            }
                        } else {
                            Text("选择商家提供的 .dab 文件，也支持重新导入备份的 .das / .dar。").foregroundStyle(.secondary).padding(.vertical, 15)
                        }
                    }.padding(12)
                }.disabled(model.busy)
                HStack {
                    Label("已装内容", systemImage: "books.vertical").font(.headline)
                    Spacer()
                    TextField("搜索书名或贴号", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                Table(model.filteredBooks, selection: $model.selection, sortOrder: $model.sortOrder) {
                    TableColumn("贴号", value: \.slot) { book in Text(String(format: "%03d", book.slot)).monospacedDigit() }.width(55)
                    TableColumn("书名", value: \.title)
                    TableColumn("类型", value: \.ext) { book in Text(book.ext.uppercased()).foregroundStyle(.secondary) }.width(48)
                    TableColumn("大小", value: \.size) { book in Text(ByteCountFormatter.string(fromByteCount: Int64(book.size), countStyle: .file)).foregroundStyle(.secondary) }.width(85)
                }.overlay {
                    if model.books.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "books.vertical").font(.largeTitle)
                            Text(model.loadingBooks ? "正在后台读取书目…" : (model.pen == nil ? "连接点读笔后显示已装内容" : "点读笔中还没有可识别的内容"))
                        }.foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                HStack {
                    Text(model.selectedBooks.isEmpty ? "⌘ 点选多个 · ⇧ 连选一段" : "已选择 \(model.selectedBooks.count) 个点读包")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.selectedBooks.count > 1 ? "移除所选（\(model.selectedBooks.count)）…" : "移除所选…", systemImage: "trash", role: .destructive) { model.removeSelected() }
                        .disabled(model.selectedBooks.isEmpty || model.busy)
                }
                if model.busy { ProgressView(value: model.progress).tint(.teal) }
                HStack(spacing: 8) {
                    Image(systemName: model.busy ? "arrow.triangle.2.circlepath" : "info.circle")
                    Text(model.status).lineLimit(2).textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 28, alignment: .leading)
            }.padding(26)
        }
        .frame(minWidth: 1030, minHeight: 720)
        .onChange(of: model.search) { _, _ in model.selection.formIntersection(Set(model.filteredBooks.map(\.id))) }
        .alert("操作提示", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("知道了") { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
    }
}

@main struct TalkingPenApp: App {
    @StateObject private var model = PenModel()
    var body: some Scene {
        WindowGroup("点读伙伴 · 小达人 Mac") {
            PenView(model: model).onOpenURL { model.openPackage($0) }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开点读包…") { model.choosePackage() }.keyboardShortcut("o").disabled(model.busy)
                Divider()
                Button("选择点读笔磁盘…") { model.chooseDevice() }.disabled(model.busy)
                Button("刷新书目") { model.refresh() }.keyboardShortcut("r").disabled(model.busy)
                Divider()
                Toggle("安装后完整回读校验（较慢）", isOn: $model.fullVerification).disabled(model.busy)
            }
        }
    }
}
