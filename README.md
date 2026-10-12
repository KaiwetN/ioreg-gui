# ioreg-gui

**AirPods 电池健康查看器** —— 通过只读 IORegistry / IOKit 接口与 CoreAnalytics 聚合数据，读取 AirPods 耳机与充电盒的**深度电池健康信息**（Apple 从未在 macOS 上提供这个功能）。

> 项目性质：本机 I/O 接口（IORegistry / IOKit / CoreAnalytics）读取工具的 GUI 实现 + 配套固件逆向分析。
> 全程**只读**：不发送任何控制命令、不上传任何数据。

---

## 功能

| 页面 | 内容 |
|---|---|
| 实时状态 | 盒 / 左耳 / 右耳 三环电量，固件版本，序列号（15 秒自动刷新） |
| 电池健康 | 循环计数（左右耳独立）、当前满充容量、固件内置容量退化曲线、服役里程 |
| 关机事件历史 | 每次断电时的电量计 SOC / 电压 / 电池温度 |
| 充电分布 | 充电吞吐热力图（电量段 × 温度段），按 `bud_side` 切换左右耳 |
| 解读报告 | 自动生成的中文白话分析 |
| 原始数据 | 完整只读 IORegistry 属性树，保留原始类型（可导出 JSON） |

## 系统要求

- macOS 14.0 或更高（Intel / Apple Silicon 通用）
- 一台曾连接过目标 AirPods 的 Mac
- 读取「电池健康」页需一次管理员授权（安装仅限本工具的免密规则，可随时移除）

## 安装（推荐）

到 [Releases](../../releases) 下载最新的 `ioreg-gui-*.dmg`，打开后把 App 拖入 Applications。

首次运行因未做苹果公证签名，需**右键点 App → 打开 → 再点打开**；若仍被拦，终端执行：

```sh
xattr -cr "/Applications/AirPods电池健康查看器.app"
```

详见 [`Docs/使用说明.txt`](Docs/使用说明.txt)。

## 从源码构建

```sh
./scripts/build.sh      # 产出 build/AirPods电池健康查看器.app
./scripts/make-dmg.sh   # 产出 dist/ioreg-gui-<version>.dmg
```

或手动编译：

```sh
swiftc -target arm64-apple-macos14.0 -O -parse-as-library \
       -o AirPodsHealthViewer Sources/AirPodsHealthViewer.swift
```

命令行版本（免编译，直接用 swift 跑）：

```sh
swift Sources/airpods_health.swift              # 电量 / 固件 / 序列号（免 root）
sudo swift Sources/airpods_health.swift --health  # 扫描 analyticsd 电池健康聚合（需 root）
swift Sources/airpods_health.swift --json        # 机器可读输出
```

## 数据链路（逆向结论）

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
Sources/   AirPodsHealthViewer.swift（GUI 主程序，SwiftUI + IOKit + SQLite3）
           airpods_health.swift（CLI 读取器）
           airpods_throughput_evidence.py（STFW 固件热力图证据导出，需 capstone）
Docs/      A2968_AirPodsPro2充电盒_固件历史分析.md
           充电吞吐热力图_逆向结论.md
           connectAnalytics_本机可读性_调查报告.md
           使用说明.txt
Preview/   界面截图（trend / heatmap，含深色模式）与 verification.txt 验证输出
scripts/   build.sh / make-dmg.sh
Resources/ AppIcon.icns
```

## 隐私与免责

本工具**只读取本机已有数据**，不发起任何网络请求、不上传任何信息（系统自身的 analyticsd 按苹果常规策略聚合上报，与本工具无关）。

本项目为个人对本机数据的读取与固件静态分析，与 Apple Inc. 无关联。请自行承担使用风险。

## 许可

暂未指定开源许可证 —— 按默认版权保留（All rights reserved）。如需允许他人使用 / 修改 / 分发，请先补充 LICENSE。
