<div align="center">

<h1>antigravity-codex-theme</h1>

<p><strong>Google Antigravity 的 Codex 昼夜主题、自定义字体、模型额度、中文界面与实时会话统计插件</strong></p>

<p>
  <a href="#快速安装">快速安装</a> ·
  <a href="#按需安装">按需安装</a> ·
  <a href="#功能详解">功能详解</a> ·
  <a href="#自定义与卸载">自定义与卸载</a> ·
  <a href="#致谢与协议">致谢与协议</a> ·
  <a href="#english-overview">English</a>
</p>

<p>
  不修改安装包，通过本地 CDP 实时注入，覆盖 36 个独立模块与 77 项单元测试。<br>
  支持 <code>--only</code> 按需安装、设置面板内一键检查更新与 <code>user/</code> 个人配置热重载。
</p>

<p>
  <a href="https://github.com/nkjDSLcvanv/antigravity-codex-theme/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/nkjDSLcvanv/antigravity-codex-theme/ci.yml?branch=main&label=CI&labelColor=363636&logo=githubactions&logoColor=white" alt="CI"></a>
  <img src="https://img.shields.io/static/v1?label=Antigravity&message=2.30.x%20~%202.35.2%2B&color=2B7FFF&labelColor=363636" alt="Antigravity 2.30.x ~ 2.35.2+">
  <img src="https://img.shields.io/static/v1?label=Node.js&message=%3E%3D%2022.13.0&color=339933&labelColor=363636&logo=nodedotjs&logoColor=white" alt="Node.js >= 22.13.0">
  <img src="https://img.shields.io/static/v1?label=platform&message=macOS%20%C2%B7%20Windows%20%C2%B7%20Linux&color=4B5563&labelColor=363636" alt="macOS · Windows · Linux">
  <img src="https://img.shields.io/static/v1?label=version&message=v1.4.1&color=2B7FFF&labelColor=363636" alt="version v1.4.1">
  <a href="LICENSE"><img src="https://img.shields.io/static/v1?label=license&message=MIT&color=10B981&labelColor=363636" alt="MIT License"></a>
</p>

<p>
  <a href="#命令行安装"><img src="https://img.shields.io/static/v1?label=CLI%20INSTALL&message=v1.4.1&color=2B7FFF&style=for-the-badge&labelColor=181818&logo=gnubash&logoColor=white" alt="CLI Install"></a>
  <a href="#ai-一键安装"><img src="https://img.shields.io/static/v1?label=AI%20ONE-CLICK&message=SKILL.md&color=0D9488&style=for-the-badge&labelColor=181818&logo=googlegemini&logoColor=white" alt="AI One-Click Install"></a>
  <a href="#按需安装"><img src="https://img.shields.io/static/v1?label=SELECTIVE%20INSTALL&message=--only&color=6366F1&style=for-the-badge&labelColor=181818&logo=codesandbox&logoColor=white" alt="Selective Install"></a>
</p>

</div>

https://github.com/user-attachments/assets/e27c7621-b605-4fdf-9bc3-4fc12da85484

![Codex 浅色与深色模式对比（含侧栏模型额度）](assets/light-dark-themes.png)

| 模块 | 核心能力 | 默认状态 |
| :--- | :--- | :--- |
| **Codex 昼夜主题与自定义字体** | 纯白 (`codex-pure-white`) / 炭灰 (`codex-dark`) 自动随外观切换；纯本地扫描本机字体，支持全局或 UI / 对话信息 / 代码与审查三区独立生效 | 默认开启 |
| **模型额度（面板 + 侧栏独立开关）** | Ink 昼夜双模式展示 `5h` / `7d` 剩余额度与具体重置时间，**统计面板底部与侧栏常驻显示可完全独立开关**，支持 **6 × 6** 样式组合、打开/聚焦/到期自动拉新、被动同步原生「查看用量」及点击手动刷新 | 默认开启 |
| **原生设置面板与一键更新** | 嵌入 **设置 → Codex 主题**，可视化管理模块开关、额度样式、字体下拉、模型档位、`sshHosts`、手动刷新与面板内直接升级 | 默认内置 |
| **会话状态与实时用量统计** | 底部四态圆点、一/二级用量面板与每轮悬浮详情卡；支持紧凑/详细动态换行、**分屏多对话独立统计**、旁路提问与可选 **SSH Remote** | 默认开启（SSH 可选） |
| **中文界面与原生右键菜单汉化** | `2,000+` 词条、额度动态提示及 **Electron 原生右键菜单**全链路汉化，`WeakMap` 原地替换并保护项目/分组/分支名防误翻 | 默认开启 |
| **输入框下一句预测** | 回复结束后在空输入框显示 Ghost Text，按 `Tab` / `→` 补全，内置 `agy models` 二级级联模型选择器 | **默认关闭**（按需开启） |

