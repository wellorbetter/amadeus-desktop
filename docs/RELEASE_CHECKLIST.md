# Amadeus 桌面端发版检查

这份清单区分“CI 能证明”和“必须在真实设备上确认”的事项。未签名的 CI artifact 只用于内部验证，不应直接作为公开安装包发布。

## 自动检查（每个 PR）

- [ ] Rust：`cargo fmt --check`、`cargo test`、`cargo clippy -D warnings`
- [ ] Flutter：格式、静态分析与全部单元/Widget 测试
- [ ] 数据安全：API Key 不进入 `config.json`；旧明文值迁移后被清除
- [ ] 数据恢复：损坏的配置、记忆库和活动库先生成 `.corrupt-*` 备份，再创建可用新库
- [ ] Windows x64 release 构建并上传 artifact
- [ ] macOS release 构建并上传未签名 `.app` artifact
- [ ] Ubuntu release 构建、完整入口 smoke、隔离验收游览录屏并上传 artifact
- [ ] Windows 完整入口 smoke 与原生录屏通过；macOS 平台语义 UI 模拟视频生成
- [ ] macOS GUI 进程 smoke 与托管 runner 原生录屏作为尽力项单独报告，不冒充真机验收

## Windows 真机

- [ ] Windows 10 与 Windows 11 各完成一次首次启动、设置窗口、托盘与退出流程
- [ ] API Key 保存后重启仍可用，且 `config.json` 中不存在 Key
- [ ] 活动感知可以暂停、恢复、排除应用并按时间范围清除
- [ ] 长期记忆可编辑、删除，关闭的记忆类型不会被自动写入
- [ ] 主动互动显示正确触发原因；休眠期间不发起在线请求
- [ ] 多显示器、不同 DPI、任务栏位于不同边缘时窗口位置正确
- [ ] 安装包签名有效；SmartScreen 不显示未知发布者

## macOS 真机

- [ ] Apple Silicon 与 Intel（或 Intel CI/测试机）各完成一次核心流程
- [ ] Keychain 首次授权、保存、读取、清除均正常；重启后 Key 可用
- [ ] 活动感知权限说明与系统隐私设置一致，不请求屏幕录制权限
- [ ] 多桌面、全屏应用、外接显示器与不同缩放下窗口行为正确
- [ ] `codesign --verify --deep --strict Amadeus.app` 通过
- [ ] Developer ID 签名后提交 notarization，并完成 stapling
- [ ] 在一台未安装开发证书的干净 Mac 上通过 Gatekeeper 启动

## Ubuntu 真机

- [ ] 当前 Ubuntu LTS 在 X11 和 Wayland 会话中各完成一次首次启动、设置、托盘与退出流程
- [ ] Agent 对话、记忆、触发设置和本地数据库读写正常
- [ ] X11 能记录应用级活动与空闲片段，排除列表在 Rust 边界生效
- [ ] Wayland 明确显示传感器不可用且保持 fail-closed，不采集窗口标题、截图或输入内容
- [ ] 明确显示 Flutter 形象回退界面，不误称 Linux 已支持 Live2D WebView
- [ ] `.tar.gz`/包管理器产物携带 GTK、libsecret、X11/XScreenSaver 与 AppIndicator 运行依赖说明

## 发布与回滚

- [ ] 版本号、变更日志、隐私说明和第三方许可证同步更新
- [ ] 保留上一稳定版本安装包与校验值
- [ ] 升级安装不会覆盖模型、人格、记忆和活动数据
- [ ] 降级/新版本数据库不兼容时给出提示，不静默覆盖较新数据库
- [ ] 抽查 `.corrupt-*` 恢复路径，确认用户可以复制备份进行人工恢复
