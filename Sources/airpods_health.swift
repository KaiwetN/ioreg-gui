#!/usr/bin/env swift
// airpods_health.swift — AirPods 电量与电池健康数据读取器
//
// 用法：
//   swift airpods_health.swift                模式①：电量/固件/序列号（免 root，数据来自 system_profiler）
//   sudo swift airpods_health.swift --health  模式②：扫描 analyticsd 中的电池健康聚合（需 root）
//   swift airpods_health.swift --json         机器可读输出（模式①）
//
// 背景结论（详见 A2968 固件分析）：
//   • macOS 蓝牙面板只暴露「电量百分比 + 固件版本」，没有健康度 UI；
//   • 耳机固件把循环计数/容量/退化曲线作为 CoreAnalytics 指标
//     com.apple.Bluetooth.AccessoryBatteryHealthV4Metric 上报，
//     落盘在 /var/db/analyticsd/（root-only），这就是 --health 模式去挖的地方；
//   • 显示版本号（如 9B42a）对应内部版本 9.1.42（Build 9B5042a）。

import Foundation
import SQLite3

// MARK: - 工具

func runCommand(_ launchPath: String, _ args: [String]) -> (data: Data, status: Int32)? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = Pipe()
    do { try proc.run() } catch { return nil }
    proc.waitUntilExit()
    return (outPipe.fileHandleForReading.readDataToEndOfFile(), proc.terminationStatus)
}

func printableContext(_ data: Data, around offset: Int, radius: Int = 80) -> String {
    let lo = max(0, offset - radius), hi = min(data.count, offset + radius)
    let slice = data.subdata(in: lo..<hi)
    let str = String(decoding: slice, as: UTF8.self)
    return String(str.map { $0.isASCII && !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } ? $0 : "." })
}

// MARK: - 模式①：system_profiler（免 root）

struct AirPodsInfo {
    var name: String
    var address: String?
    var caseLevel: String?
    var leftLevel: String?
    var rightLevel: String?
    var caseVersion: String?
    var firmwareVersion: String?
    var serial: String?
    var serialLeft: String?
    var serialRight: String?
    var productID: String?
    var services: String?
}

