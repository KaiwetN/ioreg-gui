# ioreg-gui

**macOS IORegistry 可视化工具** —— 以**只读**方式枚举 IORegistry 各 plane 的设备与服务节点，展开属性树、分类、搜索、导出；在此之上对部分 Apple 配件（AirPods、Mac 电池、充电/电源）做专门的数据展示。

> 全程**只读**：只通过 `IORegistryEntryCreateCFProperties` 等查询接口读取系统公开信息，不访问驱动控制接口、不发送任何控制命令、不上传任何数据。

---

## 功能

### 1. IORegistry 浏览器（核心）

侧边栏「全部设备 / IORegistry」。

- **多 plane 枚举**：`IOService` / `IODeviceTree` / `IOUSB` / `IOPower`（运行时从根节点 `IORegistryPlanes` 动态取得）
- **节点列表 + 属性树**：左列节点、右列属性详情，保留原始类型 —— 字符串 / 数值（同时给出十进制与十六进制）/ 布尔 / 二进制（显示字节数与 hex 前导）/ 数组 / 字典，可展开嵌套
- **分类筛选**：电池·电源、USB、雷雳·PCI、蓝牙、音频、图形·显示、存储、网络、传感器·输入、其他硬件·系统服务（启发式分类，含驱动与虚拟服务）
- **搜索**：节点级搜索 + 节点内属性搜索
- **属性详情弹窗**：完整值、类型、可选中复制
- **自动刷新**：可选 30 秒轮询
- **导出**：typed JSON 快照（`IORegistry typed snapshot v1`，二进制同时保留 base64 与 hex，数值保留精确十进制文本）
- 底部状态栏显示可见节点数 / 总节点数与快照时间

### 2. 设备页

| 页面 | 状态 | 内容 |
|---|---|---|
| AirPods Pro | 已实现 | 实时电量三环（15 秒刷新）、左右耳循环计数、满充容量、容量退化曲线、关机事件历史、充电吞吐热力图、解读报告 |
| 充电 / 电源 | 已实现 | 充电器 / 线缆 / 端口相关信息与电源状态 |
| Mac 电池 | 已实现 | 来自 `ioreg` 的 `AppleSmartBattery`（SMC）节点：循环计数、健康度、容量 |
| Apple Watch / iPhone·iPad / 其他配件 | 预留 | 侧边栏占位，尚未接入数据 |

### 3. 工具页

- **解读报告**：把当前采集到的指标自动整理成中文白话分析
- **原始数据**：底层采集结果的原始视图

## 系统要求

- macOS 14.0 或更高（Intel / Apple Silicon 通用）
- AirPods 页需要一台曾连接过目标 AirPods 的 Mac
- 读取 AirPods「电池健康」页需一次管理员授权（安装仅限本工具的免密规则，可随时移除）
- IORegistry 浏览与 Mac 电池页**免 root**

## 安装（推荐）

到 [Releases](../../releases) 下载最新的 `ioreg-gui-*.dmg`，打开后把 App 拖入 Applications。

首次运行因未做苹果公证签名，需**右键点 App → 打开 → 再点打开**；若仍被拦，终端执行：

```sh
xattr -cr "/Applications/IORegistry 查看器.app"
```

AirPods 页的详细使用说明见 [`Docs/AirPods页_使用说明.txt`](Docs/AirPods页_使用说明.txt)。

## 从源码构建

```sh
./scripts/build.sh      # 产出 build/IORegistry 查看器.app
./scripts/make-dmg.sh   # 产出 dist/ioreg-gui-<version>.dmg
```

或手动编译：

```sh
swiftc -target arm64-apple-macos14.0 -O -parse-as-library -disable-sandbox \
       -o IORegistryViewer Sources/IORegistryViewer.swift
```

> `-disable-sandbox` 用于规避受限环境下编译器无法为 SwiftUI 宏插件启动子沙箱的问题（否则报 `SwiftUIMacros ... malformed response`）。

命令行版本（免编译，直接用 swift 跑）：

```sh
swift Sources/airpods_health.swift                # 电量 / 固件 / 序列号（免 root）
sudo swift Sources/airpods_health.swift --health  # 扫描 analyticsd 电池健康聚合（需 root）
swift Sources/airpods_health.swift --json         # 机器可读输出
```

启动时带 `--registry` 参数可直接打开 IORegistry 页：

```sh
./IORegistryViewer --registry
```

## AirPods 页数据链路（逆向结论）

AirPods 是设备页里接入最深的一个，其数据链路与其他设备页不同，需要额外两层：

```text
实时层  system_profiler SPBluetoothDataType        （免 root，15s 刷新）
   │
健康层  bluetoothd → 耳机 metric Broker 拉取
        → TMAP 解码 → CoreAnalytics 事件
        com.apple.Bluetooth.AccessoryBatteryHealthV4Metric
        → /var/db/analyticsd/{config,state}.sqlite  （root-only，提权拷贝后解析）
   │
展示层  IORegistry 只读属性树 + SwiftUI/Charts 可视化
```

关键点：

- macOS 蓝牙面板只暴露「电量百分比 + 固件版本」，**没有健康度 UI**；循环计数 / 容量 / 退化曲线由耳机固件作为 CoreAnalytics 指标上报。
- 耳机只在**充电会话结束 / 放回盒子 / 每日翻转**时上报健康数据，所以循环计数一天变几次属正常。
- 充电吞吐热力图字段名里的 `ma_per_min` 具有误导性：**实际单位是 mA·min（毫安分钟）**，换算 `mAh = 原值 / 60`。

## 目录结构

```text
Sources/   IORegistryViewer.swift（主程序：IORegistry 浏览器 + 设备页，SwiftUI + IOKit + SQLite3）
           airpods_health.swift（CLI 读取器）
           airpods_throughput_evidence.py（STFW 固件热力图证据导出，需 capstone）
Docs/      A2968_AirPodsPro2充电盒_固件历史分析.md
           充电吞吐热力图_逆向结论.md
           connectAnalytics_本机可读性_调查报告.md
           AirPods页_使用说明.txt（AirPods 页）
Preview/   界面截图（trend / heatmap，含深色模式）与 verification.txt 验证输出
scripts/   build.sh / make-dmg.sh
Resources/ AppIcon.icns
```

## 隐私与免责

本工具**只读取本机已有数据**，不发起任何网络请求、不上传任何信息（系统自身的 analyticsd 按苹果常规策略聚合上报，与本工具无关）。

本项目为个人对本机数据的读取与固件静态分析，与 Apple Inc. 无关联。请自行承担使用风险。

## 许可

暂未指定开源许可证 —— 按默认版权保留（All rights reserved）。如需允许他人使用 / 修改 / 分发，请先补充 LICENSE。
