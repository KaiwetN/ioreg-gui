// AirPodsHealthViewer.swift — Apple 配件电池健康可视化（v2 · 侧边栏版）
//
// macOS 14+；构建：swiftc -O -parse-as-library -o AirPodsHealthViewer AirPodsHealthViewer.swift
// 运行：./AirPodsHealthViewer
//
// 结构：
//   侧边栏：AirPods（当前页，全功能）+ 其他设备（预留位）
//   AirPods 页：实时状态三环 / 双耳健康（循环·容量趋势·服役）/ 关机事件历史 / 双耳充电分布 / 原始数据
//
// 数据链路（逆向结论）：
//   实时层：system_profiler SPBluetoothDataType（免 root，15s 刷新）
//   健康层：bluetoothd 向耳机 metric Broker 拉取 → TMAP 解码 → CoreAnalytics →
//           /var/db/analyticsd/{config,state}.sqlite（提权拷贝后解析）

import SwiftUI
import Charts
import Combine
import SQLite3
import IOKit
import AppKit
import UniformTypeIdentifiers

// MARK: - 完整只读 IORegistry（不依赖 ioreg XML，不发送控制命令）

indirect enum RegistryValue: Sendable {
    case text(String), number(String, String), flag(Bool), bytes(Data)
    case array([RegistryValue]), dictionary([RegistryProperty]), unknown(String)

    static func decode(_ raw: Any) -> RegistryValue {
        if let v = raw as? Data { return .bytes(v) }
        if let v = raw as? String { return .text(v) }
        if let v = raw as? NSNumber {
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .flag(v.boolValue) }
            let code = String(cString: v.objCType)
            let hex = code == "f" || code == "d" ? "" : String(format: "0x%llX", v.uint64Value)
            return .number(v.stringValue, hex)
        }
        if let v = raw as? [String: Any] {
            return .dictionary(v.keys.sorted().map { RegistryProperty(key: $0, value: decode(v[$0]!)) })
        }
        if let v = raw as? [Any] { return .array(v.map(decode)) }
        return .unknown(String(describing: raw))
    }

    var type: String {
        switch self {
        case .text: return "字符串"
        case .number: return "数值"
        case .flag: return "布尔"
        case .bytes: return "二进制"
        case .array: return "数组"
        case .dictionary: return "字典"
        case .unknown: return "其他"
        }
    }
    var summary: String {
        switch self {
        case .text(let v): return String(v.prefix(240))
        case .number(let v, let hex): return hex.isEmpty ? v : "\(v) · \(hex)"
        case .flag(let v): return v ? "true" : "false"
        case .bytes(let v): return "\(v.count) 字节 · " + v.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        case .array(let v): return "\(v.count) 项"
        case .dictionary(let v): return "\(v.count) 个字段"
        case .unknown(let v): return v
        }
    }
    // 导出保留明确类型；二进制同时保留完整 base64 和 hex，数值保留精确十进制文本。
    var json: Any {
        switch self {
        case .text(let v): return ["type": "string", "value": v]
        case .number(let v, let h): return ["type": "number", "decimal": v, "hex": h]
        case .flag(let v): return ["type": "boolean", "value": v]
        case .bytes(let v): return ["type": "data", "bytes": v.count, "base64": v.base64EncodedString(), "hex": v.map { String(format: "%02X", $0) }.joined()]
        case .array(let v): return ["type": "array", "value": v.map(\.json)]
        case .dictionary(let v): return ["type": "dictionary", "value": Dictionary(uniqueKeysWithValues: v.map { ($0.key, $0.value.json) })]
        case .unknown(let v): return ["type": "unknown", "description": v]
        }
    }
    var fullText: String {
        switch self {
        case .text(let v): return v
        case .bytes(let v):
            var lines = ["二进制 · \(v.count) 字节", ""]
            for start in stride(from: 0, to: v.count, by: 16) {
                let bytes = v[start..<min(start + 16, v.count)]
                lines.append(String(format: "%08X  ", start) + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            if let text = String(data: v, encoding: .utf8) { lines += ["", "UTF-8 解码（仅辅助显示）：", text] }
            return lines.joined(separator: "\n")
        case .array, .dictionary:
            return (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? summary
        default: return summary
        }
    }
}

struct RegistryProperty: Sendable {
    let key: String
    let value: RegistryValue
}

struct RegistryPropertyRow: Identifiable {
    let id: String
    let key: String
    let value: RegistryValue
    var children: [RegistryPropertyRow]? {
        switch value {
        case .dictionary(let fields):
            return fields.isEmpty ? nil : fields.enumerated().map { RegistryPropertyRow(id: "\(id)/\($0.offset)", key: $0.element.key, value: $0.element.value) }
        case .array(let items):
            return items.isEmpty ? nil : items.enumerated().map { RegistryPropertyRow(id: "\(id)/\($0.offset)", key: "[\($0.offset)]", value: $0.element) }
        default: return nil
        }
    }
    func matching(_ term: String) -> RegistryPropertyRow? {
        guard !term.isEmpty else { return self }
        if key.localizedCaseInsensitiveContains(term) || value.summary.localizedCaseInsensitiveContains(term) { return self }
        guard let matched = children?.compactMap({ $0.matching(term) }), !matched.isEmpty else { return nil }
        let fields = matched.map { RegistryProperty(key: $0.key, value: $0.value) }
        return RegistryPropertyRow(id: id, key: key, value: .dictionary(fields))
    }
}

enum RegistryCategory: String, CaseIterable, Identifiable, Sendable {
    case power = "电池 / 电源", usb = "USB", thunderbolt = "雷雳 / PCI", bluetooth = "蓝牙"
    case audio = "音频", graphics = "图形 / 显示", storage = "存储", network = "网络"
    case sensors = "传感器 / 输入", services = "其他硬件 / 系统服务"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .power: return "battery.100percent"
        case .usb: return "cable.connector"
        case .thunderbolt: return "bolt.horizontal"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .audio: return "speaker.wave.2"
        case .graphics: return "display"
        case .storage: return "externaldrive"
        case .network: return "network"
        case .sensors: return "sensor"
        case .services: return "cpu"
        }
    }
    static func classify(name: String, cls: String) -> Self {
        let s = (name + " " + cls).lowercased()
        if s.contains("battery") || s.contains("charger") || s.contains("adapter") || s.contains("power") { return .power }
        if s.contains("bluetooth") { return .bluetooth }
        if s.contains("thunderbolt") || s.contains("pci") { return .thunderbolt }
        if s.contains("audio") || s.contains("speaker") || s.contains("microphone") { return .audio }
        if s.contains("display") || s.contains("framebuffer") || s.contains("gpu") || s.contains("graphics") { return .graphics }
        if s.contains("nvme") || s.contains("storage") || s.contains("media") || s.contains("disk") || s.contains("block") { return .storage }
        if s.contains("network") || s.contains("ethernet") || s.contains("wifi") || s.contains("80211") { return .network }
        if s.contains("usb") { return .usb }
        if s.contains("sensor") || s.contains("hid") || s.contains("keyboard") || s.contains("trackpad") { return .sensors }
        return .services
    }
}

struct RegistryNode: Identifiable, Sendable {
    let id: UInt64
    let parentID: UInt64?
    let name: String
    let displayName: String
    let className: String
    let path: String
    let category: RegistryCategory
    let properties: [RegistryProperty]
    let readError: String?
    let searchIndex: String
    var idText: String { String(format: "0x%llX", id) }
    var json: Any {
        var fields: [String: Any] = ["registryID": idText, "name": name, "displayName": displayName,
            "class": className, "path": path, "categoryHeuristic": category.rawValue,
            "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.key, $0.value.json) })]
        if let parentID { fields["parentRegistryID"] = String(format: "0x%llX", parentID) }
        if let readError { fields["readError"] = readError }
        return fields
    }
}

struct RegistrySnapshot: Sendable {
    let plane: String
    let planes: [String]
    let date: Date
    let nodes: [RegistryNode]
    let warnings: [String]
}

enum RegistryReader {
    static func properties(_ entry: io_registry_entry_t) -> (fields: [String: Any], error: String?) {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let unmanaged else { return ([:], "读取属性失败：\(result)") }
        return (unmanaged.takeRetainedValue() as NSDictionary as? [String: Any] ?? [:], nil)
    }
    static func cString(_ action: (UnsafeMutablePointer<CChar>) -> kern_return_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let result = buf.withUnsafeMutableBufferPointer { action($0.baseAddress!) }
        return result == KERN_SUCCESS ? String(cString: buf) : ""
    }
    static func node(_ entry: io_registry_entry_t, plane: String) -> RegistryNode? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return nil }
        let name = cString { IORegistryEntryGetNameInPlane(entry, plane, $0) }
        let cls = cString { IOObjectGetClass(entry, $0) }
        let path = cString { IORegistryEntryGetPath(entry, plane, $0) }
        var parent: io_registry_entry_t = 0
        var parentID: UInt64?
        if IORegistryEntryGetParentEntry(entry, plane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            var value: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(parent, &value) == KERN_SUCCESS { parentID = value }
        }
        let raw = properties(entry)
        let fields = raw.fields.keys.sorted().map { RegistryProperty(key: $0, value: RegistryValue.decode(raw.fields[$0]!)) }
        let candidates = ["USB Product Name", "Product", "Product Name", "DeviceName", "IOName", "name"]
        let friendly = candidates.compactMap { key -> String? in
            guard let v = raw.fields[key] as? String, !v.isEmpty else { return nil }
            return v
        }.first ?? name
        let category = RegistryCategory.classify(name: name, cls: cls)
        let search = ([friendly, name, cls, path, String(format: "0x%llX", id)] + fields.map { $0.key + " " + $0.value.summary }).joined(separator: " ")
        return RegistryNode(id: id, parentID: parentID, name: name, displayName: friendly,
                            className: cls, path: path, category: category, properties: fields,
                            readError: raw.error, searchIndex: search)
    }
    static func snapshot(plane: String) throws -> RegistrySnapshot {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { throw NSError(domain: "RegistryReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开 IORegistry 根节点"]) }
        defer { IOObjectRelease(root) }
        let rootProperties = properties(root).fields
        let planes = ((rootProperties["IORegistryPlanes"] as? [String: Any])?.keys.map { $0 } ?? ["IOService", "IODeviceTree", "IOUSB", "IOPower"]).sorted()
        guard planes.contains(plane) else { throw NSError(domain: "RegistryReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "注册表平面不可用：\(plane)"]) }
        var iterator: io_iterator_t = 0
        let result = IORegistryEntryCreateIterator(root, plane, UInt32(kIORegistryIterateRecursively), &iterator)
        guard result == KERN_SUCCESS else { throw NSError(domain: "RegistryReader", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "无法枚举 \(plane)：\(result)"]) }
        defer { IOObjectRelease(iterator) }
        var nodes: [RegistryNode] = []
        var seen = Set<UInt64>()
        if let n = node(root, plane: plane) { nodes.append(n); seen.insert(n.id) }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            if let n = node(entry, plane: plane), seen.insert(n.id).inserted { nodes.append(n) }
            IOObjectRelease(entry)
        }
        var warnings: [String] = []
        if IOIteratorIsValid(iterator) == 0 { warnings.append("枚举期间注册树发生变化；请刷新获取新的快照。") }
        let failures = nodes.filter { $0.readError != nil }.count
        if failures > 0 { warnings.append("\(failures) 个节点属性不可读；仍保留节点并显示错误。") }
        return RegistrySnapshot(plane: plane, planes: planes, date: Date(), nodes: nodes.sorted { $0.path < $1.path }, warnings: warnings)
    }
    static func export(_ snapshot: RegistrySnapshot, nodes: [RegistryNode]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": "IORegistry typed snapshot v1", "plane": snapshot.plane,
            "capturedAt": ISO8601DateFormatter().string(from: snapshot.date), "nodeCount": nodes.count,
            "notice": "包含硬件、驱动与虚拟服务；分类为启发式，不代表物理设备数量。可能含序列号和设备标识。",
            "warnings": snapshot.warnings, "nodes": nodes.map(\.json)], options: [.prettyPrinted, .sortedKeys])
    }
    static func selfTest() -> Bool {
        do {
            guard case .flag(true) = RegistryValue.decode(NSNumber(value: true)),
                  case .number(let decimal, _) = RegistryValue.decode(NSNumber(value: UInt64.max)), decimal == String(UInt64.max),
                  case .bytes(let bytes) = RegistryValue.decode(Data([0, 255, 128])), bytes == Data([0, 255, 128]) else { throw NSError(domain: "RegistryTest", code: 1) }
            let start = Date()
            let snapshot = try snapshot(plane: "IOService")
            guard snapshot.nodes.count > 1, Set(snapshot.nodes.map(\.id)).count == snapshot.nodes.count,
                  snapshot.nodes.contains(where: { $0.className.contains("Battery") }) else { throw NSError(domain: "RegistryTest", code: 2) }
            let data = try export(snapshot, nodes: snapshot.nodes)
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (parsed?["nodes"] as? [Any])?.count == snapshot.nodes.count else { throw NSError(domain: "RegistryTest", code: 3) }
            print("PASS 类型转换：布尔、UInt64、二进制；全量 JSON 导出回读")
            print("IOService 节点：\(snapshot.nodes.count)，耗时：\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            print("公开平面：\(snapshot.planes.joined(separator: ", "))")
            for category in RegistryCategory.allCases { print("\(category.rawValue)：\(snapshot.nodes.filter { $0.category == category }.count)") }
            for plane in snapshot.planes where plane != "IOService" {
                let value = try self.snapshot(plane: plane)
                print("PASS 平面 \(plane)：\(value.nodes.count) 个节点")
            }
            print("读取警告：\(snapshot.warnings.joined(separator: "; "))")
            return true
        } catch { print("FAIL：\(error.localizedDescription)"); return false }
    }
}