## 快速安装

> **前置要求**：**Node.js >= 22.13.0** 与 Google Antigravity（`2.30.x` ~ `2.35.2+`，已实机验证 **macOS / Windows / Linux**）。部署至 `~/.gemini/antigravity/codex-theme`，**不修改安装包**；若安装前应用已在无调试端口状态下运行，重启一次或执行 `node install.mjs relaunch` 即可生效。

### 命令行安装

```bash
git clone https://github.com/nkjDSLcvanv/antigravity-codex-theme.git
cd antigravity-codex-theme
node install.mjs install
node --disable-warning=ExperimentalWarning install.mjs doctor
```

### AI 一键安装

将下面这段提示词直接发给 Antigravity、Claude Code、Codex 或 Cursor：

> 请读取 `https://github.com/nkjDSLcvanv/antigravity-codex-theme.git`，使用 `git clone --depth=1 --filter=blob:none --sparse` 拉取核心文件（参考仓库内的 `SKILL.md`，跳过 `assets/` 和 `tests/`；如需只装部分功能可追加 `--only` 参数），运行 `node install.mjs install`、`node --disable-warning=ExperimentalWarning install.mjs doctor` 和 `verify` 完成安装并确认实时注入正常。

### 按需安装

通过 `--only` 从 `theme`、`i18n`、`metrics`、`fixes`（默认）及 `suggest`（可选）中按需组合：

```bash
# 示例：仅启用中文界面与实时统计，保留 Antigravity 原生配色
node install.mjs install --only i18n,metrics
```

<details>
<summary>展开：模块清单、精简拉取（sparse-checkout）与各平台 2.33.0+ 调试端口说明</summary>

| 模块 | 说明 |
| :--- | :--- |
| `theme` | Codex 浅色 (`codex-pure-white`) 与深色 (`codex-dark`) 昼夜主题与自定义字体 |
| `i18n` | 中文界面与 Electron 原生右键菜单本地化（`2,000+` 条词条，`WeakMap` 原地更新） |
| `metrics` | 实时会话四态指示、一/二级用量面板、每轮统计、分屏多对话支持与模型额度（含可选 SSH Remote） |
| `fixes` | 设置弹窗路由死锁修复与 `Cmd/Ctrl + -/=/0` 缩放快捷键 |
| `suggest` | 输入框下一句预测（Ghost Text + `Tab` / `→` 补全，默认关闭） |

**跳过 `assets/` 与 `tests/` 精简拉取（全平台通用）：**

```bash
git clone --depth=1 --filter=blob:none --sparse https://github.com/nkjDSLcvanv/antigravity-codex-theme.git
cd antigravity-codex-theme
git sparse-checkout set core user
node install.mjs install --only i18n,metrics
```

也可通过 `node install.mjs sparse-paths --only i18n` 输出最小单模块文件清单，配合 `git sparse-checkout set --no-cone ...` 与 `--minimal` 实现极简拉取。

**跨平台与 Antigravity `2.33.0+` 说明**：已覆盖 Antigravity `2.31.0` ~ `2.35.2`（macOS `LaunchAgent`、Windows `schtasks`/快捷方式、Linux `systemd --user`/`.desktop`）。`2.33.0+` 默认关闭 `DevToolsActivePort`，需 `--remote-debugging-port=0` 启动——macOS 默认单图标模式仅在冷启动前 `12s`（自动更新 `25s`）内接力补参，不中断运行中的会话；Windows / Linux 自动写入快捷方式或 `.desktop` 并兼容 `~/.antigravity/argv.json`。

