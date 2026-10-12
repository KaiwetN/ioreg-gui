# com.apple.ChargingCable.connectAnalytics — 本机可读性调查报告

日期：2026-10-09（凌晨）
主机：Mac（Apple Silicon，macOS 26）
现场：MagSafe3 线缆（A2363，FW 3.2.0）+ 40W 动态适配器（XID 0x701E）接着 MBP14

---

## TL;DR

1. **这个事件在本机是"活的"**：`/System/Library/PrivateFrameworks/CoreAnalytics.framework/Versions/A/Resources/defaultConfig.json` 里登记了两条聚合管线，Daily 落盘。
2. **原始 JSON 不落盘**：全盘扫描（`/usr/libexec`、`/usr/sbin`、`/usr/bin`、`PrivateFrameworks`、`Frameworks`、`CoreServices`、dyld 共享缓存）中，除 defaultConfig.json 外**没有任何文件**含 `connectAnalytics` 或 `ChargingCable` 字样 → 事件名是**数据驱动**的（从线缆 JSON 顶层键动态取得），所以二进制里没有硬编码。
3. **提交者高度指向 `usbctelemetryd`**：它链接 CoreAnalytics.framework、导入 `_AnalyticsSendEvent`，且专门从 `appleHPMDeviceService` / `appleHPMInterfaceService`（MagSafe 端口控制器）采集 `_analyticsDict`。
4. **本机此刻就能读到的**（免 root）：`ioreg` 实时计数器 + PowerLog SQLite（UVDM 计数、PDO、40W/60W 两档切换）。
5. **需要 root 的**：`/var/db/analyticsd/`（聚合报表的落盘位置，目录 700 root:wheel）。
6. **唯一能拿到完整原始 JSON（10 字段全集）** 的方式：你自己的 PD 分析仪抓包（如 `先查线再插电脑.csv`）。

---

## 1. 事件注册证据（CoreAnalytics 配置）

`defaultConfig.json` 实为 JSONL（9313 条记录，解析无碍）。命中 2 条 `addTransform`：

### 管线 A：ChargingCable_ConnectionCorrosionCountV2
```json
{
  "name": "ChargingCable_ConnectionCorrosionCountV2",
  "inputs": [{ "event": "com.apple.ChargingCable.connectAnalytics" }],
  "dimensions": ["FWVersion", "HWVersion"],
  "measures": ["sum_of_CorrosionPrevention", "sum_of_HostConnectCount", "Count"],
  "sink": "Daily"
}
```

### 管线 B：ChargingCable_FaultCounts
```json
{
  "name": "ChargingCable_FaultCounts",
  "inputs": [{ "event": "com.apple.ChargingCable.connectAnalytics" }],
  "dimensions": ["FWVersion", "HWVersion"],
  "measures": [
    "sum_of_ChgCLMVoltFault", "sum_of_HardFault", "sum_of_OtherFault",
    "sum_of_OverTempFault", "sum_of_OverVoltCLMCmd", "sum_of_TempReadFail",
    "sum_of_VoltDiffFault", "Count"
  ],
  "sink": "Daily"
}
```

### 事件字段全集（配置声明 = 11 个）
| 字段 | 线缆固件有吗 | 说明 |
|---|---|---|
| FWVersion / HWVersion | ✅ 3.1.8 / 3.1.12 / 3.2.0 都有 | 维度 |
| HostConnectCount | ✅ | 累计接主机次数 |
| CorrosionPrevention | ✅ | 防腐蚀动作计数 |
| ChgCLMVoltFault | ✅ | CLM 电压故障 |
| OverTempFault | ✅ | 过温故障 |
| OverVoltCLMCmd | ✅ | 过压 CLM 指令 |
| VoltDiffFault | ✅ | 压差故障 |
| HardFault | ✅ | 硬故障 |
| OtherFault | ✅ | 其他故障 |
| **TempReadFail** | ❌ **三个版本固件都没有** | 配置引用但固件不产生 → 预留字段（或用于其他内置测温的线缆） |

> 对照：适配器侧 `com.apple.poweradapter.Analytics` 在配置里有 11 条管线（PowerAdapterView_HwUserUsagePattern_V2、UsbpdObservation_V3、ProtectionSafety_V3/V1、Histogram 等），比线缆侧更多。

---

## 2. 提交者定位：usbctelemetryd