@MainActor
final class RegistryStore: ObservableObject {
    @Published var snapshot: RegistrySnapshot?
    @Published var isLoading = false
    @Published var error = ""
    @Published var plane = "IOService"
    func refresh() {
        guard !isLoading else { return }
        isLoading = true; error = ""
        let requestedPlane = plane
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RegistryReader.snapshot(plane: requestedPlane) }
            DispatchQueue.main.async {
                switch result {
                case .success(let value): self.snapshot = value
                case .failure(let error): self.error = error.localizedDescription
                }
                self.isLoading = false
            }
        }
    }
}

struct RegistryPage: View {
    @StateObject private var store = RegistryStore()
    @State private var search = ""
    @State private var category = "全部"
    @State private var selection: UInt64?
    @State private var propertySearch = ""
    @State private var inspected: RegistryPropertyRow?
    @State private var operationError = ""
    @State private var autoRefresh = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var visible: [RegistryNode] {
        (store.snapshot?.nodes ?? []).filter {
            (category == "全部" || $0.category.rawValue == category) &&
            (search.isEmpty || $0.searchIndex.localizedCaseInsensitiveContains(search))
        }
    }
    var selected: RegistryNode? { store.snapshot?.nodes.first { $0.id == selection } }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if !store.error.isEmpty { Text(store.error).foregroundColor(.red).padding(8) }
            if let snapshot = store.snapshot {
                ForEach(snapshot.warnings, id: \.self) { Text($0).font(.caption).foregroundColor(.orange).padding(6) }
            }
            HSplitView {
                nodeList.frame(minWidth: 270, idealWidth: 340, maxWidth: 460)
                if let selected {
                    nodeDetail(selected).frame(minWidth: 440, maxWidth: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "cpu").font(.system(size: 40)).foregroundColor(.secondary)
                        Text(store.isLoading ? "正在读取注册表…" : "选择一个设备或服务节点").font(.title3)
                        Text("只读浏览当前系统公开的信息；不会访问驱动控制接口。")
                            .font(.caption).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("\(visible.count) / \(store.snapshot?.nodes.count ?? 0) 个节点 · 分类为启发式，含驱动和虚拟服务")
                Spacer()
                if let date = store.snapshot?.date { Text(date, format: .dateTime.hour().minute().second()) }
            }.font(.caption).foregroundColor(.secondary).padding(10)
        }
        .onAppear { if store.snapshot == nil { store.refresh() } }
        .onReceive(timer) { _ in if autoRefresh { store.refresh() } }
        .onChange(of: store.plane) { _, _ in selection = nil; store.refresh() }
        .onChange(of: selection) { _, _ in propertySearch = "" }
        .sheet(item: $inspected) { property in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(property.key).font(.headline).textSelection(.enabled)
                    Spacer()
                    Text(property.value.type).foregroundColor(.secondary)
                    Button("关闭") { inspected = nil }
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(property.value.fullText).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.background(Color(nsColor: .textBackgroundColor))
                Button("复制完整值") { copy(property.value.fullText) }
            }.padding(20).frame(minWidth: 700, minHeight: 460)
        }
        .alert("操作失败", isPresented: Binding(get: { !operationError.isEmpty }, set: { if !$0 { operationError = "" } })) {
            Button("确定") { operationError = "" }
        } message: { Text(operationError) }
    }
    var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("全部设备与 IORegistry", systemImage: "cpu").font(.title2).bold()
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(store.isLoading)
                Button("导出当前筛选…") { export(visible) }.disabled(store.snapshot == nil || store.isLoading)
            }
            HStack {
                TextField("搜索名称、类、路径、ID 或顶层属性", text: $search).textFieldStyle(.roundedBorder)
                Picker("平面", selection: $store.plane) {
                    ForEach(store.snapshot?.planes ?? ["IOService"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 220).disabled(store.isLoading)
                Picker("类别", selection: $category) {
                    Text("全部").tag("全部")
                    ForEach(RegistryCategory.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }.frame(width: 240)
            }
            HStack {
                Text("IOService 为默认设备/服务视图；其他平面补充端口、供电和设备树。导出可能包含序列号，请谨慎分享。")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle("30 秒自动刷新", isOn: $autoRefresh).toggleStyle(.checkbox).font(.caption)
            }
        }.padding(14)
    }
    var nodeList: some View {
        List(selection: $selection) {
            ForEach(visible) { node in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: node.category.icon).foregroundColor(.accentColor).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.displayName.isEmpty ? node.name : node.displayName).lineLimit(1)
                        Text(node.className).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        Text(node.idText).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    }
                }.padding(.vertical, 3).tag(node.id)
            }
        }.overlay {
            if visible.isEmpty && !store.isLoading { Text("当前条件没有匹配节点").foregroundColor(.secondary) }
        }
    }
    func nodeDetail(_ node: RegistryNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(node.displayName).font(.title3).bold().textSelection(.enabled)
                    Spacer()
                    Button("复制路径") { copy(node.path) }
                    Button("导出节点…") { export([node]) }.disabled(store.isLoading)
                }
                Text("\(node.className) · \(node.idText) · \(node.category.rawValue)").font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Text(node.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                if let parentID = node.parentID, let parent = store.snapshot?.nodes.first(where: { $0.id == parentID }) {
                    Button("上级节点：\(parent.name)") { category = "全部"; search = ""; selection = parentID }.buttonStyle(.link)
                }
                let children = store.snapshot?.nodes.filter { $0.parentID == node.id } ?? []
                if !children.isEmpty {
                    DisclosureGroup("直接子节点（\(children.count)）") {
                        ScrollView {
                            LazyVStack(alignment: .leading) {
                                ForEach(children) { child in
                                    Button("\(child.displayName) · \(child.className)") { category = "全部"; search = ""; selection = child.id }.buttonStyle(.link)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 140)
                    }
                }
                if let error = node.readError { Text(error).foregroundColor(.orange) }
            }
            TextField("筛选属性名或预览值（含嵌套字段）", text: $propertySearch).textFieldStyle(.roundedBorder)
            Text("\(node.properties.count) 个顶层属性 · 展开字典/数组；点击字段查看完整值。未公開字段不会补猜。")
                .font(.caption).foregroundColor(.secondary)
            List {
                OutlineGroup(node.properties.enumerated().map {
                    RegistryPropertyRow(id: "\($0.offset)", key: $0.element.key, value: $0.element.value)
                }.compactMap { $0.matching(propertySearch) }, children: \.children) { row in
                    Button { inspected = row } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.key).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(2)
                                Spacer()
                                Text(row.value.type).font(.caption2).foregroundColor(.secondary)
                            }
                            Text(row.value.summary).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain).contextMenu {
                        Button("复制字段名") { copy(row.key) }
                        Button("复制完整值") { copy(row.value.fullText) }
                    }
                }
            }
        }.padding(14)
    }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    func export(_ nodes: [RegistryNode]) {
        guard let snapshot = store.snapshot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "IORegistry-\(snapshot.plane).json"
        panel.message = "导出含设备标识和可能的序列号，仅在确认后保存；不会上传。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try RegistryReader.export(snapshot, nodes: nodes).write(to: url, options: .atomic) }
        catch { operationError = error.localizedDescription }
    }
}

// MARK: - 字段名中文解释

let dimCN: [String: String] = [
    "cycle_count": "循环计数",
    "chg_cycle_cnt": "充电循环计数",
    "cycle_at_capacity": "当前容量对应循环数",
    "capacity_mAh": "电池容量 (mAh)",
    "bud_side": "左右耳 (1=左 2=右)",
    "bud_role": "耳机角色编码",
    "bud_mileage": "累计放电量 (0.1mAh)",
    "brownout_count": "欠压(掉电)事件数",
    "shutdown_GGSOC": "关机时电量计SOC (%)",
    "shutdown_reason": "关机原因",
    "time_in_field_days": "服役天数",
    "time_in_field_at_capacity_days": "当前容量下服役天数",
    "total_time_s": "累计使用时长 (秒)",
    "serial_number_left": "左耳序列号",
    "serial_number_right": "右耳序列号",
    "serial_number_system": "整机序列号",
    "case_product_id": "充电盒产品ID",
    "case_sw_version": "充电盒固件版本号",
    "sw_version": "固件版本号",
    "hw_config": "硬件配置",
    "product_id": "产品ID (0x2024=Pro2)",
    "vendorID": "厂商ID",
    "voltage_max_mV": "电池最高电压 (mV)",
    "voltage_min_mV": "电池最低电压 (mV)",
    "max_chg_voltage_mV": "最大充电电压 (mV)",
    "timeAbove95_h": "高电量驻留 (>95%SOC 小时, 越久老化越快)",
    "time_charging_total_s": "累计充电时长 (秒)",
    "time_charging_wired_total_s": "有线充电时长 (秒)",
    "time_charging_wireless_total_s": "无线充电时长 (秒)",
    "time_charging_topOff_s": "补电时长 (秒)",
    "time_charging_topOff_wired_s": "有线补电时长 (秒)",
    "time_charging_topOff_wireless_s": "无线补电时长 (秒)",
    "vac_teq_h": "盒电池电压等效累计时间 (h)",
    "health_source": "健康数据来源",
    "timestamp": "上报时间戳",
    "idProduct": "产品 ID",
    "idVendor": "厂商 ID",
    "kUSBSerialNumberString": "序列号",
    "kUSBVendorString": "厂商名",
    "kUSBProductString": "产品名",
    "bcdDevice": "设备版本",
    "kUSBCurrentAvailable": "可用电流 (mA)",
    "RequestedPower": "请求功率 (mA)",
    "Model Number": "型号",
    "Serial Number": "序列号",
    "Firmware Revision": "固件版本",
    "Vendor Name": "厂商",
    "Physical Interconnect": "物理互连",
    "Physical Interconnect Location": "互连位置",
    "NVMe Revision Supported": "NVMe 协议版本",
    "FW Version": "固件版本",
    "ConnectionCount": "连接计数",
    "Plug Event Count": "插拔事件数",
    "ConnectionActive": "当前连接活跃",
    "ActiveCable": "活动线缆",
    "AccessoryMode": "配件模式",
    "Boot Flags": "启动标志",
    "FeaturesEnabled": "已启用特性",
    "FeaturesSupported": "支持的特性",
    "HPDAsserted": "HPD 已声明",
    "_name": "名称",
    "IORegistryEntryName": "注册表名称",
    "IOObjectClass": "对象类",
    "IOServiceState": "服务状态",
    "Chipset Name": "芯片组名称",
    "AdapterVoltage": "适配器电压 (mV)",
    "UsbHvcHvcIndex": "当前 PDO 档位",
    "SystemVoltageIn": "输入电压 (mV)",
    "SystemCurrentIn": "输入电流 (mA)",
    "SystemPowerIn": "输入功率 (mW)",
    "AdapterEfficiencyLoss": "适配器效率损耗 (mW)",
    "AdapterEfficiencyLossAccumulatorCount": "效率采样计数",
    "BatteryPower": "电池功率 (mW)",
    "BatteryPowerAccumulatorCount": "电池功率采样数",
    "BatteryDischarge": "电池放电量",
    "SystemLoad": "系统负载 (mW)",
    "SystemLoadAccumulatorCount": "系统负载采样数",
    "SystemEnergyConsumed": "系统消耗能量",
    "SystemEffectiveTotalLoad": "当前有效负载 (mW)",
    "SystemPowerInAccumulatorCount": "输入功率采样数",
    "PowerTelemetryErrorCount": "遥测错误数",
    "WallEnergyEstimate": "市电能量估算",
    "AccumulatedSystemPowerIn": "累计输入功率 (mW·min)",
    "AccumulatedSystemLoad": "累计系统负载",
    "AccumulatedSystemEnergyConsumed": "累计系统消耗能量",
    "AccumulatedWallEnergyEstimate": "累计市电能量估算",
    "AccumulatedBatteryPower": "累计电池功率",
    "AccumulatedBatteryDischarge": "累计电池放电",
    "AccumulatedAdapterEfficiencyLoss": "累计适配器损耗",
    "AccumSystemEffectiveTotalLoad": "累计有效负载",
    "AccumSystemEffectiveTotalLoadCount": "累计有效负载计数",
]

func cn(_ dim: String) -> String {
    if let m = dimCN[dim] { return m }
    if dim.hasPrefix("shutdown_voltage_") {
        return "最近第 \((Int(dim.dropFirst("shutdown_voltage_".count)) ?? 0) + 1)/10 次关机电压 (mV)"
    }
    if dim.hasPrefix("shutdown_temperature_") {
        return "最近第 \((Int(dim.dropFirst("shutdown_temperature_".count)) ?? 0) + 1)/10 次关机温度 (°C)"
    }
    if dim.hasPrefix("shutdown_current_") {
        return "第 \((Int(dim.dropFirst("shutdown_current_".count)) ?? 0) + 1)/3 次关机电流 (mA)"
    }
    if dim.hasPrefix("milestone_capacity_mAh_") {
        return "容量里程碑\(dim.suffix(1)) (mAh)"
    }
    if dim.hasPrefix("milestone_cycle_count_at_capacity_") {
        return "达到该容量时的循环数 \(dim.suffix(1))"
    }
    if dim.hasPrefix("acc_charge_throughput_soc_temp_matrix_ma_per_min_") {
        let idx = dim.dropFirst("acc_charge_throughput_soc_temp_matrix_ma_per_min_".count).split(separator: "_")
        if idx.count == 2, let s = Int(idx[0]), let t = Int(idx[1]) {
            return "累计充入电荷 (mA·min)：电量档\(s+1) × 温度档\(t+1)"
        }
    }
    if dim.hasPrefix("time_at_idle_soc_temp_matrix_min_") {
        let idx = dim.dropFirst("time_at_idle_soc_temp_matrix_min_".count).split(separator: "_")
        if idx.count == 2, let s = Int(idx[0]), let t = Int(idx[1]) {
            return "闲置时长：电量档\(s+1) × 温度档\(t+1) (分钟)"
        }
    }
    if dim.hasPrefix("vac_milestone_teq_h_") {
        return "盒电压等效里程碑 \(dim.suffix(1)) (h)"
    }
    return dim
}