</details>

<details>
<summary>展开：常用运维、更新、回滚与测试命令</summary>

| 命令 | 用途 |
| :--- | :--- |
| `node install.mjs install [--channel auto\|stable\|insiders] [--only <features>] [--minimal] [--with-launcher] [--sync-user]` | 部署插件并注册后台自启服务 |
| `node install.mjs update [--check] [--ref <branch\|tag>]` | 检查 GitHub 更新并直接升级（校验哈希、自动备份 `core.prev/`，保留 `user/`） |
| `node install.mjs relaunch [--channel auto\|stable\|insiders] [--force]` | 携带 `--remote-debugging-port=0` 重启 Antigravity 并校验注入（含 15s 活跃会话保护） |
| `node --disable-warning=ExperimentalWarning install.mjs doctor` | 检查 Node 版本、CDP 状态、`core/manifest.json` 哈希及页面挂载状态 |
| `node --disable-warning=ExperimentalWarning install.mjs verify [--safe-mode]` | 单次注入并校验；`--safe-mode` 跳过 `user/` 自定义脚本以便排障 |
| `node install.mjs rollback` / `uninstall` | 回滚至上一份 `core/` 备份 / 停止服务并还原英文界面与原生样式 |
| `npm run check` / `npm test` | 校验全部 `.mjs` 与拼接后的前端脚本语法，运行 77 项 `node:test` 单元测试 |

</details>

## 功能详解

### 1. 嵌入式设置面板与一键更新

在 Antigravity 原生设置弹窗（`内置浏览器` 下方）嵌入 **Codex 主题** 页签，日常切换无需手改 JSON：

- **统一可视化控制**：分组管理核心开关、6×6 侧栏额度样式、自定义字体下拉、输入预测二级级联模型选择器、`sshHosts` 主机标签与状态栏偏好，修改实时写入 `user/config.json` 并热重载；关闭汉化后设置页同步切回英文。
- **手动刷新与面板内直更新**：标题旁提供手动刷新（`↻`），底部 **版本与更新** 卡片支持检查 Release / `main` 差异并一键升级，自动备份 `core.prev/` 并保留 `user/`，无需重启应用。

![原生嵌入式 Codex 主题设置面板与二级模型选择器](assets/settings-panel.png)

### 2. 模型额度显示（侧栏与统计面板底部）

采用低噪声 **Ink 克制墨色体系**（常规炭墨 / `≤25%` 暖金 / `≤10%` 砖红，昼夜自动适配），实时读取当前账号各模型池的 `5h` 与 `7d` 剩余额度及具体重置时间（如 `2:38 后重置`、`周二 09:39`）：

- **6 × 6 自由组合**：当前模型池支持 `分段格`（默认）、`细线`、`双环`、`仪表`、`点阵`、`紧凑`；其他模型池支持 `标签细线`、`纯文字`（单行紧凑卡片）、`迷你分段`、`迷你环`、`两行`、`不显示`，统一双列 Bento 对齐。
- **即时同步与手动刷新**：打开应用先秒出缓存并立刻后台拉取最新额度；窗口重新聚焦（`window.focus` / `visibilitychange`）或倒计时归零后自动拉新，被动同步原生「查看用量」结果（零额外请求），亦支持**点击侧栏额度块**手动立即刷新。
- **双位置完全独立开关**：**模型额度**（统计面板底部额度行）与 **侧栏模型额度**（系统设置上方常驻显示）在设置面板中拆分为两个独立开关，可按需只开其一或全部开启，并按各分屏所选模型自动匹配对应池子。

![模型额度显示：6 种当前模型池、其他池自由组合与统计面板底部额度栏](assets/quota-display.png)

### 3. 自定义本机字体（全局 / 分区）

在 **设置 → Codex 主题 → 字体设置** 中无需手写 CSS，直接下拉选择本机字体（默认 `跟随 Codex 主题`）：

