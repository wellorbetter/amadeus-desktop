<p align="center">
  <img src="assets/docs/icon.png" width="96" alt="Amadeus">
</p>

<h1 align="center">Amadeus · 牧濑红莉栖 AI 桌宠</h1>

<p align="center">
  本地优先的 Windows AI 陪伴桌宠
  <br>
  <b>Flutter</b> + <b>WebView2 Live2D</b> · 可选接入 <b>TimeTrace</b> 使用数据，让她「感知」你在干什么
</p>

<p align="center">
  <a href="README_EN.md">English</a>
  ·
  <img src="https://img.shields.io/github/stars/wellorbetter/amadeus-desktop" alt="Stars">
  ·
  <img src="https://img.shields.io/github/license/wellorbetter/amadeus-desktop" alt="License">
</p>

---

## 功能特性

- **AI 陪伴对话** — 默认 DeepSeek，兼容任意 OpenAI 格式 API；`soul.md` 人格插件化，可自由换角色
- **感知你在干什么（可选）** — 通过本地数据桥只读 TimeTrace 数据，知道你在用什么应用、今天活跃多久、昨天干了什么
- **主动触发引擎** — 内置 15 种触发器（整点 / 深夜 / 久坐 / 切窗激增 / 空闲归来 / 专注提醒 / 记忆关心等），在合适的时机主动开口
- **零 token 空闲休眠** — 检测到系统睡眠 / 长时间离开时自动休眠、唤醒后恢复，不浪费 API 费用
- **长期记忆** — 会话记忆 / 日记 / 长期记忆，SQLite 存储于 `%APPDATA%\timepet\mem.db`
- **原生桌宠体验** — 无边框透明窗口、自由拖拽、托盘常驻、右键菜单；Live2D 表情 / 动作 / 说话嘴型

## 截图

| | |
| --- | --- |
| ![桌宠](assets/docs/screenshots/pet.png) | ![对话](assets/docs/screenshots/chat.png) |
| ![设置](assets/docs/screenshots/settings.png) | ![模型](assets/docs/screenshots/model.png) |

## 技术栈

| 模块 | 说明 |
| --- | --- |
| `lib/` | Flutter 主程序：窗口 / 托盘 / 触发引擎 / 记忆 / 设置 |
| `assets/web/` | kurisu.html + live2d-widget 渲染层（WebView2 驱动） |
| `assets/bridge/` | Node 数据桥：只读 `time.db`，暴露 `127.0.0.1:8788` 本地 API |
| `tools/` | 模型导入 / 下载工具（Python） |

## 快速开始