func serviceText(_ days: Int) -> (text: String, firstUse: String) {
    let cal = Calendar.current
    let now = Date()
    guard let first = cal.date(byAdding: .day, value: -days, to: now) else { return ("\(days) 天", "-") }
    let comp = cal.dateComponents([.year, .day], from: first, to: now)
    let y = comp.year ?? 0, d = comp.day ?? 0
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy年M月d日"
    return (y > 0 ? "\(y) 年 \(d) 天" : "\(d) 天", "首次使用约 " + fmt.string(from: first))
}

func ggsocColor(_ v: Int) -> Color { v >= 80 ? .green : v >= 30 ? .orange : .red }

// MARK: - 数据模型

struct LiveInfo {
    var name = ""
    var address = ""
    var caseLevel = 0
    var leftLevel = 0
    var rightLevel = 0
    var caseVersion = ""
    var firmwareVersion = ""
    var serial = ""
    var serialLeft = ""
    var serialRight = ""
}

struct DimValue: Identifiable {
    let id = UUID()
    let dim: String
    let value: String
    var fromCache = false
}

struct HealthRecord: Identifiable {
    var uuid: String
    var message: String
    var sink: String
    var eventCount: Int
    var rows: [[DimValue]]
    var id: String { uuid }
}

// MARK: - 数据层

enum DataSource {

    static func run(_ path: String, _ args: [String]) -> (data: Data, status: Int32)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        // 先持续排空 stdout，避免 system_profiler / ioreg 超出管道缓冲后双方互相等待。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (data, proc.terminationStatus)
    }

    static func readLive() -> [LiveInfo] {
        guard let res = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              res.status == 0,
              let root = try? JSONSerialization.jsonObject(with: res.data) as? [String: Any],
              let list = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var out: [LiveInfo] = []
        for bt in list {
            guard let connected = bt["device_connected"] as? [[String: Any]] else { continue }
            for dev in connected {
                for (name, raw) in dev {
                    guard let p = raw as? [String: Any] else { continue }
                    let minor = p["device_minorType"] as? String ?? ""
                    let isAP = (p["device_vendorID"] as? String) == "0x004C"
                        && (minor == "Headphones" || name.lowercased().contains("airpods"))
                    guard isAP else { continue }
                    var i = LiveInfo()
                    i.name = name
                    i.address = p["device_address"] as? String ?? ""
                    i.caseLevel = pct(p["device_batteryLevelCase"])
                    i.leftLevel = pct(p["device_batteryLevelLeft"])
                    i.rightLevel = pct(p["device_batteryLevelRight"])
                    i.caseVersion = p["device_caseVersion"] as? String ?? ""
                    i.firmwareVersion = p["device_firmwareVersion"] as? String ?? ""
                    i.serial = p["device_serialNumber"] as? String ?? ""
                    i.serialLeft = p["device_serialNumberLeft"] as? String ?? ""
                    i.serialRight = p["device_serialNumberRight"] as? String ?? ""
                    out.append(i)
                }
            }
        }
        return out
    }

    private static func pct(_ v: Any?) -> Int {
        guard let s = v as? String else { return 0 }
        return Int(s.replacingOccurrences(of: "%", with: "")) ?? 0
    }

    static func elevateAndCopy() -> (ok: Bool, message: String) {
        let dst = "/tmp/analyticsd_gui"
        let user = NSUserName()
        let shell = "mkdir -p \(dst) && rm -rf \(dst)/* && cp -R /var/db/analyticsd/ \(dst)/ && chown -R \(user) \(dst)"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        let res = run("/usr/bin/osascript", ["-e", script])
        if res?.status == 0 { return (true, "已提权拷贝到 \(dst)") }
        let err = String(decoding: res?.data ?? Data(), as: UTF8.self)
        if err.contains("User canceled") || err.contains("用户已取消") { return (false, "已取消") }
        return (false, "提权失败：\(err.prefix(200))")
    }

    static func parseAnalytics(dir: String) -> (records: [HealthRecord], error: String?) {
        let statePath = dir + "/state.sqlite"
        let configPath = dir + "/config.sqlite"
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: statePath), fm.isReadableFile(atPath: configPath) else {
            return ([], "找不到 \(statePath) — 请先点击「提权读取」")
        }
        var dbState: OpaquePointer?, dbConfig: OpaquePointer?
        guard sqlite3_open_v2(statePath, &dbState, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_open_v2(configPath, &dbConfig, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return ([], "sqlite 打开失败")
        }
        defer { sqlite3_close(dbState); sqlite3_close(dbConfig) }

        var defs: [(uuid: String, dims: [String], message: String, sink: String)] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(dbConfig, "SELECT transform_uuid, transform_def FROM composed_transforms_view", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = String(cString: sqlite3_column_text(stmt, 0))
            let defStr = String(cString: sqlite3_column_text(stmt, 1))
            guard defStr.contains("BatteryHealth"),
                  let d = try? JSONSerialization.jsonObject(with: Data(defStr.utf8)) as? [String: Any],
                  let dimsRaw = d["dimensions"] as? [[String: Any]] else { continue }
            let dims = dimsRaw.compactMap { $0["name"] as? String }
            let out = (d["outputs"] as? [[String: Any]])?.first
            defs.append((uuid, dims, out?["message"] as? String ?? "?", out?["sink"] as? String ?? "?"))
        }
        sqlite3_finalize(stmt)

        var records: [HealthRecord] = []
        sqlite3_prepare_v2(dbState, """
            SELECT tm.transform_uuid, ts.transform_key, ts.transform_value
            FROM transform_states ts JOIN transform_metadata tm
              ON ts.transform_metadata_id = tm.transform_metadata_id
            """, -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = String(cString: sqlite3_column_text(stmt, 0))
            let keyStr = String(cString: sqlite3_column_text(stmt, 1))
            let cnt = sqlite3_column_int(stmt, 2)
            guard let def = defs.first(where: { uuid.hasPrefix($0.uuid) }),
                  let vals = try? JSONSerialization.jsonObject(with: Data(keyStr.utf8)) as? [Any?]
            else { continue }
            var row: [DimValue] = []
            for (i, dim) in def.dims.enumerated() {
                guard i < vals.count, let v = vals[i], !(v is NSNull) else { continue }
                // 矩阵的明确零值和缺失值必须分开；第零次循环也是有效坐标。
                let keepZero = dim.contains("soc_temp_matrix_") || dim.hasPrefix("milestone_cycle_count_")
                    || dim == "cycle_at_capacity"
                if !keepZero, let n = v as? Int, n == 0 { continue }
                if !keepZero, let n = v as? Double, n == 0 { continue }
                row.append(DimValue(dim: dim, value: "\(v)"))
            }
            if let idx = records.firstIndex(where: { $0.uuid == def.uuid }) {
                records[idx].rows.append(row)
            } else {
                records.append(HealthRecord(uuid: def.uuid, message: def.message,
                                            sink: def.sink, eventCount: Int(cnt), rows: [row]))
            }
        }
        sqlite3_finalize(stmt)
        return (mergeCachedMilestones(into: records), nil)
    }

    // 聚合窗口可能被 analyticsd 重置（里程碑字段回到 null）——
    // 用本地缓存补齐历史里程碑，保证退化曲线跨窗口稳定
    static func mergeCachedMilestones(into records: [HealthRecord]) -> [HealthRecord] {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirPodsHealthViewer", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("health_cache.json")
        var cache = [String: [String: String]]()
        if let data = try? Data(contentsOf: cacheURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            cache = obj
        }
        var out: [HealthRecord] = []
        for var rec in records {
            guard rec.message.contains("AudioBatteryHealthShutdown") else { out.append(rec); continue }
            for r in rec.rows.indices {
                let side = DataSource.strValue(rec.rows[r], "bud_side")
                var cached = cache[side] ?? [:]
                var merged = rec.rows[r]
                for (k, v) in cached where k.hasPrefix("milestone_") {
                    if !merged.contains(where: { $0.dim == k }) {
                        merged.append(DimValue(dim: k, value: v, fromCache: true))
                    }
                }
                for dv in merged {
                    if dv.dim.hasPrefix("milestone_") {
                        if let n = Int(dv.value), n > 0 { cached[dv.dim] = dv.value }
                    } else if dv.dim != "timestamp", Int(dv.value) != nil {
                        cached[dv.dim] = dv.value
                    }
                }
                cache[side] = cached
                rec.rows[r] = merged
            }
            out.append(rec)
        }
        if let data = try? JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys]) {
            try? data.write(to: cacheURL)
        }
        return out
    }

   // MARK: 充电 / 电源数据（PowerLog + ioreg，均免 root）

    struct AdapterLive {
        var desc = ""
        var name = ""
        var manufacturer = ""
        var model = ""
        var serial = ""
        var fwVersion = ""
        var hwVersion = ""
        var isWireless = false
        var voltageMV = 0
        var currentMA = 0
        var watts = 0
        var tier = 0
        var hvcIndex = 0
        var menu: [(idx: Int, mv: Int, ma: Int)] = []
        var connected = false
    }

    struct PortRow {
        var port: Int
        var attach = 0
        var detach = 0
        var uvdmEnum = 0
        var uvdmSts = 0
        var maxPower = 0
        var npdos = 0
        var pdos: [(text: String, kind: Int)] = []
    }

    /// 解码一个 PDO 原始值（含 SPR PPS / SPR AVS / EPR AVS APDO）
    static func decodePDO(_ v: Int) -> String? {
        guard v != 0 else { return nil }
        let w = v & 0xFFFF_FFFF                       // 确保只看低 32 位（ioreg 可能 sign-extend 到 64 位）
        let kind = (w >> 30) & 0x3
        if kind == 0 {
            let mv = ((w >> 10) & 0x3FF) * 50
            let ma = (w & 0x3FF) * 10
            return "固定 \(mv)mV / \(ma)mA"
        }
        if kind == 3 {
            let apdoSub = (w >> 28) & 0x3              // B29:28 = APDO 子类型
            if apdoSub == 0 {
                // SPR PPS (PD3.0+)：B27=PwrLtd, B24:17=MaxV(100mV), B15:8=MinV(100mV), B6:0=MaxI(50mA)
                let pwrLtd = (w >> 27) & 1
                let maxV = Double((w >> 17) & 0xFF) * 0.1
                let minV = Double((w >> 8) & 0xFF) * 0.1
                let ma = (w & 0x7F) * 50
                let ltd = pwrLtd == 1 ? "⚡️限功率" : ""
                return "PPS \(String(format: "%.1f", minV))V – \(String(format: "%.1f", maxV))V / \(ma)mA \(ltd)"
            }
            if apdoSub == 1 {
                // EPR AVS (PD3.1+)：B27:26=Peak, B25:17=MaxV(100mV), B15:8=MinV(100mV), B7:0=PDP(1W)
                let maxV = Double((w >> 17) & 0x1FF) * 0.1
                let minV = Double((w >> 8) & 0xFF) * 0.1
                let pdp = w & 0xFF
                return "EPR-AVS \(String(format: "%.1f", minV))V – \(String(format: "%.1f", maxV))V / \(pdp)W"
            }
            if apdoSub == 2 {
                // SPR AVS (PD3.2+)：B27=PwrLtd, B24:17=MaxV(100mV), B15:8=MinV(100mV), B6:0=MaxI(50mA)
                let pwrLtd = (w >> 27) & 1
                let maxV = Double((w >> 17) & 0xFF) * 0.1
                let minV = Double((w >> 8) & 0xFF) * 0.1
                let ma = (w & 0x7F) * 50
                let ltd = pwrLtd == 1 ? "⚡️限功率" : ""
                return "AVS 连续可调 \(String(format: "%.1f", minV))V – \(String(format: "%.1f", maxV))V / \(ma)mA \(ltd)"
            }
            return "APDO 子类型\(apdoSub)（raw 0x\(String(w, radix: 16))）"
        }
        return "PDO 类型\(kind)（raw 0x\(String(w, radix: 16))）"
    }

    struct ChargeSample: Identifiable { let id = UUID(); let date: Date; let mv: Int; let ma: Int }
    struct AdapterEvent { let date: Date; let model: String; let watts: Int; let tier: Int }

    static func readAdapterLive() -> AdapterLive? {
        guard let res = run("/usr/sbin/ioreg", ["-r", "-n", "AppleSmartBattery", "-a"]),
              res.status == 0,
              let pl = try? PropertyListSerialization.propertyList(from: res.data, options: [], format: nil)
        else { return nil }
        let entry = (pl as? [[String: Any]])?.first ?? pl as? [String: Any]
        guard let e = entry as? [String: Any] else { return nil }
        var a = AdapterLive()
        a.connected = (e["ExternalConnected"] as? Bool) ?? false
        guard let ads = e["AppleRawAdapterDetails"] as? [[String: Any]], let ad = ads.first else { return a }
        a.desc = ad["Description"] as? String ?? ""
        a.name = ad["Name"] as? String ?? ""
        a.manufacturer = ad["Manufacturer"] as? String ?? ""
        a.model = ad["Model"] as? String ?? ""
        a.serial = ad["SerialString"] as? String ?? ""
        a.fwVersion = ad["FwVersion"] as? String ?? ""
        a.hwVersion = ad["HwVersion"] as? String ?? ""
        a.isWireless = (ad["IsWireless"] as? Bool) ?? false
        a.voltageMV = ad["AdapterVoltage"] as? Int ?? 0
        a.currentMA = ad["Current"] as? Int ?? 0
        a.watts = ad["Watts"] as? Int ?? 0
        a.tier = ad["AdapterPowerTier"] as? Int ?? 0
        a.hvcIndex = ad["UsbHvcHvcIndex"] as? Int ?? 0
        if let menu = ad["UsbHvcMenu"] as? [[String: Any]] {
            for m in menu {
                if let i = m["Index"] as? Int, let mv = m["MaxVoltage"] as? Int, let ma = m["MaxCurrent"] as? Int {
                    a.menu.append((idx: i, mv: mv, ma: ma))
                }
            }
        }
        return a
    }

    static func copyPowerLog() -> String? {
        let fm = FileManager.default
        let base = "/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"
        guard fm.isReadableFile(atPath: base) else { return nil }
        let dst = "/tmp/powerlog_viewer/CurrentPowerlog.PLSQL"
        try? fm.createDirectory(atPath: "/tmp/powerlog_viewer", withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let s = base + suffix, d = dst + suffix
            if fm.fileExists(atPath: s) { try? fm.removeItem(atPath: d); try? fm.copyItem(atPath: s, toPath: d) }
        }
        return dst
    }

    static func readCharging() -> (events: [AdapterEvent], ports: [PortRow], samples: [ChargeSample])? {
        guard let dbPath = copyPowerLog() else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var events: [AdapterEvent] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT timestamp, Model, Watts, AdapterPowerTier, Manufacturer FROM PLBatteryAgent_EventForward_AdapterDetails ORDER BY timestamp DESC LIMIT 15", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt, 0)
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let watts = Int(sqlite3_column_int(stmt, 2))
            let tier = Int(sqlite3_column_int(stmt, 3))
            let man = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            events.append(AdapterEvent(date: Date(timeIntervalSince1970: ts), model: model, watts: watts, tier: tier))
        }
        sqlite3_finalize(stmt)
        var ports: [PortRow] = []
        for pi in 0...3 {
            sqlite3_prepare_v2(db, "SELECT PortControllerAttachCount, PortControllerDetachCount, PortControllerIrqCntUvdmEnum, PortControllerIrqCntUvdmStsUpd, PortControllerMaxPower, PortControllerPortPDO0, PortControllerPortPDO1, PortControllerPortPDO2, PortControllerPortPDO3, PortControllerPortPDO4, PortControllerPortPDO5, PortControllerPortPDO6, PortControllerPortPDO7, PortControllerPortPDO8, PortControllerPortPDO9, PortControllerPortPDO10, PortControllerPortPDO11, PortControllerPortPDO12 FROM PLBatteryAgent_EventForward_PortControllerInfo\(pi) ORDER BY timestamp DESC LIMIT 1", -1, &stmt, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                var pr = PortRow(port: pi)
                pr.attach = Int(sqlite3_column_int(stmt, 0))
                pr.detach = Int(sqlite3_column_int(stmt, 1))
                pr.uvdmEnum = Int(sqlite3_column_int(stmt, 2))
                pr.uvdmSts = Int(sqlite3_column_int(stmt, 3))
                pr.maxPower = Int(sqlite3_column_int(stmt, 4))
                for c in 5...17 {
                    let v = Int(sqlite3_column_int64(stmt, Int32(c)))
                    if let text = decodePDO(v) {
                        let kind = (v & 0xFFFF_FFFF) >> 30 & 0x3
                        pr.pdos.append((text: text, kind: Int(kind)))
                    }
                }
                ports.append(pr)
            }
            sqlite3_finalize(stmt)
        }
        var samples: [ChargeSample] = []
        sqlite3_prepare_v2(db, "SELECT timestamp, SystemInputVoltage, SystemInputCurrent FROM PLBatteryAgent_EventBackward_Adapter WHERE SystemPowerIn > 0 ORDER BY timestamp DESC LIMIT 240", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt, 0)
            samples.append(ChargeSample(date: Date(timeIntervalSince1970: ts),
                                        mv: Int(sqlite3_column_int(stmt, 1)),
                                        ma: Int(sqlite3_column_int(stmt, 2))))
        }
        sqlite3_finalize(stmt)
        samples.reverse()
        return (events, ports, samples)
    }

    static func fmtAny(_ v: Any) -> String {
        if let s = v as? String { return s.isEmpty ? "-" : s }
        if let n = v as? NSNumber { return n.stringValue }
        if let b = v as? Bool { return b ? "是" : "否" }
        if let d = v as? Data {
            let hex = d.prefix(12).map { String(format: "%02x", $0) }.joined()
            return "0x" + hex + (d.count > 12 ? "…(\(d.count)B)" : "")
        }
        if let a = v as? [Any] { return "[\(a.count) 项]" }
        if let d = v as? [String: Any] { return "{\(d.count) 键}" }
        let s = String(describing: v)
        return String(s.prefix(80))
    }

    struct SmartBatteryData {
        var adapter: AdapterLive?
        var telemetry: [(String, String)]
        var efficiencyPct: Int?
        var mac: (cycle: Int, nominal: Int?, design: Int?, healthPct: Int?, external: Bool, watts: Int)?
    }

    /// 一次 ioreg 调用：充电器身份/PDO 菜单 + 电力遥测 + Mac 电池健康
    static func readSmartBattery() -> SmartBatteryData? {
        guard let res = run("/usr/sbin/ioreg", ["-r", "-n", "AppleSmartBattery", "-a"]),
              res.status == 0,
              let pl = try? PropertyListSerialization.propertyList(from: res.data, options: [], format: nil)
        else { return nil }
        let entry = (pl as? [[String: Any]])?.first ?? pl as? [String: Any]
        guard let e = entry as? [String: Any] else { return nil }

        // 充电器
        var a = AdapterLive()
        a.connected = (e["ExternalConnected"] as? Bool) ?? false
        if let ads = e["AppleRawAdapterDetails"] as? [[String: Any]], let ad = ads.first {
            a.desc = ad["Description"] as? String ?? ""
            a.name = ad["Name"] as? String ?? ""
            a.manufacturer = ad["Manufacturer"] as? String ?? ""
            a.model = ad["Model"] as? String ?? ""
            a.serial = ad["SerialString"] as? String ?? ""
            a.fwVersion = ad["FwVersion"] as? String ?? ""
            a.hwVersion = ad["HwVersion"] as? String ?? ""
            a.isWireless = (ad["IsWireless"] as? Bool) ?? false
            a.voltageMV = ad["AdapterVoltage"] as? Int ?? 0
            a.currentMA = ad["Current"] as? Int ?? 0
            a.watts = ad["Watts"] as? Int ?? 0
            a.tier = ad["AdapterPowerTier"] as? Int ?? 0
            a.hvcIndex = ad["UsbHvcHvcIndex"] as? Int ?? 0
            if let menu = ad["UsbHvcMenu"] as? [[String: Any]] {
                for m in menu {
                    if let i = m["Index"] as? Int, let mv = m["MaxVoltage"] as? Int, let ma = m["MaxCurrent"] as? Int {
                        a.menu.append((idx: i, mv: mv, ma: ma))
                    }
                }
            }
        }

        // 电力遥测（PowerTelemetryData）
        var telemetry: [(String, String)] = []
        var efficiencyPct: Int? = nil
        if let ptd = e["PowerTelemetryData"] as? [String: Any] {
            for k in ptd.keys.sorted() {
                if let v = ptd[k] { telemetry.append((k, fmtAny(v))) }
            }
            if let pin = ptd["SystemPowerIn"] as? Int, pin > 0,
               let loss = ptd["AdapterEfficiencyLoss"] as? Int {
                efficiencyPct = Int((Double(pin - loss) / Double(pin)) * 100)
            }
        }

        // Mac 电池
        let cycle = e["CycleCount"] as? Int ?? 0
        var nominal = e["NominalChargeCapacity"] as? Int
        var design = e["DesignCapacity"] as? Int
        if (nominal == nil || design == nil), let bd = e["BatteryData"] as? String,
           let d = try? JSONSerialization.jsonObject(with: Data(bd.utf8)) as? [String: Any] {
            if nominal == nil { nominal = d["NominalChargeCapacity"] as? Int }
            if design == nil { design = d["DesignCapacity"] as? Int }
        }
        var health: Int? = nil
        if let n = nominal, let g = design, g > 0 { health = Int(Double(n) / Double(g) * 100) }
        let mac = (cycle: cycle, nominal: nominal, design: design, healthPct: health,
                   external: (e["ExternalConnected"] as? Bool) ?? false,
                   watts: a.watts)

        return SmartBatteryData(adapter: a, telemetry: telemetry, efficiencyPct: efficiencyPct, mac: mac)
    }

    static func readMacBattery() -> (cycle: Int, nominal: Int?, design: Int?, healthPct: Int?, external: Bool, watts: Int)? {
        guard let live = readAdapterLive() else { return nil }
        guard let res = run("/usr/sbin/ioreg", ["-r", "-n", "AppleSmartBattery", "-a"]),
              res.status == 0,
              let pl = try? PropertyListSerialization.propertyList(from: res.data, options: [], format: nil)
        else { return nil }
        let entry = (pl as? [[String: Any]])?.first ?? pl as? [String: Any]
        guard let e = entry as? [String: Any] else { return nil }
        let cycle = e["CycleCount"] as? Int ?? 0
        var nominal = e["NominalChargeCapacity"] as? Int
        var design = e["DesignCapacity"] as? Int
        if (nominal == nil || design == nil), let bd = e["BatteryData"] as? String,
           let d = try? JSONSerialization.jsonObject(with: Data(bd.utf8)) as? [String: Any] {
            if nominal == nil { nominal = d["NominalChargeCapacity"] as? Int }
            if design == nil { design = d["DesignCapacity"] as? Int }
        }
        var health: Int? = nil
        if let n = nominal, let g = design, g > 0 { health = Int(Double(n) / Double(g) * 100) }
        return (cycle, nominal, design, health, (e["ExternalConnected"] as? Bool) ?? false, live.watts)
    }

    static func intValue(_ row: [DimValue], _ dim: String) -> Int? {
        row.first { $0.dim == dim }?.value.isEmpty == false
            ? Int(row.first { $0.dim == dim }!.value) : nil
    }
    static func strValue(_ row: [DimValue], _ dim: String) -> String {
        row.first { $0.dim == dim }?.value ?? "-"
    }
}