- **纯本地 SFNT 自动发现**：自动扫描 macOS / Windows / Linux 系统与用户目录已安装的 `.ttf` / `.otf` / `.ttc` 字体并区分常规体与等宽体，下拉列表实时呈现字体预览并自动贴合弹窗边界。
- **全局与三区独立生效**：支持 `全局` 模式（保留代码等宽）或 `分区` 模式分别定制 **UI 界面**、**对话信息**（含回复正文、气泡、文件引用与输入框）及 **代码与等宽**（含代码块、行内代码、侧边代码审查 diff、编辑器与等宽数值），自动豁免图标字体。

![自定义本机字体设置与三区独立作用域预览](assets/custom-fonts.png)

### 4. 实时会话状态与用量统计（含分屏多对话）

在输入框底部工具栏嵌入实时指标摘要与四态圆点，悬停预览一级面板，单击固定/逐级展开二级详情，并在每轮回复左下角附带单轮统计与悬浮详情卡：

- **动态宽度换行**：`compact`（默认）与 `detailed`（补充 `TTFT`、精确上下文与 `Out`）两种密度均按输入框宽度自动排版——宽屏居中嵌入工具栏、不占额外高度；窄侧栏、旁路提问或空间不足时自动换至底部居中虚线行（`24px` 迟滞防抖）。
- **分屏多对话并发监听**：拖入第二个对话开启分屏时，每个窗格独立挂载状态栏、并发监听所属 UUID 并独立刷新每轮统计与悬浮面板，换序或关闭分屏自动回收观察器，互不串台。

![状态栏四种自适应与分屏形态](assets/telemetry-layouts.png)

| 会话状态 | 圆点样式 | 触发条件 |
| :--- | :--- | :--- |
| 就绪 | **蓝色常亮** | 连接正常且空闲；主动取消生成后立即恢复 |
| 执行中 | **蓝色闪烁** | 模型流式输出、`/compact` 压缩或工具调用进行中 |
| 等待或重试 | **黄色脉冲** | 首字/单步等待 `>= 60s`（如跨模型 `/compact` 重算 KV 缓存）、模型自动重试或建连耗时 `3s ~ 11s` |
| 连接或执行异常 | **红色脉冲** | 网络离线、建连超时 `>= 12s`、API/步骤报错（不含主动取消）或后台心跳超时 `>= 90s` |

![会话状态：就绪、执行中、等待或重试、连接或执行异常](assets/led-status-states.png)

- **一/二级用量面板与上下文预警**：一级面板展示生成速度（含端到端均值）、上下文占比与剩余容量、缓存命中率及底部当前池额度；二级面板补充 TTFT、思考/正文拆分、本轮多步汇总与会话累计用量（上下文 `>= 75%` 黄色预警、`>= 90%` 红色临界，支持 `/compact` 过程与摘要提示）。

![一级概览、二级详情、上下文预警及每轮对话尾部统计](assets/telemetry-bento-panels.png)

![每轮对话尾部统计与悬浮详情卡](assets/turn-hover-card.png)

<details>
<summary>展开：SSH Remote 远端只读统计（可选，默认关闭）</summary>

在 **设置 → Codex 主题** 开启并添加主机别名（不扫描 `~/.ssh/config`，需远端具备 `python3` 且可无密码 SSH）。后台通过单条常驻 `ssh` 会话执行纯明文只读脚本 `~/.gemini/antigravity/codex-theme-remote/metrics_reader.py --serve`（无 `base64`/`exec`/`-c`，企业 HIDS 友好），以 `sqlite3` `mode=ro` 读取最新 WAL，**在远端剥离全部正文、Prompt 与 Checkpoint 文本**，仅回传脱敏数值元数据并在本地纯内存解析，不拷贝任何 `.db` 文件。

```json
{
  "modules": { "sshRemote": true },
  "sshHosts": ["node032"]
}
```

</details>

### 5. 输入框下一句预测（可选，默认关闭）

开启后在回复结束时的空输入框显示 Ghost Text，按 `Tab` / `→` 补全、输入或 `Esc` 隐藏；支持在设置面板通过 `agy models` 二级菜单切换模型与 `Thinking effort`（推荐 `Gemini 3.8 Flash Low`），关闭后立即停止后台进程、零额外消耗。

![输入框下一句预测 Ghost Text 与 Tab 补全](assets/prompt-suggestions.png)