func readAirPodsViaSystemProfiler() -> [AirPodsInfo] {
    guard let res = runCommand("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
          res.status == 0,
          let root = try? JSONSerialization.jsonObject(with: res.data) as? [String: Any],
          let btList = root["SPBluetoothDataType"] as? [[String: Any]]
    else { return [] }

    var result: [AirPodsInfo] = []
    for bt in btList {
        guard let connected = bt["device_connected"] as? [[String: Any]] else { continue }
        for dev in connected {
            for (name, raw) in dev {
                guard let p = raw as? [String: Any] else { continue }
                let minor = p["device_minorType"] as? String ?? ""
                let isAppleHeadphones = (p["device_vendorID"] as? String) == "0x004C"
                    && (minor == "Headphones" || name.lowercased().contains("airpods"))
                if !isAppleHeadphones { continue }
                result.append(AirPodsInfo(
                    name: name,
                    address: p["device_address"] as? String,
                    caseLevel: p["device_batteryLevelCase"] as? String,
                    leftLevel: p["device_batteryLevelLeft"] as? String,
                    rightLevel: p["device_batteryLevelRight"] as? String,
                    caseVersion: p["device_caseVersion"] as? String,
                    firmwareVersion: p["device_firmwareVersion"] as? String,
                    serial: p["device_serialNumber"] as? String,
                    serialLeft: p["device_serialNumberLeft"] as? String,
                    serialRight: p["device_serialNumberRight"] as? String,
                    productID: p["device_productID"] as? String,
                    services: p["device_services"] as? String
                ))
            }
        }
    }
    return result
}

func printLevels(_ infos: [AirPodsInfo], asJSON: Bool) {
    if asJSON {
        let payload: [[String: Any?]] = infos.map { i in
            ["name": i.name, "address": i.address, "caseLevel": i.caseLevel,
             "leftLevel": i.leftLevel, "rightLevel": i.rightLevel,
             "caseVersion": i.caseVersion, "firmwareVersion": i.firmwareVersion,
             "serial": i.serial, "serialLeft": i.serialLeft, "serialRight": i.serialRight,
             "productID": i.productID, "services": i.services]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["airpods": payload], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    guard !infos.isEmpty else {
        print("未发现已连接的 AirPods。请连接后重试（电量数据仅在连接时上报）。")
        return
    }
    for i in infos {
        print("━━━ \(i.name) ━━━")
        print("  地址           : \(i.address ?? "-")  (productID \(i.productID ?? "-"), Apple)")
        print("  电量  盒       : \(i.caseLevel ?? "-")")
        print("  电量  左耳     : \(i.leftLevel ?? "-")")
        print("  电量  右耳     : \(i.rightLevel ?? "-")")
        print("  固件  盒       : \(i.caseVersion ?? "-")")
        print("  固件  耳机     : \(i.firmwareVersion ?? "-")")
        print("  序列号 盒      : \(i.serial ?? "-")")
        print("  序列号 左/右   : \(i.serialLeft ?? "-") / \(i.serialRight ?? "-")")
        print("  服务           : \(i.services ?? "-")")
    }
    print()
    print("  提示：显示版本（如 9B42a）= 内部版本 9.1.42（Build 9B5042a，beta 通道）。")
    print("  此处只有电量；循环计数/容量等健康数据见固件指标")
    print("  com.apple.Bluetooth.AccessoryBatteryHealthV4Metric，需 --health（sudo）模式从 analyticsd 挖取。")
}

// MARK: - 模式②：analyticsd 扫描（需 root）

let healthKeywords: [String] = [
    "AccessoryBatteryHealth", "BatteryHealthV4", "healthV3",
    "cycle_count", "chg_cycle_cnt", "capacity_mAh",
    "milestone_capacity_mAh", "milestone_cycle_count",
]

func scanAnalyticsd() {
    let dir = "/var/db/analyticsd"
    let fm = FileManager.default
    guard fm.isReadableFile(atPath: dir) else {
        print("无法读取 \(dir) —— 需要 root：")
        print("  sudo swift \(CommandLine.arguments.first ?? "airpods_health.swift") --health")
        return
    }

    print("扫描 \(dir) …")
    guard let enumerator = fm.enumerator(atPath: dir) else { return }
    var scanned = 0, hits = 0

    while let sub = enumerator.nextObject() as? String {
        let path = dir + "/" + sub
        guard let attr = try? fm.attributesOfItem(atPath: path),
              let size = attr[.size] as? Int, size > 0, size < 200_000_000,
              let data = fm.contents(atPath: path)
        else { continue }
        scanned += 1

        // 找命中的关键词及其上下文
        var matched: [(String, String)] = []
        for kw in healthKeywords {
            guard let range = data.range(of: Data(kw.utf8)) else { continue }
            matched.append((kw, printableContext(data, around: range.lowerBound)))
        }
        guard !matched.isEmpty else { continue }
        hits += 1
        print("\n━━━ 命中: \(path) (\(size)B) ━━━")
        for (kw, ctx) in matched.prefix(6) {
            print("  [\(kw)] …\(ctx)…")
        }

        // 尝试按 plist 解码（analyticsd 聚合常为 binary plist）
        if let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            print("  [plist 解码成功，顶层类型: \(type(of: pl))]")
            if let dict = pl as? [String: Any] {
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                    let vs = String(describing: v)
                    print("    \(k) = \(vs.prefix(120))")
                }
            }
        }
    }
    print("\n扫描完成：\(scanned) 个文件，\(hits) 个命中电池健康关键词。")
    print("说明：聚合文件多为二进制格式；若命中但解码失败，可把命中的文件拷出来离线分析")
    print("（复制本工具输出的路径即可）。")
}

// MARK: - 模式③：解析 analyticsd 的 state.sqlite（需先 sudo 拷贝）

func decodeState(_ dir: String) {
    let statePath = dir + "/state.sqlite"
    let configPath = dir + "/config.sqlite"
    for p in [statePath, configPath] where !FileManager.default.isReadableFile(atPath: p) {
        print("缺 \(p)。先执行： sudo cp -R /var/db/analyticsd /tmp/analyticsd_copy && sudo chown -R $(whoami) /tmp/analyticsd_copy")
        return
    }
    var db1: OpaquePointer?, db2: OpaquePointer?
    // 注意：必须以读写模式打开——READONLY 连接读不到 WAL 中未合并的最新数据
    guard sqlite3_open_v2(statePath, &db1, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          sqlite3_open_v2(configPath, &db2, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        print("sqlite 打开失败"); return
    }
    defer { sqlite3_close(db1); sqlite3_close(db2) }

    // 找出所有 transform_def 里含 BatteryHealth 的变换
    var uuidDefs: [(uuid: String, dims: [String], message: String, sink: String)] = []
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db2, "SELECT transform_uuid, transform_def FROM composed_transforms_view", -1, &stmt, nil)
    while sqlite3_step(stmt) == SQLITE_ROW {
        let uuid = String(cString: sqlite3_column_text(stmt, 0))
        let defStr = String(cString: sqlite3_column_text(stmt, 1))
        guard defStr.contains("BatteryHealth"), let d = try? JSONSerialization.jsonObject(with: Data(defStr.utf8)) as? [String: Any],
              let dimsRaw = d["dimensions"] as? [[String: Any]]
        else { continue }
        let dims = dimsRaw.compactMap { $0["name"] as? String }
        let out = (d["outputs"] as? [[String: Any]])?.first
        let msg = out?["message"] as? String ?? "?"
        let sink = out?["sink"] as? String ?? "?"
        uuidDefs.append((uuid, dims, msg, sink))
    }
    sqlite3_finalize(stmt)
    print("发现 \(uuidDefs.count) 个 BatteryHealth 相关变换：")
    for u in uuidDefs { print("   \(u.uuid) → \(u.message) (\(u.dims.count) 维, sink=\(u.sink))") }

    // 逐状态行映射维度
    var stateRows = 0
    sqlite3_prepare_v2(db1, """
        SELECT tm.transform_uuid, ts.transform_key, ts.transform_value
        FROM transform_states ts JOIN transform_metadata tm
          ON ts.transform_metadata_id = tm.transform_metadata_id
        """, -1, &stmt, nil)
    while sqlite3_step(stmt) == SQLITE_ROW {
        stateRows += 1
        let uuid = String(cString: sqlite3_column_text(stmt, 0))
        let keyStr = String(cString: sqlite3_column_text(stmt, 1))
        let cnt = sqlite3_column_int(stmt, 2)
        guard let def = uuidDefs.first(where: { uuid.hasPrefix($0.uuid) }),
              let vals = try? JSONSerialization.jsonObject(with: Data(keyStr.utf8)) as? [Any?]
        else { continue }
        print("━━━ \(def.message)  sink=\(def.sink)  事件数=\(cnt) ━━━")
        for (i, dim) in def.dims.enumerated() {
            guard i < vals.count, let v = vals[i] else { continue }
            if let n = v as? Int, n == 0 { continue }
            if v is NSNull { continue }
            print("   \(dim) = \(v)")
        }
        print()
    }
    sqlite3_finalize(stmt)
}

// MARK: - main

let args = CommandLine.arguments
if args.contains("--health") {
    scanAnalyticsd()
} else if let idx = args.firstIndex(of: "--state") {
    decodeState(idx + 1 < args.count ? args[idx + 1] : "/tmp/analyticsd_copy")
} else {
    printLevels(readAirPodsViaSystemProfiler(), asJSON: args.contains("--json"))
}