// MARK: - 视图模型

final class Store: ObservableObject {
    @Published var live: [LiveInfo] = []
    @Published var records: [HealthRecord] = []
    @Published var statusText = "未加载数据"
    @Published var elevated = false
    @Published var dataTimeText = ""
    @Published var searchText = ""

    /// 搜索过滤：空串 = 全部显示
    func matches(_ text: String) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || text.localizedCaseInsensitiveContains(q)
    }

    var buds: [(side: String, row: [DimValue])] {
        var out: [(String, [DimValue])] = []
        for rec in records where rec.message.contains("AudioBatteryHealthShutdown") {
            for row in rec.rows {
                let side = DataSource.strValue(row, "bud_side")
                out.append((side == "1" ? "左耳" : side == "2" ? "右耳" : "耳 \(side)", row))
            }
        }
        return out
    }

    var caseRecords: [HealthRecord] {
        records.filter { $0.message.contains("AudioCapFadeView") }
    }

    var otherRecords: [HealthRecord] {
        records.filter { !$0.message.contains("AudioBatteryHealthShutdown") && !$0.message.contains("AudioCapFadeView") }
    }

    struct ShutdownEvent: Identifiable {
        let id = UUID()
        var time: Date?
        var side: String
        var ggsoc: Int
        var voltage: Int
        var temp: Int
        var cycle: Int
        var isNewest: Bool
    }

    var shutdownEvents: [ShutdownEvent] {
        var out: [ShutdownEvent] = []
        for rec in records where rec.message.contains("AudioBatteryHealthShutdown") {
            for row in rec.rows {
                let ts = DataSource.intValue(row, "timestamp")
                let time = ts.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
                let side = DataSource.strValue(row, "bud_side")
                out.append(ShutdownEvent(
                    time: time,
                    side: side == "1" ? "左" : side == "2" ? "右" : "?",
                    ggsoc: DataSource.intValue(row, "shutdown_GGSOC") ?? 0,
                    voltage: DataSource.intValue(row, "shutdown_voltage_0") ?? 0,
                    temp: DataSource.intValue(row, "shutdown_temperature_0") ?? 0,
                    cycle: DataSource.intValue(row, "cycle_count") ?? 0,
                    isNewest: false))
            }
        }
        out.sort { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
        if !out.isEmpty { out[0].isNewest = true }
        return out
    }

    func refreshLive() { live = DataSource.readLive() }

    func tryLoadExisting() {
        for dir in ["/tmp/analyticsd_gui", "/tmp/analyticsd_copy", "/tmp/analyticsd_now"] {
            if FileManager.default.isReadableFile(atPath: dir + "/state.sqlite") {
                load(from: dir)
                elevated = true
                return
            }
        }
    }

    func elevateAndLoad() {
        statusText = "请求管理员权限…"
        let res = DataSource.elevateAndCopy()
        statusText = res.message
        guard res.ok else { return }
        elevated = true
        load(from: "/tmp/analyticsd_gui")
    }

    func load(from dir: String) {
        let (recs, err) = DataSource.parseAnalytics(dir: dir)
        if let err = err { statusText = err; return }
        records = recs
        statusText = "已加载 \(recs.count) 个变换（\(recs.reduce(0) { $0 + $1.rows.count }) 条记录）"
        var maxTs: Double = 0
        for rec in recs {
            for row in rec.rows {
                for dv in row where dv.dim == "timestamp" {
                    if let v = Double(dv.value), v > maxTs { maxTs = v }
                }
            }
        }
        if maxTs > 1e14 {
            let dt = Date(timeIntervalSince1970: maxTs / 1_000_000)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            dataTimeText = "数据最后上报：\(fmt.string(from: dt))"
        } else {
            dataTimeText = ""
        }
    }

    // MARK: 免密机制

    var passwordlessInstalled: Bool {
        FileManager.default.isReadableFile(atPath: "/etc/sudoers.d/airpods-health")
            && FileManager.default.isReadableFile(atPath: "/usr/local/bin/airpods_copy.sh")
    }

    /// 一次性授权：安装免密拷贝脚本 + sudoers 规则（此后刷新不再要密码）
    @discardableResult
    func setupPasswordless() -> (ok: Bool, msg: String) {
        let user = NSUserName()
        let body = """
        #!/bin/sh
        mkdir -p /tmp/analyticsd_gui
        rm -rf /tmp/analyticsd_gui/*
        cp -R /var/db/analyticsd/ /tmp/analyticsd_gui/
        chown -R \(user) /tmp/analyticsd_gui
        """
        try? body.write(toFile: "/tmp/airpods_copy_install.sh", atomically: true, encoding: .utf8)
        // 规则仅限该脚本；先写 tmp 再 visudo 校验后 mv，避免写坏 sudoers
        let shell = "install -m 755 -o root -g wheel /tmp/airpods_copy_install.sh /usr/local/bin/airpods_copy.sh && echo '\(user) ALL=(root) NOPASSWD: /usr/local/bin/airpods_copy.sh' > /etc/sudoers.d/airpods-health.tmp && /usr/sbin/visudo -q -c -f /etc/sudoers.d/airpods-health.tmp && mv /etc/sudoers.d/airpods-health.tmp /etc/sudoers.d/airpods-health"
        let osaRes = DataSource.run("/usr/bin/osascript",
                ["-e", "do shell script \"\(shell)\" with administrator privileges"])
        guard let res = osaRes, res.status == 0 else {
            let err = String(decoding: osaRes?.data ?? Data(), as: UTF8.self)
            return (false, err.contains("User canceled") || err.contains("用户已取消") ? "已取消" : "授权失败：\(err.prefix(120))")
        }
        return (true, "免密授权完成（规则 /etc/sudoers.d/airpods-health，移除：sudo rm 该文件与 /usr/local/bin/airpods_copy.sh）")
    }

    /// 免密刷新：经 sudoers 规则拷贝最新数据并重新解析
    func refreshData() {
        guard passwordlessInstalled else { statusText = "尚未安装免密授权"; return }
        guard let res = DataSource.run("/usr/bin/sudo", ["-n", "/usr/local/bin/airpods_copy.sh"]), res.status == 0 else {
            statusText = "免密刷新失败（规则可能被移除，请重新授权）"
            return
        }
        load(from: "/tmp/analyticsd_gui")
    }

    /// 免密重新解析已有副本
    func reparseExisting() {
        for dir in ["/tmp/analyticsd_gui", "/tmp/analyticsd_now", "/tmp/analyticsd_copy"] {
            if FileManager.default.isReadableFile(atPath: dir + "/state.sqlite") {
                load(from: dir)
                return
            }
        }
        statusText = "没有已拷贝的数据，请先提权"
    }

    func autoRefresh() {
        if passwordlessInstalled { refreshData() } else { reparseExisting() }
    }

    // MARK: 充电 / 电源
    struct ChargingData {
        var adapterLive: DataSource.AdapterLive?
        var samples: [DataSource.ChargeSample]
        var ports: [DataSource.PortRow]
        var events: [DataSource.AdapterEvent]
        var mac: (cycle: Int, nominal: Int?, design: Int?, healthPct: Int?, external: Bool, watts: Int)?
        var telemetry: [(String, String)]
        var efficiencyPct: Int?
    }
    @Published var charging: ChargingData?

    func loadCharging() {
        let sb = DataSource.readSmartBattery()
        guard let d = DataSource.readCharging() else {
            if let s = sb {
                charging = ChargingData(adapterLive: s.adapter, samples: [], ports: [],
                                        events: [], mac: s.mac, telemetry: s.telemetry,
                                        efficiencyPct: s.efficiencyPct)
            }
            return
        }
        charging = ChargingData(adapterLive: sb?.adapter, samples: d.samples,
                                ports: d.ports, events: d.events, mac: sb?.mac,
                                telemetry: sb?.telemetry ?? [], efficiencyPct: sb?.efficiencyPct)
    }

}

