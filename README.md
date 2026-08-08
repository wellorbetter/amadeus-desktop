# Amadeus — 牧濑红莉栖 AI 桌宠（Windows）

> 将 Makise Kurisu（牧濑红莉栖）的人格与 Live2D 形象带到你的桌面，提供**本地优先**的 AI 陪伴桌宠。可选接入 **TimeTrace** 使用数据，让她「感知」你在做什么——**但这不是硬依赖**：没有 TimeTrace 也能完整使用。

> 技术栈：Flutter (Windows) + WebView2 Live2D + DeepSeek / OpenAI 兼容 API + SQLite 记忆 + TimeTrace 数据桥（可选）

## 功能特性 / Features

- **本地 Live2D**：Cubism 2.1 模型，支持表情 / 动作 / 说话嘴型
- **AI 对话**：默认 DeepSeek，兼容任意 OpenAI 格式 API
- **记忆系统**：会话记忆 / 日记 / 长期记忆，SQLite 存储于 `%APPDATA%\timepet\mem.db`；可选注入 TimeTrace 观测语料
- **零 token 空闲休眠**：检测到系统睡眠 / 用户离开时自动暂停 AI，不浪费 token
- **主动触发**：空闲 / 时间 / 活动变化等多类触发器（内置 15 种），AI 会在合适的时机主动开口，带 token 上限保护
- **TimeTrace 数据桥（可选）**：通过 `assets/bridge/server.mjs`（Node 进程，**只读** `time.db`）暴露 `127.0.0.1:8788` 本地 API，让她知道你在用什么应用、今天活跃多久、昨天干了什么

## 快速开始 / Quick Start

1. 从 Release 下载 `timepet-windows.zip` 并解压
2. 设置环境变量 `DEEPSEEK_API_KEY=sk-...`（DeepSeek API Key）后启动 `timepet.exe`
3. 首次启动按「模型导入」章节导入一个 Live2D 模型
4. 可选：本机安装并运行 TimeTrace，桌宠会自动感知你的使用数据

## 构建 / Build

```bat
:: 依赖：Flutter stable + Visual Studio 2019 BuildTools + Windows SDK 10.0.19041 + Node.js
flutter pub get
flutter build windows --release
:: 产物：build\windows\x64\runner\[Release\]timepet.exe（VS generator 在 Release\ 下）
```

> 注意：首次构建可能因网络问题无法自动下载 `sqlite3` 原生库，需从 GitHub Releases 手动获取 `sqlite3.x64.windows.dll` 放入 hooks 目录（详见构建日志）。

> 产品名为 `timepet`：可执行文件为 `timepet.exe`，数据目录为 `%APPDATA%\timepet`。

## 模型导入 / Model Import

桌宠 = 程序源码 + 可选 `soul.md` 人格文件 + **自备** Live2D 模型。仓库**不包含任何模型资源**（`models/` 已加入 `.gitignore`）。

### 方式一：导入本地模型

使用 `tools/import_model.py`：

```bat
python tools\import_model.py import D:\models\shizuku                  :: 导入到 %APPDATA%\timepet\models\
python tools\import_model.py import D:\models\shizuku --set-config     :: 导入并设为当前模型
python tools\import_model.py list                                        :: 列出已安装模型
python tools\import_model.py switch shizuku                             :: 切换当前模型
python tools\import_model.py status                                      :: 查看模型/配置/soul/状态
python tools\import_model.py check D:\models\haru01                    :: 校验模型完整性
```

### 方式二：下载模型（需自行提供链接）

`tools/download_model.py` 只提供「下载 + 校验 + 导入」的管线，**不内置任何模型链接**——与上游 Amadeus 项目做法一致，避免代为分发第三方资源：

```bat
python tools\download_model.py download --url <模型zip链接>            :: 下载并导入到 %APPDATA%\timepet\models\
python tools\download_model.py download --url <链接> --set-config     :: 下载并设为当前模型
python tools\download_model.py list                                      :: 列出已安装模型
```