1. 从 [Releases](https://github.com/wellorbetter/amadeus-desktop/releases) 下载 `timepet-windows.zip` 并解压
2. 设置环境变量 `OPENAI_API_KEY=sk-...` 后启动 `timepet.exe`（OpenAI API；DeepSeek 可改用 `DEEPSEEK_API_KEY`）
3. 按下方「模型导入」导入一个 Live2D 模型：`python tools\download_model.py pick --list` 查看内置模型清单，`pick <名字> --set-config` 一键下载开箱即用（仓库本身不附带任何模型资源）
4. 可选：本机安装并运行 TimeTrace，桌宠自动感知你的使用数据

## 模型导入

桌宠 = 程序源码 + 可选 `soul.md` 人格文件 + **自备** Live2D 模型。仓库**不包含任何模型资源**（`models/` 已加入 `.gitignore`）。

### 方式一：导入本地模型

```bat
python tools\import_model.py import D:\models\shizuku                  :: 导入到 %APPDATA%\timepet\models\
python tools\import_model.py import D:\models\shizuku --set-config     :: 导入并设为当前模型
python tools\import_model.py list                                        :: 列出已安装模型
python tools\import_model.py switch shizuku                             :: 切换当前模型
python tools\import_model.py status                                      :: 查看模型/配置/soul/状态
```

### 方式二：下载模型（需自行提供链接）

```bat
python tools\download_model.py download --url <模型zip链接>            :: 下载并导入到 %APPDATA%\timepet\models\
python tools\download_model.py download --url <链接> --set-config     :: 下载并设为当前模型
```

### 方式三：内置模型仓库一键下载（开箱即用）

```bat
python tools\download_model.py pick --list                           :: 查看内置模型清单（名称/简介）
python tools\download_model.py pick shizuku                          :: 下载并导入小雫 Shizuku
python tools\download_model.py pick wed_16 --set-config              :: 下载、导入并设为当前模型（重启即用）
```

> 内置仓库来自开源免费模型合集 [hacxy/l2d-models](https://github.com/hacxy/l2d-models)（直链 CDN：`model.hacxy.cn`），仅收录当前引擎可显示的 Cubism 2.1 模型。模型版权归原作者所有，仅限个人本地学习研究，请勿商用 / 二次分发 / 重新打包发布（与仓库 `models/` 不入库策略一致）。支持 Cubism 2.1（`.model.json`）模型。

## 人格 / Soul

- 将 `soul.md` 放到 `%APPDATA%\timepet\`（或 exe 同目录），用 Markdown 描述角色人格、说话风格、背景设定
- 可参考仓库提供的 [`soul.example.md`](soul.example.md) 模板
- `soul.md` 已被 `.gitignore` 忽略，不会入库

## 构建

### 环境要求

- Windows 10/11
- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows)（stable 渠道）
- Visual Studio（含「使用 C++ 的桌面开发」工作负载）
- Node.js（数据桥运行时）

### 命令

```bash
# 1) Flutter 静态分析
flutter analyze

# 2) Windows Release 构建
flutter build windows --release
# 产物：build\windows\x64\runner\Release\timepet.exe
```

> 首次构建可能因网络问题无法自动下载 `sqlite3` 原生库，需从 GitHub Releases 手动获取 `sqlite3.x64.windows.dll` 放入 hooks 目录（详见构建日志）。

## 与 TimeTrace 的关系

**不依赖。** TimeTrace 是可选的只读数据增强：

- 没有 TimeTrace 时，桌宠作为普通 AI 陪伴角色完整可用
- 有 TimeTrace 时，`assets/bridge/server.mjs`（Node 桥）以**只读**方式读取 `%APPDATA%\TimeTrace\time.db`
- 数据桥以 JSON API 暴露在 `127.0.0.1:8788`：

| 接口 | 说明 | 返回字段 |
| --- | --- | --- |
| `GET /api/context` | 当前上下文 | `foreground_app` `today.active_min` `today.idle_min` `today.switches` `last_active_at` |
| `GET /api/history?days=N` | 历史数据 | `days[].date` `active_min` `idle_min` `top_apps[]` `peak_hours[]` `diary.has_entry` |

> 桥只读 `usage_sessions` 表中的字段，**不修改 TimeTrace 的任何数据**；若 TimeTrace 未运行，桌宠自动降级为纯 AI 陪伴模式。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `OPENAI_API_KEY` | 无 | OpenAI API Key |
| `DEEPSEEK_API_KEY` | 无 | DeepSeek API Key（使用 DeepSeek 地址时） |
| `TIMEPET_MODEL` | `gpt-5.6-luna` | 可指定 `gpt-5.6-sol`、`gpt-4.1-mini` 或 `deepseek-chat` |
| `TIMEPET_BASE_URL` | `https://api.openai.com/v1` | OpenAI 兼容 API 地址 |
| `TIMEPET_TT_API` | `http://127.0.0.1:8788` | TimeTrace 数据桥地址 |
| `TIMEPET_OPEN_SETTINGS` | 无 | 设为 `1` 时启动即打开设置窗口 |

## 隐私

所有数据仅在本机处理：记忆存于本地 SQLite，数据桥只读 TimeTrace，唯一的外部调用是你配置的 AI API。

## 开发过程

全程 vibe coding：前期用 DeepSeek V4 Flash + Pi 快速搭出原型，后期切换到 Codex 持续做性能与交互优化（与 TimeTrace 同一工作流）。

## License

[GPL-3.0](LICENSE)。注意：本仓库**不附带任何 Live2D 模型资源**。

- 牧濑红莉栖为《命运石之门》版权方所属 IP
- 演示使用的 Live2D 模型为第三方同人二创资源，仅用于本地技术演示，模型文件不对外分发
- 使用者需自行获取合规的同人 Live2D 模型，仅限个人本地学习研究
- 禁止将模型用于商用、二次分发、重新打包发布
- 本项目与《命运石之门》官方、同人模型作者无任何关联

`assets/web/vendor/live2d-widget` 基于 [stevenjoezhang/live2d-widget](https://github.com/stevenjoezhang/live2d-widget)（AGPL-3.0），详见 `assets/web/vendor/live2d-widget/LICENSE`。