// MARK: - 导航

enum SidebarItem: String, CaseIterable, Identifiable {
    case airpods, charging, registry, report, watch, iphone, mac, other, raw
    var id: String { rawValue }
    var title: String {
        switch self {
        case .airpods: return "AirPods Pro"
        case .charging: return "充电 / 电源"
        case .registry: return "全部设备 / IORegistry"
        case .report: return "解读报告"
        case .watch: return "Apple Watch"
        case .iphone: return "iPhone / iPad"
        case .mac: return "Mac 电池"
        case .other: return "其他配件"
        case .raw: return "原始数据"
        }
    }
    var icon: String {
        switch self {
        case .airpods: return "airpodspro"
        case .charging: return "cable.connector"
        case .registry: return "cpu"
        case .report: return "doc.text.magnifyingglass"
        case .watch: return "applewatch"
        case .iphone: return "iphone"
        case .mac: return "laptopcomputer"
        case .other: return "puzzlepiece"
        case .raw: return "tablecells"
        }
    }
    var reserved: Bool { self != .airpods && self != .charging && self != .registry && self != .mac && self != .report && self != .raw }
}

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var sel: SidebarItem? = CommandLine.arguments.contains("--registry") ? .registry : .airpods

    var body: some View {
        NavigationSplitView {
            List(selection: $sel) {
                Section("设备") {
                    SidebarRow(item: .airpods, active: true)
                    SidebarRow(item: .charging, active: true)
                    SidebarRow(item: .registry, active: true)
                    SidebarRow(item: .mac, active: true)
                }
                Section("其他设备（预留数据位）") {
                    SidebarRow(item: .watch, active: false)
                    SidebarRow(item: .iphone, active: false)
                    SidebarRow(item: .other, active: false)
                }
                Section("工具") {
                    SidebarRow(item: .report, active: true)
                    SidebarRow(item: .raw, active: true)
                }
            }
            .navigationTitle("配件健康")
        } detail: {
            switch sel {
            case .airpods, nil:
                AirPodsPage(store: store)
            case .charging:
                ChargingPage(store: store)
            case .registry:
                RegistryPage()
            case .report:
                ReportTab(store: store)
            case .raw:
                RawTab(store: store)
            case .mac:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let c = store.charging {
                            MacBatteryCard(info: c.mac)
                            ExplainBox(title: "关于本页", lines: [
                                "Mac 内置电池的健康数据来自 SMC（ioreg AppleSmartBattery 节点）",
                                "循环计数 = 完整充放电周期累计；健康度 = 当前满容量 / 设计容量",
                                "更多电池细节可在系统报告（关于本机 → 系统报告 → 电源）查看",
                            ])
                        } else {
                            ProgressView("读取中…").frame(maxWidth: .infinity).padding(40)
                        }
                    }
                    .padding()
                }
                .onAppear { store.loadCharging() }
            case let item?:
                ReservedPage(item: item)
            }
        }
        .frame(minWidth: 1050, minHeight: 700)
        .onAppear {
            store.tryLoadExisting()
            store.refreshLive()
            NSApp.activate(ignoringOtherApps: true)   // 后台拉起时强制成为活动应用，否则键盘输入进不来
        }
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    let active: Bool
    var body: some View {
        Label {
            HStack {
                Text(item.title)
                if !active {
                    Spacer()
                    Text("预留").font(.caption2).foregroundColor(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.icon)
                .foregroundColor(active ? .accentColor : .secondary)
        }
        .tag(item)
    }
}

// MARK: - AirPods 页

struct AirPodsPage: View {
    @ObservedObject var store: Store
    let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    let autoTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeroCard(store: store)
                ToolbarRow(store: store)
                ForEach(Array(store.buds.enumerated()), id: \.offset) { _, bud in
                    BudHealthCard(side: bud.side, row: bud.row,
                                  capacityRow: store.caseRecords.flatMap(\.rows).first {
                                      DataSource.strValue($0, "bud_side") == DataSource.strValue(bud.row, "bud_side")
                                  } ?? [])
                }
                ShutdownHistoryCard(events: store.shutdownEvents, query: store.searchText)
                ForEach(store.caseRecords) { rec in
                    CaseCard(rec: rec)
                }
                if store.records.isEmpty {
                    ContentUnavailableViewCompat(store: store)
                }
            }
            .padding()
        }
        .onReceive(timer) { _ in store.refreshLive() }
        .onReceive(autoTimer) { _ in store.autoRefresh() }
    }
}

// 顶部 Hero 卡：连接状态 + 电量三环 + 固件/序列号
struct HeroCard: View {
    @ObservedObject var store: Store
    var body: some View {
        GroupBox {
            HStack(spacing: 22) {
                Image(systemName: "airpodspro")
                    .font(.system(size: 44))
                    .foregroundStyle(store.live.isEmpty ? .secondary : .primary)
                VStack(alignment: .leading, spacing: 4) {
                    if let i = store.live.first {
                        Text(i.name).font(.title3).bold()
                        HStack(spacing: 8) {
                            Chip("固件 \(i.firmwareVersion)", .blue)
                            Chip("内部 9.1.42 beta", .orange)
                            Chip("PID \(i.address)", .gray)
                        }
                        Text("盒 \(i.serial)  ·  左 \(i.serialLeft)  ·  右 \(i.serialRight)")
                            .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    } else {
                        Text("AirPods 未连接").font(.title3)
                        Text("电量仅在蓝牙连接时刷新；健康数据见下方（需提权）")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let i = store.live.first {
                    HStack(spacing: 16) {
                        RingGauge(level: i.caseLevel, label: "充电盒", color: .gray)
                        RingGauge(level: i.leftLevel, label: "左耳", color: .blue)
                        RingGauge(level: i.rightLevel, label: "右耳", color: .green)
                    }
                }
            }
            .padding(10)
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color
    init(_ t: String, _ c: Color) { text = t; color = c }
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

struct RingGauge: View {
    let level: Int
    let label: String
    let color: Color
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(level) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(level)%").font(.callout).monospacedDigit().bold()
            }
            .frame(width: 64, height: 64)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }
}

struct ToolbarRow: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            if store.passwordlessInstalled {
                Button { store.refreshData() } label: {
                    Label("提权刷新（免密）", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("经 sudoers 规则免密拷贝最新数据；移除规则：sudo rm /etc/sudoers.d/airpods-health /usr/local/bin/airpods_copy.sh")
            } else {
                Button { store.elevateAndLoad() } label: {
                    Label("提权读取（需密码）", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                Button { _ = store.setupPasswordless() } label: {
                    Label("安装免密授权（推荐）", systemImage: "key")
                }
                .help("输一次密码安装免密规则（仅限本工具的拷贝脚本），之后所有刷新不再要密码")
            }
            Button { store.reparseExisting() } label: {
                Label("重新解析", systemImage: "doc.text.magnifyingglass")
            }
            .help("免密：重新解析已拷贝到 /tmp 的数据快照")
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索字段/值…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .help("即时过滤：原始数据 / 关机历史 / 双耳卡片的字段与数值（不区分大小写）")
            Text(store.statusText).font(.footnote).foregroundColor(.secondary)
            Spacer()
            if !store.dataTimeText.isEmpty {
                Text(store.dataTimeText).font(.footnote).foregroundColor(.orange)
            }
        }
    }
}

// 💡 解读块
struct ExplainBox: View {
    let title: String
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("💡 " + title).font(.caption).foregroundColor(.secondary)
            ForEach(lines, id: \.self) { l in
                Text("• " + l).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// 双耳健康卡片
struct BudHealthCard: View {
    let side: String
    let row: [DimValue]
    var capacityRow: [DimValue] = []

    var cycleCount: Int { DataSource.intValue(row, "cycle_count") ?? 0 }
    var capacity: Int { DataSource.intValue(row, "capacity_mAh") ?? 0 }
    var ggsoc: Int { DataSource.intValue(row, "shutdown_GGSOC") ?? 0 }
    var mileage: Int { DataSource.intValue(row, "bud_mileage") ?? 0 }
    var fieldDays: Int { DataSource.intValue(row, "time_in_field_days") ?? 0 }

    var milestones: [DegradationPoint] {
        var pts: [DegradationPoint] = []
        for i in 0..<8 {
            let cd = "milestone_cycle_count_at_capacity_\(i)"
            let md = "milestone_capacity_mAh_\(i)"
            // 优先使用同一份固件记录中的完整坐标对，再回退到关机记录 / 缓存。
            let source = (DataSource.intValue(capacityRow, md) ?? 0) > 0
                && DataSource.intValue(capacityRow, cd) != nil ? capacityRow : row
            if let c = DataSource.intValue(source, cd), c >= 0,
               let mv = source.first(where: { $0.dim == md }), let m = Int(mv.value), m > 0 {
                let cached = mv.fromCache || (source.first { $0.dim == cd }?.fromCache ?? false)
                pts.append(DegradationPoint(cycle: c, mAh: m, fromCache: cached))
            }
        }
        return pts.sorted(by: { $0.cycle < $1.cycle })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("\(side)", systemImage: "airpodspro").font(.headline)
                    Chip("\(cycleCount) 次循环", .purple)
                    Chip("\(capacity) mAh", .blue)
                    Chip("SOC \(ggsoc)%", ggsocColor(ggsoc))
                    Spacer()
                }
                DegradationChart(points: milestones, currentCapacity: capacity,
                                 currentCycle: DataSource.intValue(row, "cycle_at_capacity"))

                DisclosureGroup("使用情况与设备信息") {
                    VStack(alignment: .leading, spacing: 8) {
                        stat("累计使用", String(format: "%.1f 天", Double(DataSource.intValue(row, "total_time_s") ?? 0) / 86400))
                        stat("服役时长", serviceText(fieldDays).text)
                        stat("首次使用", serviceText(fieldDays).firstUse)
                        stat("累计放电", String(format: "%.1f Ah", Double(mileage) / 1000))
                        stat("欠压(掉电)事件", "\(DataSource.intValue(row, "brownout_count") ?? 0) 次")
                        stat("左右耳序列号", "\(DataSource.strValue(row, "serial_number_left")) / \(DataSource.strValue(row, "serial_number_right"))")
                        stat("盒固件版本号", DataSource.strValue(row, "case_sw_version"))
                    }.padding(.top, 8)
                }

                ExplainBox(title: "这些数字怎么读", lines: [
                    "循环计数：每完成一个完整充放电周期 +1，左右耳独立计",
                    "容量 mAh：最近一次固件上报的满充容量；可与最早里程碑比较变化",
                    "容量趋势：连线仅连接固件记录点，区间内的容量未实测；保持率相对最早记录，不等同于官方健康度",
                    "欠压事件：电池电压过低的掉电记录，频繁出现 = 电池/负载异常",
                    "关机 SOC：每次断电时电量计读数快照（区别于界面显示的 UISOC）",
                ])
            }
            .padding(10)
        }
    }

    func stat(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).frame(width: 110, alignment: .leading).foregroundColor(.secondary)
            Text(v).textSelection(.enabled)
        }.font(.callout)
    }
}

// 容量趋势：坐标刻度、当前容量、历史来源与可查询的记录点。
struct DegradationPoint: Identifiable {
    let cycle: Int
    let mAh: Int
    let fromCache: Bool
    var isCurrent = false
    var id: String { "\(cycle)-\(mAh)-\(isCurrent)" }
    var source: String { isCurrent ? "当前容量" : fromCache ? "历史缓存" : "固件里程碑" }
    var color: Color { isCurrent ? .teal : fromCache ? .orange : .blue }
}

struct DegradationChart: View {
    let points: [DegradationPoint]
    let currentCapacity: Int
    var currentCycle: Int? = nil
    @State private var fullScale = false
    @State private var selectedCycle: Double?
    @State private var selectedID: String?