### 6. 中文界面汉化、昼夜主题与实用修复

- **中文界面与原生右键菜单汉化**：内置 `2,000+` 条词条（覆盖 Antigravity `2.30.x` ~ `2.35.2+`、额度耗尽/AI 点数动态提示与 **Electron 原生右键多级菜单**，保留英文模型名与单字项目/分组/分支名防误翻），`WeakMap` 原地更新，支持 [user/i18n.override.json](user/i18n.override.json) 覆写或一键切回英文。
- **昼夜主题与实用修复**：纯白浅色（`#FFFFFF` / `#F9F9F9`）与中性炭灰深色（`#181818` / `#232323`）搭配同心圆角悬浮输入框；内置设置弹窗路由死锁修复、`Cmd/Ctrl + -/=/0` 缩放快捷键与 `2.33.0+` 单图标冷启动接力。

## 自定义与卸载

日常偏好推荐直接在 **设置 → Codex 主题** 中修改，实时写入 `~/.gemini/antigravity/codex-theme/user/config.json` 并热重载，升级时自动保留 `user/`。如需卸载，执行 `node install.mjs uninstall` 即可停止后台服务、清理自启项并恢复英文界面与原生样式。

<details>
<summary>展开：user/ 高级配置字段说明（config.json / custom.css / custom.js）</summary>

- [user/config.json](user/config.json)
  - `preset`：`"codex-pure-white"` 或 `"codex-dark"`
  - `themeVars`：覆盖 `--background`、`--sidebar`、`--primary`、`--ag-composer-*`、`--ag-dark-*` 等变量
  - `telemetryLayout`：`"compact"`（默认）或 `"detailed"`（均动态换行）
  - `telemetryCacheMode`：`"session"`（会话累计）或 `"step"`（单步）
  - `quotaStyle`：`"segments"`（默认）| `"bar"` | `"rings"` | `"gauge"` | `"dots"` | `"compact"`
  - `quotaOtherStyle`：`"lines"`（默认）| `"text"` | `"segments"` | `"rings"` | `"rows"` | `"hidden"`
  - `fonts`：`{ mode: "global" | "split", global, ui, chat, code }`，留空跟随 Codex 主题
  - `modules`：`theme`、`i18n`、`metrics`、`quota`、`quotaSidebar`、`sshRemote`、`promptSuggestions`、`deadlockHealer`、`zoomShortcuts`、`cdpAutoRelaunch`、`customCss`、`customJs`
  - `promptSuggestionModel`（默认 `"gemini-3.8-flash-low"`）、`sshHosts`（显式主机白名单）
- [user/i18n.override.json](user/i18n.override.json)：追加或覆盖翻译词条。
- [user/custom.css](user/custom.css) 与 [user/custom.js](user/custom.js)：注入自定义样式与脚本，热重载自动清理旧副作用。

</details>

<details>
<summary>展开：源码模块结构（core/ 36 模块与 77 项单元测试）与本地构建</summary>

| 定制方向 | 对应文件 |
| :--- | :--- |
| 昼夜主题配色与布局 | [core/styles/00-base.css](core/styles/00-base.css)、[10-light-codex.css](core/styles/10-light-codex.css)、[20-dark-codex.css](core/styles/20-dark-codex.css) |
| 原生设置面板与自更新 | [core/runtime/75-settings-ui.js](core/runtime/75-settings-ui.js)、[core/styles/45-settings-ui.css](core/styles/45-settings-ui.css)、[core/daemon/updater.mjs](core/daemon/updater.mjs) |
| 状态机与用量统计面板 | [core/runtime/40-status-machine.js](core/runtime/40-status-machine.js)、[core/runtime/50-telemetry-ui.js](core/runtime/50-telemetry-ui.js)、[core/daemon/telemetry-renderer.mjs](core/daemon/telemetry-renderer.mjs)、[core/styles/30-telemetry.css](core/styles/30-telemetry.css) |
| 模型额度显示（5h / 7d） | [core/runtime/55-quota-ui.js](core/runtime/55-quota-ui.js)、[core/styles/35-quota.css](core/styles/35-quota.css) |
| 输入预测与模型解析 | [core/daemon/prompt-suggest.mjs](core/daemon/prompt-suggest.mjs)、[core/runtime/70-prompt-suggestions.js](core/runtime/70-prompt-suggestions.js) |
| 词典与按需分组 | [core/i18n.json](core/i18n.json)、[core/runtime/60-i18n-engine.js](core/runtime/60-i18n-engine.js)、[core/installer/features.mjs](core/installer/features.mjs) |

