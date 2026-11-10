<div align="center">
  <img src="Resources/AppIcon-Light-1024.png" width="110" height="110" alt="SysPulse Icon" />
  <h1>SysPulse</h1>
  <p><strong>macOS (Apple Silicon) 系统监测、清理与扩展模块管理工具</strong></p>

  <p>
    <a href="https://github.com/Rabbit-Spec/macOS-SysPulse/releases"><img src="https://img.shields.io/github/v/release/Rabbit-Spec/macOS-SysPulse?style=flat-square&color=00B4D8" alt="Latest Release" /></a>
    <a href="https://github.com/Rabbit-Spec/macOS-SysPulse/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-2EC4B6?style=flat-square" alt="License: MIT" /></a>
    <img src="https://img.shields.io/badge/Platform-macOS%2026%2B%20%7C%20arm64-7209B7?style=flat-square" alt="Platform" />
    <a href="https://space.bilibili.com/7135720"><img src="https://img.shields.io/badge/Bilibili-汤圆__Lyric-FB7299?style=flat-square" alt="Bilibili" /></a>
  </p>
</div>

<p align="center">
  <img src="Resources/SysPulse-Poster-Light.png" width="860" alt="SysPulse 功能海报" />
</p>

---

## 功能说明

### 1. 状态总览与菜单栏 HUD
- **健康度评估**：综合 CPU 负载、内存压力、运行温度、磁盘余量与开机时长计算评分，显示 4 档兔兔状态图标。
- **菜单栏显示**：支持双行等宽显示 `CPU / GPU`、`RAM / TMP`、`上下行网速` 与 `实时功耗 / 峰值功耗`。
- **传感器读取**：通过 AppleSMC 读取 CPU/GPU 核心温度与风扇转速，支持 **自动 / 散热 / 全速** 模式切换。
- **外设电量显示**：识别并展示 AirPods (1-4 / Pro / Max)、Beats 耳机、妙控键盘、妙控鼠标、妙控板电量。
- **供电状态显示**：Mac 台式机默认显示 **AC 供电**，MacBook 显示内置 **电池**；在模块中心启用 UPS 电源管理并接入外置 UPS 后显示 **UPS 供电**。

### 2. 网络监控与测速诊断
- **流量排行与连接查看**：按应用或活跃 Socket 连接统计实时上下行带宽与累计流量，记录 24 小时分时流量趋势，支持定位进程路径。
- **网络测速**：调用 macOS 原生 `networkQuality` 测量上下行带宽、链路延迟 (RPM) 与抖动。

### 3. 系统清理、应用卸载与空间分析
- **智能清理**：扫描系统与用户缓存、Xcode 派生数据、日志、废纸篓与浏览器缓存，支持白名单保护与移至废纸篓/删除两种模式。
- **应用卸载**：扫描 `.app` 本体及 `~/Library` 下 12 类关联配置文件、容器与缓存目录并支持一并清理。
- **空间分析**：统计目录层级体积分布，列出大体积文件与目录路径。

### 4. 模块中心（按需启用）
首次安装后四个功能模块均处于未启用状态，未启用时不启动后台定时任务与硬件轮询；用户可在顶部导航栏 **「模块」**（`⌘6`）按需开启或停用：

- **PS Portal 串流画质增强（v1.0.1）**
  - 拦截局域网 UDP 9296 握手包并修改 LaunchSpec 目标码率，支持选择 `65 Mbps`、`100 Mbps`、`200 Mbps` 档位。
  - 支持扫描局域网设备并填入 PS5 与 PS Portal IP 地址，提供 120 秒握手等待实时倒计时，并依据真实数据包注入与质量回报输出生效状态，握手完成后自动恢复局域网直连。
- **Wi-Fi 低延迟**
  - 控制 macOS `awdl0` 接口开关，暂停后台隔空扫描与信道切换。
  - 停用模块或退出应用时自动恢复 `awdl0` 状态。
- **局域网活动设备**
  - 读取系统内核 ARP 缓存表，展示设备名称、IP 地址、物理 MAC 地址、厂商及物理网卡接口。
  - 列表按 IPv4 地址升序排序，支持点击复制 IP / MAC 地址、关键字过滤、单台设备改名及上传本地图片作为图标。
  - 支持导入路由器导出的 DHCP 静态分配备份文件（`.csv`），按 MAC 地址批量匹配设备名称。
- **UPS 电源管理**
  - 通过 IOKit USB-HID 接入 APC、Santak（山特）、CyberPower、Eaton 等 USB UPS 设备，同步显示电压、负载功耗、电池电量与预计续航。
  - 支持配置断电阈值（使用时间、剩余时间、剩余电量百分比），触发后可执行发送保存指令、安全睡眠或关机操作，并同步至系统设置。
  - 内置 **外置硬盘逃生舱**，以两列卡片展示已挂载外置磁盘及容量，支持断电延时自动卸载与单盘单独推出。

### 5. 系统诊断、权限管理与更新检查
- **系统运行诊断**：汇总硬件规格、传感器、权限、安全设置与运行状态，支持复制 Markdown 格式诊断报告。
- **权限与自启动管理**：集中检测与申请完全磁盘访问、桌面通知、Apple Events、SMC 风扇助手与开机自启动（默认开启，基于 `SMAppService`）权限。
- **版本更新检查**：对接 GitHub Releases 检查版本发布说明并支持下载安装。

---

## 下载与安装

1. 前往 [**GitHub Releases**](https://github.com/Rabbit-Spec/macOS-SysPulse/releases) 页面下载 `SysPulse-v0.1.10.dmg`。
2. 双击打开 DMG 镜像，将 **`SysPulse.app`** 拖入 **`Applications`（应用程序）** 文件夹。
3. 首次打开如果遇到 macOS 未签名开发者提示，可在终端运行以下命令放行：
   ```bash
   sudo xattr -rd com.apple.quarantine /Applications/SysPulse.app
   ```

---

## 从源码编译

SysPulse 使用 **Swift 6 + SwiftUI + AppKit + IOKit** 编写：

```bash
git clone https://github.com/Rabbit-Spec/macOS-SysPulse.git
cd macOS-SysPulse
./scripts/build_app.sh release
```

编译完成后，生成的应用包与 DMG 镜像位于 `../build/` 目录下。

---

## 作者与开源协议

- **作者**：[Rabbit-Spec](https://github.com/Rabbit-Spec)
- **Bilibili 频道**：[汤圆_Lyric](https://space.bilibili.com/7135720)
- **开源协议**：本项目基于 [MIT License](LICENSE) 开源。
- **功能参考**：「CleanMyMac」、「Mole」、「Cleer」、「Surge」