    var plottedPoints: [DegradationPoint] {
        var result = points.filter { $0.cycle >= 0 && $0.mAh > 0 }
        if let cycle = currentCycle, cycle >= 0, currentCapacity > 0 {
            result.removeAll { $0.cycle == cycle && $0.mAh == currentCapacity }
            result.append(DegradationPoint(cycle: cycle, mAh: currentCapacity, fromCache: false, isCurrent: true))
        }
        var seen = Set<String>()
        return result.sorted { $0.cycle < $1.cycle }.filter { seen.insert($0.id).inserted }
    }

    var baseline: DegradationPoint? { points.filter { $0.mAh > 0 }.min { $0.cycle < $1.cycle } }
    var focus: DegradationPoint? {
        if let cycle = selectedCycle {
            return plottedPoints.min { abs(Double($0.cycle) - cycle) < abs(Double($1.cycle) - cycle) }
        }
        return plottedPoints.first { $0.id == selectedID } ?? plottedPoints.last
    }
    var xMax: Double { max(50, ceil(Double(plottedPoints.map(\.cycle).max() ?? 0) / 50) * 50) }
    var yRange: ClosedRange<Double> {
        let minimum = Double(plottedPoints.map(\.mAh).min() ?? 0)
        let maximum = Double(plottedPoints.map(\.mAh).max() ?? max(currentCapacity, 1))
        let padding = max(2, (maximum - minimum) * 0.2)
        return (fullScale ? 0 : max(0, floor(minimum - padding)))...ceil(maximum + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ChartMetric(title: "当前容量", value: currentCapacity > 0 ? "\(currentCapacity) mAh" : "暂无", color: .teal)
                ChartMetric(title: "最早记录", value: baseline.map { "\($0.mAh) mAh" } ?? "暂无")
                ChartMetric(title: "容量变化", value: capacityChange)
                ChartMetric(title: "相对保持率", value: retention, color: .blue)
            }
            HStack {
                Text("容量衰减趋势").font(.headline)
                Spacer()
                Toggle("纵轴从 0 开始", isOn: $fullScale).toggleStyle(.checkbox).font(.caption)
            }
            if plottedPoints.isEmpty {
                Text("暂无可绘制的容量记录；等待固件上报容量与对应循环数。")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 180)
            } else {
                plot
                HStack(spacing: 16) {
                    legend("固件里程碑", .blue)
                    if points.contains(where: \.fromCache) { legend("历史缓存", .orange) }
                    legend("当前容量", .teal)
                    Spacer()
                    Text(fullScale ? "完整容量范围" : "纵轴放大 · \(Int(yRange.lowerBound))–\(Int(yRange.upperBound)) mAh")
                        .foregroundColor(.secondary).font(.caption)
                }
                HStack {
                    if let point = focus {
                        Text("\(point.source)  ·  \(point.cycle) 次循环  ·  \(point.mAh) mAh")
                            .monospacedDigit().foregroundColor(point.color)
                    }
                    Spacer()
                    Text("悬停或点击查看记录").foregroundColor(.secondary)
                }
                .font(.callout).padding(10)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                DisclosureGroup("全部容量记录（\(plottedPoints.count) 个点）") {
                    ForEach(plottedPoints) { point in
                        Button { selectedID = point.id; selectedCycle = nil } label: {
                            HStack {
                                Text("\(point.cycle) 次循环").frame(width: 100, alignment: .leading)
                                Text("\(point.mAh) mAh").bold()
                                Spacer()
                                Text(point.source).foregroundColor(point.color)
                            }.font(.callout).monospacedDigit().padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("容量变化 = 当前容量 − 最早记录；保持率 = 当前容量 ÷ 最早记录 × 100%，不等同于官方健康度。mAh（毫安时）表示电池容量。")
                .font(.caption).foregroundColor(.secondary)
            Text("连线仅连接固件记录点，未测量区间不作预测。\(plottedPoints.count < 2 ? "仅有一个记录点，暂不能判断衰减趋势。" : "")")
                .font(.caption).foregroundColor(.secondary)
            if currentCapacity > 0 && currentCycle == nil {
                Text("当前容量缺少对应循环数，已展示数值，未添加曲线坐标。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    var capacityChange: String {
        guard let first = baseline, currentCapacity > 0 else { return "暂无" }
        return String(format: "%+d mAh", currentCapacity - first.mAh)
    }
    var retention: String {
        guard let first = baseline, currentCapacity > 0 else { return "暂无" }
        return String(format: "%.1f%%", Double(currentCapacity) / Double(first.mAh) * 100)
    }

    func legend(_ title: String, _ color: Color) -> some View {
        Label { Text(title) } icon: { Circle().fill(color).frame(width: 8, height: 8) }.font(.caption)
    }

    var plot: some View {
        Chart {
            if let first = baseline {
                RuleMark(y: .value("最早容量", first.mAh))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(plottedPoints) { point in
                if plottedPoints.count > 1 {
                    LineMark(x: .value("循环次数", point.cycle), y: .value("容量", point.mAh))
                        .interpolationMethod(.linear).foregroundStyle(Color.blue.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                PointMark(x: .value("循环次数", point.cycle), y: .value("容量", point.mAh))
                    .foregroundStyle(point.color).symbolSize(point.isCurrent ? 100 : 55)
                    .accessibilityLabel("\(point.source)，\(point.cycle) 次循环，\(point.mAh) 毫安时")
                    .annotation(position: .bottom, alignment: point.isCurrent ? .trailing : .leading) {
                        if point.isCurrent {
                            Text("当前 \(point.mAh) mAh").font(.caption).bold().foregroundColor(.teal)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.background, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
            }
            if selectedCycle != nil, let point = focus {
                RuleMark(x: .value("选中循环", point.cycle))
                    .foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [3, 3]))
                PointMark(x: .value("选中循环", point.cycle), y: .value("选中容量", point.mAh))
                    .foregroundStyle(point.color.opacity(0.2)).symbolSize(220)
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: 0...xMax)
        .chartYScale(domain: yRange)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) {
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.16))
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartXAxisLabel("累计充放电循环（次）")
        .chartYAxisLabel("容量（mAh）")
        .chartXSelection(value: $selectedCycle)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let frame = proxy.plotFrame {
                                let rect = geometry[frame]
                                selectedCycle = rect.contains(location)
                                    ? proxy.value(atX: location.x - rect.minX, as: Double.self) : nil
                            }
                        case .ended: selectedCycle = nil
                        }
                    }
                    .onTapGesture { if let point = focus { selectedID = point.id } }
            }
        }
        .frame(height: 240)
    }
}

struct ChartMetric: View {
    let title: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundColor(color).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 关机事件历史卡
struct ShutdownHistoryCard: View {
    let events: [Store.ShutdownEvent]
    var query: String = ""

    var filtered: [Store.ShutdownEvent] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return events }
        return events.filter { e in
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            return query.isEmpty
                || String(e.ggsoc).contains(query) || String(e.voltage).contains(query)
                || (e.time.map { f.string(from: $0) } ?? "").contains(query)
                || e.side.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("关机事件历史（固件断电快照）", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Text("耳机每次断电（放回盒/休眠/耗尽）时记录当时电量计 SOC、电压、温度")
                    .font(.caption).foregroundColor(.secondary)
                ExplainBox(title: "怎么读这张表", lines: [
                    "这不是「没电关机」记录——放回盒子合盖休眠也会记一条快照",
                    "SOC 高 + 电压 4.0V = 满电入盒（正常）；SOC 个位数 + 电压 3.5V = 真耗尽关机",
                    "频繁出现低 SOC 关机 = 续航衰减信号，配合欠压计数一起看",
                ])
                Divider()
                let evs = filtered
                if evs.isEmpty {
                    Text(query.isEmpty ? "提权读取后显示" : "没有匹配的关机事件").font(.caption).foregroundColor(.secondary)
                }
                ForEach(evs) { e in
                    HStack(spacing: 10) {
                        Text(e.time.map { fmtTime($0) } ?? "-")
                            .font(.caption).monospacedDigit()
                            .frame(width: 92, alignment: .leading)
                        Chip(e.side, e.side == "左" ? .blue : .green)
                        Chip("SOC \(e.ggsoc)%", ggsocColor(e.ggsoc))
                        Text("\(e.voltage) mV").font(.caption).monospacedDigit().frame(width: 62, alignment: .leading)
                        Text("\(e.temp)°C").font(.caption).monospacedDigit().frame(width: 38, alignment: .leading)
                        Spacer()
                        Text("循环 \(e.cycle)").font(.caption).foregroundColor(.secondary)
                        if e.isNewest { Chip("最新", .orange) }
                    }
                    .padding(.vertical, 1)
                    if e.id != evs.last?.id { Divider() }
                }
            }
            .padding(10)
        }
    }

    func fmtTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

// 按固件的 bud_side 展示充电分布，分档物理边界未确认时不推断百分比或摄氏度。
struct CaseCard: View {
    let rec: HealthRecord
    @State private var selectedRow = 0

    var row: [DimValue] {
        rec.rows.indices.contains(selectedRow) ? rec.rows[selectedRow] : rec.rows.first ?? []
    }
    var sharedMaximum: Double {
        rec.rows.flatMap { ChargeMatrix(row: $0).cells }.map(\.value).max() ?? 0
    }
    func rowTitle(_ index: Int) -> String {
        let side = DataSource.strValue(rec.rows[index], "bud_side")
        let title = side == "1" ? "左耳" : side == "2" ? "右耳" : "记录 \(index + 1)"
        let duplicates = rec.rows.filter { DataSource.strValue($0, "bud_side") == side }.count
        return duplicates > 1 ? "\(title) · 记录 \(index + 1)" : title
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("充电分布 · 电量 × 电池温度", systemImage: "square.grid.3x3.fill").font(.headline)
                    Spacer()
                    if rec.rows.count > 1 {
                        Picker("耳机记录", selection: $selectedRow) {
                            ForEach(rec.rows.indices, id: \.self) { i in Text(rowTitle(i)).tag(i) }
                        }.pickerStyle(.segmented).frame(maxWidth: 280)
                    } else if !rec.rows.isEmpty {
                        Chip(rowTitle(0), .blue)
                    }
                }
                ChargeHeatmap(matrix: ChargeMatrix(row: row), sharedMaximum: sharedMaximum)
                    .id(selectedRow)
                DisclosureGroup("充电时长与原始指标") {
                    FlowStats(rows: row).padding(.top, 8)
                    Text("最高电压 \(DataSource.strValue(row, "voltage_max_mV")) mV · 最低电压 \(DataSource.strValue(row, "voltage_min_mV")) mV")
                        .font(.caption).foregroundColor(.secondary)
                    Text("数据来源：\(rec.message) · \(rec.sink)").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(10)
        }
    }
}

struct ChargeCell: Identifiable {
    let soc: Int
    let temp: Int
    let value: Double
    var id: String { "\(soc)-\(temp)" }
}

struct ChargeMatrix {
    let row: [DimValue]
    static let prefix = "acc_charge_throughput_soc_temp_matrix_ma_per_min_"
    // STFW 9.1.42：0x080528be 累加 mA×秒，0x0805298c 除以 60 后上报。
    // 数值单位为 mA·min，进一步除以 60 才是 mAh；不是名字中的 mA/min。
    static func milliampHours(_ raw: Double) -> Double { raw / 60 }
    // 9.1.42 的分档表位于 0x0806e84c / 0x0806e85e（9.0.348 相同）。
    static let socThresholds = [0, 10, 20, 40, 60, 80, 85, 90, 95]
    static let temperatureThresholds = [0, 20, 27, 35, 42]
    var hasVerifiedBands: Bool {
        DataSource.intValue(row, "sw_version") == 9_503_393
            && DataSource.intValue(row, "product_id") == 0x2024 && socCount == 9 && tempCount == 5
    }
    func socLabel(_ index: Int) -> String {
        guard hasVerifiedBands, Self.socThresholds.indices.contains(index) else { return "电量档 \(index + 1)" }
        return "\(Self.socThresholds[index])–\(index == 8 ? 100 : Self.socThresholds[index + 1])%"
    }
    func temperatureLabel(_ index: Int) -> String {
        guard hasVerifiedBands, Self.temperatureThresholds.indices.contains(index) else { return "温度档 \(index + 1)" }
        if index == 0 { return "<20°C" }
        if index == 4 { return "≥42°C" }
        return "\(Self.temperatureThresholds[index])–\(Self.temperatureThresholds[index + 1])°C"
    }
    func region(_ cell: ChargeCell) -> String { "\(socLabel(cell.soc)) × \(temperatureLabel(cell.temp))" }
    var cells: [ChargeCell] {
        row.compactMap { dim in
            guard dim.dim.hasPrefix(Self.prefix) else { return nil }
            let indices = dim.dim.dropFirst(Self.prefix.count).split(separator: "_")
            guard indices.count == 2, let soc = Int(indices[0]), let temp = Int(indices[1]),
                  soc >= 0, temp >= 0, let value = Double(dim.value), value.isFinite, value >= 0 else { return nil }
            return ChargeCell(soc: soc, temp: temp, value: value)
        }
    }
    var socCount: Int { (cells.map(\.soc).max() ?? -1) + 1 }
    var tempCount: Int { (cells.map(\.temp).max() ?? -1) + 1 }
    var total: Double { cells.reduce(0) { $0 + $1.value } }
    var peak: ChargeCell? { cells.filter { $0.value > 0 }.max { $0.value < $1.value } }
    func cell(soc: Int, temp: Int) -> ChargeCell? { cells.first { $0.soc == soc && $0.temp == temp } }
    func percent(_ value: Double) -> String {
        guard total > 0 else { return "—" }
        let percent = value / total * 100
        return percent > 0 && percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent)
    }
}

struct ChargeHeatmap: View {
    let matrix: ChargeMatrix
    let sharedMaximum: Double
    @State private var showShare = true
    @State private var logarithmic = false
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @Environment(\.colorScheme) private var colorScheme