```
otool -L /usr/libexec/usbctelemetryd
  → /System/Library/PrivateFrameworks/CoreAnalytics.framework/... （链接）

nm -u /usr/libexec/usbctelemetryd
  → _AnalyticsSendEvent （导入符号，即"发事件"API）

strings /usr/libexec/usbctelemetryd
  → initializeWithHPMDeviceService:andHPMInterfaceService:andLogger:atRid:
  → collectAllAnalytics / _analyticsDict / set_analyticsDict:
  → "Failed to read FW Version data!" / "HPM Mode Register on Boot" / "AppLoaded Count"
  → 自身事件：com.apple.usbcd.reset_reasons、com.apple.usbctelemetryd.reset_reasons_type6

LaunchDaemon（com.apple.usbctelemetryd.plist）
  → StartCalendarInterval 每日 12:00:00 + com.apple.usbcd Repeating 每 86400s
```

**推断**：它把从 HPM 接口服务（如 `AppleHPMInterfaceType11`，带 `ConnectionCount`/`Plug Event Count`/`SOP UVDM Update Count` 等属性的那个节点）读到的字典统一转发成 CoreAnalytics 事件；事件名取自数据本身（线缆 JSON 的顶层键），因此二进制里找不到 `ChargingCable` 字样——这与全盘扫描结果自洽。

**注意**：约每天中午 12:00 采集一次，意味着 connectAnalytics 的故障计数是"日快照"粒度。

---

## 3. 数据链路（全貌）

```
线缆 A2363 (FW 3.2.0)
  │   UVDM over CC（SOP' 通道，抓包里 0x05AC8106 读请求 → 34 分块 673B JSON）
  ▼
Mac 端口控制器 AppleHPM Type11 / SMC（AppleSMCChargerUtil 持有 Brick ID 节点）
  │   ① IOKit 属性暴露（ioreg 可见）         ② PerfPowerServices 采样 → PowerLog
  ▼
usbctelemetryd（每日 12:00）
  │   AnalyticsSendEvent("com.apple.ChargingCable.connectAnalytics", {...})
  ▼
CoreAnalytics / analyticsd
      → 两条 Daily 聚合 → /var/db/analyticsd/（root 700）
```

---

## 4. 本机可读矩阵（实测）

| 数据 | 位置 / 工具 | 权限 | 备注 |
|---|---|---|---|
| 原始 673B JSON 全文 | **不落盘**；仅 UVDM 通道瞬时传输 | 抓包设备 | 你的分析仪是唯一全文来源 |
| FW Version / ConnectionCount / Plug Event Count / ConnectionUUID / SOP UVDM Update Count | `ioreg` AppleHPMInterfaceType11 | ✅ 免 root | 实测：7 / 14 / 5C381109-… / 0 |
| 线缆身份（SOP1 VID/PID） | `ioreg` IOPortTransportStateCC | ✅ 免 root | 实测：VID=1452(0x05AC)、PID=30720(0x7800) |
| 协商档位（5/9/15/20V）与当前 Winning | `ioreg` Power In 节点 | ✅ 免 root | Winning=20V/2.99A/59.8W |
| UVDM 枚举/状态次数 | PowerLog PortControllerInfo3 | ✅ 免 root | UvdmEnum=5、UvdmStsUpd=23 |
| 40W↔60W 两档切换 | PowerLog MaxPower + AdapterDetails | ✅ 免 root | 39800/59800 mW；Watts 40/60 tier1/2 |
| VBUS / 输入电流（AVS 动态） | PowerLog EventBackward_Adapter | ✅ 免 root | 18.5–19.6V / 0.5–1.1A 动态波动 |
| 适配器制造商/型号 | PowerLog AdapterDetails | ✅ 免 root | "Apple Inc." / 0x701E |
| UARP 升级状态 | PowerLog UARPStatus 表 | ✅ 免 root | 当前 0 行（本机没发生过线缆/适配器升级） |
| 故障计数聚合（connectAnalytics 结果） | `/var/db/analyticsd/` | ❌ 需 sudo | 目录 700 root:wheel，普通用户 ls 都被拒 |

---

## 5. 命令清单（前三条已实测通过）