> 模型仅限个人本地学习研究，请勿商用 / 二次分发 / 重新打包发布（与仓库 `models/` 不入库策略一致）。

### 模型要求

支持 Cubism 2.1（`.model.json`）模型，放入 `models/` 或 `%APPDATA%\timepet\models/` 后即可在设置中切换。

## 人格 / Soul

- 将 `soul.md` 放到 `%APPDATA%\timepet\`（或 exe 同目录），用 Markdown 描述角色人格、说话风格、背景设定
- 可参考仓库提供的 [`soul.example.md`](soul.example.md) 模板
- `soul.md` 已被 `.gitignore` 忽略，不会入库

## 配置 / Configuration

配置文件为 `%APPDATA%\timepet\config.json`（修改后自动保存，约 60 秒防抖）：

- `appearance`：模型 / 大小 / 位置 / 透明度
- `proactive`：主动对话开关、频率、触发条件
- `sleep`：空闲休眠阈值、恢复策略
- `chat`：聊天参数
- `ai`：模型 / API 地址 / Key（也可用环境变量）
- `window`：置顶 / 无边框 / 透明度 / 开机自启

## 环境变量 / Environment Variables

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DEEPSEEK_API_KEY` | 无 | AI API Key（必填） |
| `TIMEPET_MODEL` | `deepseek-chat` | 可选 `deepseek-reasoner` |
| `TIMEPET_BASE_URL` | `https://api.deepseek.com/v1` | OpenAI 兼容 API 地址 |
| `TIMEPET_TT_API` | `http://127.0.0.1:8788` | TimeTrace 数据桥地址 |
| `TIMEPET_OPEN_SETTINGS` | 无 | 设为 `1` 时启动即打开设置窗口 |

## 是否依赖 TimeTrace？/ Is TimeTrace Required?

**不依赖。** TimeTrace 是可选的只读数据增强：

- 没有 TimeTrace 时，桌宠作为普通 AI 陪伴角色完整可用
- 有 TimeTrace 时，`assets/bridge/server.mjs`（Node 桥）以**只读**方式读取 `%APPDATA%\TimeTrace\time.db`
- 桥只读取 `usage_sessions` 表中的 `app_name` / `window_title` / `duration_secs` / `is_idle` / `started_at` / `ended_at` / `date` 字段，**不修改 TimeTrace 的任何数据**
- 所有数据仅在本机处理，不上传任何服务端

## TimeTrace 数据契约 / Data Contract

> 数据桥以**只读 JSON API** 形式暴露在 `127.0.0.1:8788`，由 `assets/bridge/server.mjs`（Node 进程）提供：

| 接口 | 说明 | 返回字段 |
| --- | --- | --- |
| `GET /api/context` | 当前上下文 | `foreground_app` `today.active_min` `today.idle_min` `today.switches` `today.top_app` `last_active_at` `now_hour` |
| `GET /api/history?days=N` | 历史数据 | `days[].date` `active_min` `idle_min` `top_apps[].{app,minutes}` `peak_hours[].{hour,minutes}` `diary.has_entry` |

> 若本机 TimeTrace 未运行（`TT 离线`），桌宠会自动降级为纯 AI 陪伴模式。

## 目录结构 / Layout

```
assets/bridge/        数据桥：Node 只读 time.db，暴露本地 API
assets/web/           前端：kurisu.html + live2d-widget 渲染层
assets/tray/          托盘图标
lib/                  Flutter 主程序：app / services / ui
tools/                模型导入/下载工具
windows/              Windows runner
```

## 许可证 / License

GPL-3.0。注意：本仓库**不附带任何 Live2D 模型资源**。

- 牧濑红莉栖为《命运石之门》版权方所属 IP
- 演示使用的 Live2D 模型为第三方同人二创资源，仅用于本地技术演示，模型文件不对外分发
- 使用者需自行获取合规的同人 Live2D 模型，仅限个人本地学习研究
- 禁止将模型用于商用、二次分发、重新打包发布
- 本项目与《命运石之门》官方、同人模型作者无任何关联