    var focusID: String? { hoveredID ?? selectedID ?? matrix.peak?.id }
    var focus: ChargeCell? { matrix.cells.first { $0.id == focusID } }
    func intensity(_ value: Double) -> Double {
        guard value > 0, sharedMaximum > 0 else { return 0 }
        return min(1, logarithmic ? log1p(value) / log1p(sharedMaximum) : value / sharedMaximum)
    }
    func fill(_ amount: Double) -> Color {
        // 不使用透明度编码，深浅两种外观均有稳定的色阶与文本对比。
        Color(red: 0.9 - 0.85 * amount, green: 0.95 - 0.53 * amount, blue: 0.99 - 0.25 * amount)
    }
    func chargeText(_ raw: Double, precise: Bool = false) -> String {
        ChargeMatrix.milliampHours(raw).formatted(.number.precision(.fractionLength(precise ? 2 : 0))) + " mAh"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ChartMetric(title: "累计充入电荷（固件估算）", value: chargeText(matrix.total))
                ChartMetric(title: "最集中区域（电量 × 电池温度）", value: matrix.peak.map { matrix.region($0) } ?? "暂无", color: .blue)
                ChartMetric(title: "该格占已上报总量", value: matrix.peak.map { matrix.percent($0.value) } ?? "—", color: .blue)
            }
            HStack {
                Text("格内显示").font(.caption).fixedSize()
                Picker("格内显示", selection: $showShare) {
                    Text("占比").tag(true)
                    Text("充入电荷 (mAh)").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                Toggle("增强小值（对数色阶）", isOn: $logarithmic).toggleStyle(.checkbox).font(.caption)
            }
            if matrix.cells.isEmpty {
                Text("暂无充电分布数据；等待固件上报电量与温度矩阵。")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 180)
            } else {
                GeometryReader { geometry in
                    let cellWidth = max(74, (geometry.size.width - 100) / CGFloat(max(matrix.tempCount, 1)) - 6)
                    ScrollView(.horizontal) {
                        matrixGrid(cellWidth: cellWidth)
                    }
                }.frame(height: CGFloat(matrix.socCount) * 54 + 80)
                colorLegend
                HStack {
                    if let cell = focus {
                        Text(matrix.region(cell)).bold()
                        Text("\(chargeText(cell.value, precise: true)) · \(matrix.percent(cell.value))")
                            .monospacedDigit()
                        Spacer()
                        Text("原值 \(cell.value.formatted()) mA·min").font(.caption).foregroundColor(.secondary)
                    } else if let id = focusID {
                        let indices = id.split(separator: "-").compactMap { Int($0) }
                        if indices.count == 2 {
                            Text("\(matrix.socLabel(indices[0])) × \(matrix.temperatureLabel(indices[1])) · 未上报")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("暂无非零累计值").foregroundColor(.secondary)
                    }
                }
                .font(.callout).padding(10)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            ExplainBox(title: "数值怎么读", lines: [
                "充入电荷：耳机电池充电电流 × 充电时间的累计量，汇总多次充电，所以会远大于单次满充容量。",
                "换算：固件原值单位是 mA·min，除以 60 得到 mAh。例如原来的 144k（144,027）折算约 2,400.45 mAh。",
                "占比：该格充入电荷 ÷ 当前耳机全部已上报格子的充入电荷；例如 18.5% 表示约占总量的五分之一。",
                "颜色：越深表示累计充入电荷越多，左右耳使用同一色阶；它不表示当前容量、健康度或充电次数。",
                matrix.hasVerifiedBands ? "分档来自 9.1.42 固件；区间下限包含、上限不含（100% 除外），电量采用电量计 SOC，温度为电池温度。" : "此固件的分档边界尚未验证，保留档位编号。",
            ])
        }
    }

    func matrixGrid(cellWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("电量：高 → 低 ↓                         电池温度：低 → 高 →")
                .font(.caption).foregroundColor(.secondary)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text("电量（SOC）").font(.caption).foregroundColor(.secondary).frame(width: 88)
                    ForEach(0..<matrix.tempCount, id: \.self) { temp in
                        Text(matrix.temperatureLabel(temp)).font(.callout).frame(width: cellWidth, height: 30)
                    }
                }
                ForEach(Array((0..<matrix.socCount).reversed()), id: \.self) { soc in
                    GridRow {
                        Text(matrix.socLabel(soc)).font(.callout).frame(width: 88, alignment: .trailing)
                        ForEach(0..<matrix.tempCount, id: \.self) { temp in
                            heatCell(soc: soc, temp: temp, width: cellWidth)
                        }
                    }
                }
            }
        }
    }

    func heatCell(soc: Int, temp: Int, width: CGFloat) -> some View {
        let cell = matrix.cell(soc: soc, temp: temp)
        let value = cell?.value ?? 0
        let amount = intensity(value)
        let textColor: Color = value > 0 ? (amount > 0.89 ? .white : Color(red: 0.015, green: 0.02, blue: 0.035)) : .secondary
        let id = "\(soc)-\(temp)"
        let isFocused = id == focusID
        return Button { selectedID = id } label: {
            VStack(spacing: 2) {
                Text(cell == nil ? "—" : value == 0 ? "0" : showShare ? matrix.percent(value) : chargeText(value, precise: value < 60))
                    .font(.system(size: 14, weight: value > 0 ? .semibold : .regular, design: .rounded))
                    .foregroundColor(textColor)
                if value > 0 {
                    Text(showShare ? chargeText(value, precise: value < 60) : "占比 " + matrix.percent(value))
                        .font(.system(size: 11)).foregroundColor(textColor)
                }
            }
            .monospacedDigit().frame(width: width, height: 48)
            .background(value > 0 ? fill(amount) : Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.07),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? id : nil }
        .help(cell.map { "\(matrix.region($0))：\(chargeText($0.value, precise: true))（原值 \($0.value.formatted()) mA·min），占比 \(matrix.percent($0.value))" } ?? "此格未上报")
        .accessibilityLabel(cell.map { "\(matrix.region($0))，累计充入 \(chargeText($0.value, precise: true))，占比 \(matrix.percent($0.value))" } ?? "\(matrix.socLabel(soc))，\(matrix.temperatureLabel(temp))，未上报")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    var colorLegend: some View {
        HStack(spacing: 12) {
            Text(logarithmic ? "mAh · 对数色阶" : "mAh · 线性色阶").font(.caption).foregroundColor(.secondary)
            VStack(spacing: 4) {
                LinearGradient(stops: (0...10).map { .init(color: fill(Double($0) / 10), location: Double($0) / 10) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 10).clipShape(Capsule())
                HStack {
                    Text("0")
                    Spacer()
                    Text(ChargeMatrix.milliampHours(logarithmic ? expm1(log1p(sharedMaximum) / 2) : sharedMaximum / 2).formatted(.number.precision(.fractionLength(0...1))))
                    Spacer()
                    Text(ChargeMatrix.milliampHours(sharedMaximum).formatted(.number.precision(.fractionLength(0...1))))
                }.font(.caption).monospacedDigit().foregroundColor(.secondary)
            }.frame(maxWidth: 260)
            Spacer()
            Text("0 = 明确零值    — = 未上报").font(.caption).foregroundColor(.secondary)
        }
    }
}

struct FlowStats: View {
    let rows: [DimValue]
    var body: some View {
        let items = rows
            .filter { $0.dim.hasPrefix("time_charging") || $0.dim.hasPrefix("timeAbove95") || $0.dim.hasPrefix("time_in_field") || $0.dim.hasPrefix("vac_milestone") }
            .sorted { $0.dim < $1.dim }
        ForEach(items, id: \.id) { dv in
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(cn(dv.dim)).font(.caption2)
                    Text(dv.dim).font(.system(size: 8)).foregroundColor(.secondary)
                }
                Spacer()
                Text(dv.value).font(.caption).monospacedDigit().textSelection(.enabled)
            }
        }
    }
}

// MARK: - 充电 / 电源页

struct ChargingPage: View {
    @ObservedObject var store: Store
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c = store.charging {
                    if let a = c.adapterLive {
                        AdapterLiveCard(a: a)
                    } else {
                        GroupBox {
                            HStack {
                                Image(systemName: "powerplug").font(.title2).foregroundColor(.secondary)
                                Text("未检测到充电器").font(.headline)
                                Text("插上充电器后 30 秒内自动出现").font(.caption).foregroundColor(.secondary)
                            }.padding(10).frame(maxWidth: .infinity)
                        }
                    }
                    if !c.telemetry.isEmpty {
                        TelemetryCard(rows: c.telemetry, efficiency: c.efficiencyPct)
                    }
                    ChargeCurveCard(samples: c.samples)
                    AdapterHistoryCard(events: c.events)
                    PortStatsCard(ports: c.ports)
                    MacBatteryCard(info: c.mac)
                } else {
                    ProgressView("读取 PowerLog …").frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding()
        }
        .onAppear { store.loadCharging() }
        .onReceive(timer) { _ in store.loadCharging() }
    }
}

struct AdapterLiveCard: View {
    let a: DataSource.AdapterLive
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(a.name.isEmpty ? "当前充电器" : a.name, systemImage: "cable.connector").font(.headline)
                    Chip(a.connected ? "外接供电中" : "未外接", a.connected ? .green : .gray)
                    Spacer()
                }
                if !a.manufacturer.isEmpty || !a.model.isEmpty {
                    HStack(spacing: 8) {
                        Chip(a.manufacturer, .blue)
                        Chip("型号 \(a.model)", .purple)
                        Chip("固件 \(a.fwVersion)", .gray)
                        if !a.isWireless { Chip("有线", .gray) } else { Chip("无线", .gray) }
                    }
                }
                kvRow("描述", a.desc)
                kvRow("硬件版本", a.hwVersion.isEmpty ? "-" : a.hwVersion)
                kvRow("序列号", a.serial.isEmpty ? "-" : a.serial)
                kvRow("输入电压", "\(a.voltageMV) mV")
                kvRow("输入电流", "\(a.currentMA) mA")
                kvRow("输出功率", "\(a.watts) W")
                kvRow("功率档位", "Tier \(a.tier)")
                if !a.menu.isEmpty {
                    Text("USB-PD 可用档位（当前使用第 \(a.hvcIndex + 1) 档）:")
                        .font(.caption).foregroundColor(.secondary)
                    ForEach(a.menu, id: \.idx) { m in
                        HStack(spacing: 8) {
                            Chip(m.idx == a.hvcIndex ? "使用中" : "档 \(m.idx + 1)", m.idx == a.hvcIndex ? .orange : .gray)
                            Text("\(m.mv) mV · \(m.ma) mA").font(.callout).monospacedDigit()
                        }
                    }
                }
                ExplainBox(title: "档位表 = 充电器的 PDO 菜单", lines: [
                    "每行是充电器宣告的一档电压/电流（USB-PD Source Capabilities）",
                    "「使用中」= 当前合同所在的档位；Mac 会按需在档位间切换",
                ])
            }
            .padding(10)
        }
    }

    func kvRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).frame(width: 80, alignment: .leading).foregroundColor(.secondary)
            Text(v).monospacedDigit().textSelection(.enabled)
            Spacer()
        }.font(.callout)
    }
}