修改 `core/` 后运行以下命令重建哈希清单、校验并本地部署：

```bash
node install.mjs build-manifest && npm run check && npm test && node install.mjs install
```

```text
antigravity-codex-theme/
├── assets/         # README 展示图
├── core/           # daemon/ · runtime/ · styles/ · installer/ · daemon.mjs · shared.mjs · i18n.json · manifest.json
├── tests/          # 77 项 node:test 单元测试
├── user/           # 个人配置与热重载目录
├── install.mjs     # 安装、更新、重启与运维 CLI
├── SKILL.md        # AI Agent 操作指南
└── LICENSE         # MIT License
```

</details>

<details>
<summary>展开：卸载行为与默认保留项</summary>

- **移除与还原**：停止后台进程，清理系统自启项（macOS `LaunchAgent`、Linux `systemd --user`、Windows 计划任务/启动脚本）及托管的 CDP 启动参数，恢复英文界面与原生样式。
- **默认保留**：保留 `~/.gemini/antigravity/codex-theme/user/`、`backups/`、`core.prev/` 及 `~/.antigravity/argv.json` 中的 `"remote-debugging-port"` 字段，如需彻底清除手动删除即可。

</details>

## 致谢与协议

感谢以下社区贡献者通过 Pull Request 完善本项目：

- [@isdou](https://github.com/isdou)（[PR #1](https://github.com/nkjDSLcvanv/antigravity-codex-theme/pull/1)）：输入框下一句预测（Ghost Text + `Tab` / `→` 补全）
- [@xiaoxiami-zyx](https://github.com/xiaoxiami-zyx)（[PR #3](https://github.com/nkjDSLcvanv/antigravity-codex-theme/pull/3)）：SSH Remote 远端只读统计元数据提取与纯内存解析
- [@chunbin1](https://github.com/chunbin1)（[PR #6](https://github.com/nkjDSLcvanv/antigravity-codex-theme/pull/6)）：冷启动目标退避重试机制，修复主窗口附着失败导致的心跳超时
- [@tz8899](https://github.com/tz8899)（[PR #11](https://github.com/nkjDSLcvanv/antigravity-codex-theme/pull/11)）：Electron 原生右键菜单全链路汉化、Antigravity `2.35.x` 词条扩充及 Windows 测试路径兼容修复

早期调研 Antigravity 的 CDP 注入、`WeakMap` 原地文本替换、SQLite 增量读取及 `2.33.0` 启动接力方案时参考了 [Anarcadia/chuanban-antigravity-theme-patch](https://github.com/Anarcadia/chuanban-antigravity-theme-patch)（MIT），在此一并致谢。基于 [MIT License](LICENSE) 开源，欢迎 Fork 与定制。

## English Overview

`antigravity-codex-theme` brings Codex light & dark themes, custom local fonts (with pure-Node SFNT auto-discovery for global or split UI / Chat / Code scopes), Ink 5h/7d model quota display (independent toggles for panel footer and sidebar block, 6×6 mix-and-match styles, instant live refresh on open/focus/reset, passive native-usage sync & click-to-refresh), Chinese UI + Electron native right-click context menu localization (`2,000+` in-place `WeakMap` entries with project/branch/group name guards), an embedded native **Settings → Codex Theme** panel with live self-updater, and multi-pane live session telemetry (dynamic width-adaptive wrapping for both `compact` and `detailed` modes, concurrent split-screen multi-conversation tracking, Side Question panes, opt-in read-only SSH Remote, and opt-in Ghost Text prompt suggestions) to Google Antigravity (`2.30.x` – `2.35.2+`) without touching the application bundle. Built as 36 modules with 77 `node:test` unit tests (Node.js `>= 22.13.0`, macOS / Windows / Linux, MIT License).
