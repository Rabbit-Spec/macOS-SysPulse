<div align="center">
  <img src="Resources/AppIcon-Light-1024.png" width="110" height="110" alt="SysPulse Icon" />
  <h1>SysPulse</h1>
  <p><strong>轻于颜表，深于内在 · 让系统状态如玻璃般清透，让运行空间如初次开箱</strong></p>
  <p>专为 macOS (Apple Silicon) 打造的原生液态玻璃系统管家与 UPS 断电守护中心</p>

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

## ✨ 核心特性

### 1. 🪟 状态总览与菜单栏灵动萌兔 HUD
- **健康度动态评估**：实时综合 CPU 负载、内存压力、运行温度、磁盘余量与开机时长，呈现 4 档水彩健康萌兔形象。
- **菜单栏 4 档变速萌兔**：菜单栏小兔子随 CPU 占用率自动切换帧率，支持双行等宽显示 `CPU / GPU`、`RAM / TMP`、`上下行网速`、`实时功耗 / 峰值功耗` 或 `UPS 状态`。
- **AppleSMC 传感器直读**：无需后台常驻守护进程即可毫秒级读取 CPU/GPU 真实核心温度与双风扇实时转速，支持 **静音 / 自动 / 极速排风** 模式切换。
- **全生态外设电量矩阵**：原生矢量图标精准识别 AirPods (1-4 / Pro / Max)、Beats 全系耳机、妙控键盘、妙控鼠标、妙控板、Apple Watch 与 iPhone/iPad。

### 2. 🌐 网络监控与硬件级链路诊断
- **实时上下行流量排行**：按应用或活跃 Socket 连接追踪实时带宽去向，支持一键复制进程路径或在访达中定位。
- **内置硬件级测速**：一键调用 macOS 原生 `networkQuality` 引擎测量上下行峰值带宽、链路延迟 (RPM) 与抖动。
- **Wi-Fi 低延迟优化**：支持一键挂起 `awdl0` 隔空投送漫游扫描接口，消除无线游戏或串流时的周期性跳 Ping。

### 3. 🧹 三合一净空引擎（智能清理 · 应用卸载 · 空间分析）
- **智能清理**：深度扫描系统与用户缓存、Xcode 派生数据、日志、废纸篓与浏览器缓存，支持安全白名单保护与废纸篓/永久删除双模式。
- **应用强力卸载**：并发计算 `.app` 本体与散落在 `~/Library` 12 个子目录中的关联偏好设置、容器与缓存残留，卸载更彻底。
- **磁盘空间透视**：可视化文件夹体积占比，快速揪出超大文件与深层占用。

### 4. ⚡️ 专业级 UPS 断电守护与外置磁盘逃生舱
- **IOKit HID 毫秒级监听**：完美适配 APC、Santak（山特）、CyberPower、Eaton 等主流 USB UPS。
- **断电自动保存与关机**：市电中断或电池低于阈值时自动向正在运行的创作软件发送 `⌘S` 保存指令，并安全执行休眠或关机。
- **外置磁盘安全逃生舱**：断电后按设定延时自动卸载雷电阵列与外置硬盘，防止断电损坏文件系统。

### 5. 🩺 系统运行诊断 (SysPulse Doctor) 与 OTA 在线更新
- **一键生成诊断报告**：全面汇总硬件环境、系统传感器、权限状态、安全配置与待处理项，支持一键复制 Markdown 诊断报告。
- **GitHub Releases 自动更新**：内置 OTA 更新检查器，当仓库发布新 Tag / Release 时可在应用内直接查看更新日志并一键下载覆盖安装。

---

## 📦 下载与安装

1. 前往 [**GitHub Releases**](https://github.com/Rabbit-Spec/macOS-SysPulse/releases) 页面下载最新的 `SysPulse-v0.1.2.dmg`。
2. 双击打开 DMG 镜像，将 **`SysPulse.app`** 拖入 **`Applications`（应用程序）** 文件夹。
3. 首次打开如果遇到 macOS 未签名开发者提示，可在终端运行以下命令放行：
   ```bash
   sudo xattr -rd com.apple.quarantine /Applications/SysPulse.app
   ```

---

## 🛠️ 从源码编译

SysPulse 采用 100% 纯原生 **Swift 6 + SwiftUI + AppKit + IOKit** 构建，零第三方臃肿依赖：

```bash
git clone https://github.com/Rabbit-Spec/macOS-SysPulse.git
cd macOS-SysPulse
./Scripts/build_app.sh release
```

编译完成后，生成的独立应用包与 DMG 镜像位于 `../build/` 目录下。

---

## 👨‍💻 作者与致谢

- **作者**：[Rabbit-Spec](https://github.com/Rabbit-Spec)
- **Bilibili 频道**：[汤圆_Lyric](https://space.bilibili.com/7135720)
- **开源协议**：本项目基于 [MIT License](LICENSE) 开源，纯净无广告、零隐私遥测。