struct TelemetryCard: View {
    let rows: [(String, String)]
    let efficiency: Int?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("充电器实时遥测（PowerTelemetryData）", systemImage: "bolt.horizontal")
                        .font(.headline)
                    if let e = efficiency {
                        Spacer()
                        Chip("效率 ≈ \(e)%", .green)
                    }
                }
                Text("SMC 每 30 秒采样一次的 Mac 侧电力遥测——与抓包 JSON 的充电器侧字段互补")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(rows, id: \.0) { kv in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(cn(kv.0)).font(.caption)
                            Text(kv.0).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(kv.1).font(.caption).monospacedDigit().textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 1)
                }
                ExplainBox(title: "与抓包 JSON 的关系", lines: [
                    "i-oreg 这份 = Mac 侧电力遥测（输入电压/电流/功率、效率损耗、累计能量，SMC 30 秒采样）",
                    "抓包 JSON 里的充电器侧字段（ocp_count、SentCurrent、UptimeAVS…）不走 i-oreg——它们进 analyticsd（需 root）",
                ])
            }
            .padding(10)
        }
    }
}

struct ChargeCurveCard: View {
    let samples: [DataSource.ChargeSample]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("充电功率曲线（PowerLog 最近采样）", systemImage: "chart.xyaxis.line").font(.headline)
                #if canImport(Charts)
                Chart(samples) { s in
                    LineMark(x: .value("时间", s.date), y: .value("功率 W", Double(s.mv * s.ma) / 1_000_000))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel("W")
                .frame(height: 180)
                #endif
                if let last = samples.last {
                    Text("最新：\(last.mv) mV · \(last.ma) mA（\(last.mv * last.ma / 1000) W）")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(10)
        }
    }
}

struct AdapterHistoryCard: View {
    let events: [DataSource.AdapterEvent]
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("适配器接入历史（AdapterDetails）", systemImage: "clock").font(.headline)
                if events.isEmpty { Text("暂无记录").font(.caption).foregroundColor(.secondary) }
                ForEach(Array(events.enumerated()), id: \.offset) { i, e in
                    HStack {
                        Text(fmt(e.date)).font(.caption).monospacedDigit().frame(width: 110, alignment: .leading)
                        Text("\(e.model)").font(.caption)
                        Spacer()
                        Text("\(e.watts) W · Tier \(e.tier)").font(.caption).monospacedDigit()
                    }
                    if i < events.count - 1 { Divider() }
                }
            }
            .padding(10)
        }
    }

    func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}

struct PortStatsCard: View {
    let ports: [DataSource.PortRow]
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("USB-PD 端口控制器统计", systemImage: "cpu").font(.headline)
                Text("Mac 的每个 Type-C 口由独立端口控制器管理；UVDM 计数 = 与苹果配件（如 MagSafe 线）的私有通讯次数")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(ports, id: \.port) { pr in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("端口 \(pr.port)").font(.callout).bold()
                            if pr.uvdmEnum > 0 { Chip("UVDM 活跃", .purple) }
                            Spacer()
                            Text("接入 \(pr.attach) · 断开 \(pr.detach)").font(.caption).foregroundColor(.secondary)
                        }
                        if pr.maxPower > 0 { Text("历史最大功率：\(pr.maxPower) mW").font(.caption) }
                        ForEach(Array(pr.pdos.enumerated()), id: \.offset) { i, p in
                            Text("PDO\(i+1)：\(p.text)")
                                .font(.caption2)
                                .foregroundColor(p.kind == 3 ? .orange : .secondary)
                        }
                        Divider()
                    }
                }
            }
            .padding(10)
        }
    }
}

struct MacBatteryCard: View {
    let info: (cycle: Int, nominal: Int?, design: Int?, healthPct: Int?, external: Bool, watts: Int)?
    var body: some View {
        GroupBox(label: Label("Mac 内置电池", systemImage: "laptopcomputer.and.iphone")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let i = info { Chip("循环 \(i.cycle)", .purple) }
                    Spacer()
                }
                if let i = info {
                    if let h = i.healthPct {
                        HStack(spacing: 10) {
                            Text("电池健康度").foregroundColor(.secondary)
                            Text("\(h)%").font(.title2).bold().monospacedDigit()
                            Text("(当前 \(i.nominal ?? 0) / 设计 \(i.design ?? 0) mAh)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        Text("健康度暂不可读（需要更多电池数据样本）").font(.caption).foregroundColor(.secondary)
                    }
                    if i.external, i.watts > 0 {
                        Text("正在由 \(i.watts) W 充电器供电").font(.caption).foregroundColor(.green)
                    }
                } else {
                    Text("暂无数据").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(10)
        }
    }
}

struct ReservedPage: View {
    let item: SidebarItem
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: item.icon).font(.system(size: 56)).foregroundColor(.secondary.opacity(0.5))
            Text(item.title).font(.title2)
            Text("此数据位已预留").font(.headline).foregroundColor(.secondary)
            Text("该页已预留显示位置，接入对应设备的数据后将展示：\n实时电量 / 循环计数 / 容量退化曲线 / 遥测明细 / 事件历史")
                .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
            GroupBox {
                HStack(spacing: 14) {
                    ForEach(["实时状态", "电池健康", "事件历史", "遥测明细"], id: \.self) { t in
                        VStack(spacing: 6) {
                            Image(systemName: "chart.bar.doc.horizontal").foregroundColor(.secondary)
                            Text(t).font(.caption).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
                .padding(12)
            }
            .padding(.horizontal, 60)
            .opacity(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ContentUnavailableViewCompat: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "airpodspro").font(.system(size: 44)).foregroundColor(.secondary)
            Text("尚无健康数据").font(.headline)
            Text("点击「提权读取」并确保 AirPods 曾与这台 Mac 连接过。\n数据由耳机固件经 CoreAnalytics 上报后落盘。")
                .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}

// 解读报告页（动态 markdown，数据实时带入）
struct ReportTab: View {
    @ObservedObject var store: Store

    func reportMarkdown() -> String {
        var L: [String] = []
        L.append("# AirPods Pro 电池健康报告")
        var meta: [String] = []
        if !store.dataTimeText.isEmpty { meta.append(store.dataTimeText) }
        if let i = store.live.first { meta.append("固件 \(i.firmwareVersion)（内部 9.1.42 beta）") }
        if !meta.isEmpty { L.append("*\(meta.joined(separator: " · "))*") }
        L.append("")
        L.append("## 一、当前快照")
        if let i = store.live.first {
            L.append("- 电量：充电盒 \(i.caseLevel)% · 左耳 \(i.leftLevel)% · 右耳 \(i.rightLevel)%")
        }
        for b in store.buds {
            let c = DataSource.intValue(b.row, "cycle_count") ?? 0
            let cap = DataSource.intValue(b.row, "capacity_mAh") ?? 0
            let days = DataSource.intValue(b.row, "time_in_field_days") ?? 0
            let g = DataSource.intValue(b.row, "shutdown_GGSOC") ?? 0
            let st = serviceText(days)
            L.append("- **\(b.side)**：循环 \(c) 次 · 容量 \(cap) mAh · 关机SOC \(g)% · 服役 \(st.text)（\(st.firstUse)）")
        }
        L.append("")
        L.append("## 二、指标怎么读")
        L.append("- **循环计数**：每完成一个完整充放电周期 +1，左右耳独立计")
        L.append("- **容量 mAh**：最近一次固件上报的满充容量，可与最早里程碑比较变化")
        L.append("- **容量趋势**：连线仅连接记录点，区间内不作预测；保持率相对最早记录，不等同于官方健康度")
        L.append("- **欠压(掉电)事件**：电池电压过低的掉电记录，频繁出现 = 电池/负载异常")
        L.append("- **关机 SOC**：每次断电时电量计读数快照（区别于界面显示的 UISOC）")
        L.append("")
        L.append("## 三、健康解读")
        for b in store.buds {
            let capacityRow = store.caseRecords.flatMap(\.rows).first {
                DataSource.strValue($0, "bud_side") == DataSource.strValue(b.row, "bud_side")
            } ?? []
            let card = BudHealthCard(side: b.side, row: b.row, capacityRow: capacityRow)
            let chart = DegradationChart(points: card.milestones, currentCapacity: card.capacity,
                                         currentCycle: DataSource.intValue(b.row, "cycle_at_capacity"))
            if let baseline = chart.baseline, card.capacity > 0 {
                L.append("- **\(b.side)**：最早记录 \(baseline.mAh) mAh → 当前 \(card.capacity) mAh，变化 \(chart.capacityChange)，相对保持率 \(chart.retention)")
            } else {
                L.append("- **\(b.side)**：历史容量记录不足，暂不能计算相对保持率")
            }
        }
        L.append("- 关机快照记录当时 SOC、电压和温度；结合容量趋势与欠压事件评估使用状况")
        L.append("")
        L.append("## 四、充电习惯画像")
        L.append("- 充电分布：按电量与电池温度累计充入耳机电池的电荷；固件原值单位为 mA·min，除以 60 折算为 mAh")
        for rec in store.caseRecords {
            for (index, row) in rec.rows.enumerated() {
                let side = DataSource.strValue(row, "bud_side")
                let label = side == "1" ? "左耳" : side == "2" ? "右耳" : "记录 \(index + 1)"
                let matrix = ChargeMatrix(row: row)
                let totalCharge = ChargeMatrix.milliampHours(matrix.total).formatted(.number.precision(.fractionLength(2)))
                L.append("- **\(label)**：已上报累计充入电荷 \(totalCharge) mAh（跨多次充电累计，不是当前容量）")
                if let peak = matrix.peak {
                    let charge = ChargeMatrix.milliampHours(peak.value).formatted(.number.precision(.fractionLength(2)))
                    L.append("- **\(label)**：充入电荷最集中于 \(matrix.region(peak))，累计 \(charge) mAh，占该耳已上报总量 \(matrix.percent(peak.value))")
                }
                if let hours = DataSource.intValue(row, "timeAbove95_h") {
                    L.append("- **\(label)**：高电量（>95% SOC）驻留累计 \(hours) 小时")
                }
            }
        }
        L.append("- 已验证的 Pro 2 / 9.1.42 固件使用实际分档范围；其他型号或版本保留档位编号。颜色越深表示充入电荷越多，不表示健康程度")
        L.append("")
        L.append("## 五、说明")
        L.append("- 本报告数据来自耳机固件经 CoreAnalytics 上报的聚合快照，由本机 analyticsd 存储")
        L.append("- 聚合窗口可能被系统重置（重置后里程碑重新积累，工具会用本地缓存补齐历史曲线）")
        L.append("- 原始解析逻辑与固件逆向结论见 magsafe_out 目录各分析文档")
        return L.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let md = reportMarkdown()
                let attr = (try? AttributedString(
                    markdown: md,
                    options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(md)
                Text(attr)
                    .textSelection(.enabled)
                    .lineSpacing(4)
            }
            .padding(18)
        }
    }
}

// 原始数据页
struct RawTab: View {
    @ObservedObject var store: Store

    var filteredRecords: [HealthRecord] {
        guard !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return store.records }
        return store.records.compactMap { rec in
            let rows = rec.rows.map { row in
                row.filter { store.matches($0.dim) || store.matches($0.value) || store.matches(cn($0.dim)) }
            }.filter { !$0.isEmpty }
            guard !rows.isEmpty else { return nil }
            var r = rec
            r.rows = rows
            return r
        }
    }

    var body: some View {
        Group {
            if store.records.isEmpty {
                ContentUnavailableViewCompat(store: store)
            } else if filteredRecords.isEmpty {
                VStack {
                    Text("没有匹配「\(store.searchText)」的条目").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).padding(40)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredRecords) { rec in
                            GroupBox(label: Label("\(rec.message)  (匹配 \(rec.rows.count) 行, sink=\(rec.sink))", systemImage: "list.bullet.rectangle")) {
                                ForEach(Array(rec.rows.enumerated()), id: \.offset) { i, row in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("记录 \(i+1)").font(.caption).foregroundColor(.secondary)
                                        ForEach(row) { dv in
                                            HStack {
                                                VStack(alignment: .leading, spacing: 0) {
                                                    Text(cn(dv.dim)).font(.system(size: 11))
                                                    Text(dv.dim).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                                                }
                                                Spacer()
                                                Text(dv.value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                            }
                                        }
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - App 入口

@main
struct AirPodsHealthViewerApp: App {
    init() {
        if CommandLine.arguments.contains("--registry-self-test") {
            exit(RegistryReader.selfTest() ? 0 : 1)
        }
    }
    var body: some Scene {
        WindowGroup("配件电池健康") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