```bash
# ① 线缆/端口实时计数器（免 root）
ioreg -r -c AppleHPMInterfaceType11 -l -w0 | grep -E '"(FW Version|ConnectionCount|Plug Event Count|ConnectionUUID|SOP UVDM Update Count)"'

# ② 线缆身份 SOP1（免 root）
ioreg -r -c IOPortTransportStateCC -l -w0 | grep -E 'SOP1|MagSafe'

# ③ PowerLog 查询（免 root，时间戳直接是 Unix epoch）
sqlite3 -readonly -header /var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL \
  "SELECT datetime(timestamp,'unixepoch','localtime') 时间, Manufacturer, Model, Watts, AdapterPowerTier
   FROM PLBatteryAgent_EventForward_AdapterDetails ORDER BY timestamp DESC LIMIT 10;"

# ④ 端口控制器 UVDM 计数（免 root；Info0-3 分别对应 4 个物理端口，Info3=MagSafe）
sqlite3 -readonly -header /var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL \
  "SELECT datetime(timestamp,'unixepoch','localtime'), PortControllerIrqCntUvdmEnum, PortControllerIrqCntUvdmStsUpd,
          PortControllerMaxPower, PortControllerNPDOs
   FROM PLBatteryAgent_EventForward_PortControllerInfo3 ORDER BY timestamp DESC LIMIT 10;"

# ⑤ 进入 CoreAnalytics 聚合目录（需要你自己跑 sudo）
sudo ls -la /var/db/analyticsd/
sudo find /var/db/analyticsd -type f | head -40
sudo grep -r -l "ChargingCable" /var/db/analyticsd/ 2>/dev/null | head
```

另：`/var/db/powerlog/Library/BatteryLife/Archives/` 有按天归档的 `powerlog_YYYY-MM-DD_*.PLSQL.gz`（rw-r--r--，免 root 可解压查询）。

---

## 6. 交叉印证（抓包 ↔ 系统数据）

| 发现 | 抓包侧 | 系统侧 |
|---|---|---|
| 适配器身份 | Extended Src Cap：VID/PID=0x05AC/0x8019，XID=0x0000701E | PowerLog AdapterDetails Model=**0x701E** |
| 线缆身份 | 线缆控制器 PID 0x7800 | ioreg CC 节点 **Product ID (SOP1)=30720(0x7800)**、Vendor ID=1452(0x05AC) |
| 40W↔60W 两档 | 两套 Source_Caps：{15V/2.67A, 20V/2A}（=40W）→ {15V/3A, 20V/3A}（=60W），间隔 2s | AdapterDetails：01:32:57 Watts=40 tier1 → 01:33:57 Watts=60 tier2 |
| 功率档切换痕迹 | —— | PortControllerInfo3 MaxPower 在 39800↔59800 mW 间来回切换 |
| AVS 动态调整 | 适配器 JSON：UptimeAVS=13162、"UptimePeakPwr" 等 | Adapter backward：SystemInputVoltage 18.5–19.6V、电流 0.5–1.1A 动态波动 |
| UVDM 会话量 | 每次连接一整轮 34 分块读 | UvdmEnum=5 轮、UvdmStsUpd=23 次（最近几晚的插入操作） |

---

## 7. 设计解读：为什么"原始 JSON"本机读不到

- 线缆侧：JSON 是固件里的**格式化模板**（`"com.apple.ChargingCable.connectAnalytics": {...}` 作为顶层键），按需经 UVDM 送出，不存储历史。
- 宿主侧：设计上只做**聚合**（CoreAnalytics Daily sink），不保留原始 payload；故障计数字段也没有任何本地数据库表承接（PowerLog 已全库 grep 过，0 命中）。
- 所以"读不到原始 JSON"不是权限问题，而是**架构上就没有这个落点**。
- 想拿完整字段：**继续用自己的分析仪抓**（这就是最正宗的来源）；或者 `sudo` 进 `/var/db/analyticsd/` 看故障计数字段的日聚合是否已写入（只含聚合后的计数值，不含原始结构）。

---

## 附：相关组件清单（本机实证）

| 组件 | 角色 |
|---|---|
| `/usr/libexec/usbctelemetryd`（com.apple.usbcd） | 采集 HPM 端口遥测 → AnalyticsSendEvent；每日 12:00 |
| `/System/Library/PrivateFrameworks/CoreAccessories.framework/Support/accessoryd` | 持有 IOAccessoryManagerUserClient（配件通道） |
| `UARPUpdaterServiceUSBPD.xpc`（MobileAccessoryUpdater.framework） | 持有 AppleHPMUserClient（UVDM 固件升级通道，_accessoryupdater 用户） |
| `AppleSMCChargerUtil`（com.apple.driver.AppleSMC 的内核节点） | 持有 "Brick ID"、USB-PD PowerSource 节点 |
| `PerfPowerServices` | 采样端口控制器统计 → PowerLog 各表 |
