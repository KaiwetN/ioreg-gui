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
swift Sources/airpods_health.swift                # 电量 / 固件版本 / 序列号（免 root）
sudo swift Sources/airpods_health.swift --health  # 读取系统电池健康聚合数据（需 root）
swift Sources/airpods_health.swift --json         # 机器可读输出
```

启动时带 `--registry` 参数可直接打开 IORegistry 页：

```sh
./IORegistryViewer --registry
```

## 使用提示

- AirPods 的健康数据由耳机在**充电会话结束 / 放回盒子 / 每日翻转**时更新，因此循环计数这类数值一天变化几次属正常；页面顶部的「数据最后上报时间」表示数据新鲜度。
- IORegistry 分类为启发式结果，节点可能同时落在多个类别中；导出 JSON 会保留每个属性的完整类型信息。
- 浏览 IORegistry 与读取 Mac 电池不需要管理员权限；仅 AirPods 健康页需要一次授权。

## 目录结构

```text
Sources/   IORegistryViewer.swift（主程序：IORegistry 浏览器 + 设备页，SwiftUI + IOKit + SQLite3）
           airpods_health.swift（CLI 读取器）
           airpods_throughput_evidence.py（数据导出辅助脚本，需 capstone）
Docs/      AirPods页_使用说明.txt 及若干技术说明文档
Preview/   界面截图（trend / heatmap，含深色模式）与 verification.txt 验证输出
scripts/   build.sh / make-dmg.sh
Resources/ AppIcon.icns
```

## 隐私与免责

本工具**只读取本机已有数据**，不发起任何网络请求、不上传任何信息。

本项目为个人开发的本机数据读取工具，与 Apple Inc. 无关联。请自行承担使用风险。

## 许可

暂未指定开源许可证 —— 按默认版权保留（All rights reserved）。如需允许他人使用 / 修改 / 分发，请先补充 LICENSE。
