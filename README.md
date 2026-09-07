# ForgeSweep

面向工程师的原生 macOS 清理与效率工具：菜单栏常驻 + 快捷面板 + 主窗口（硬盘清理 / 磁盘分析 / 应用卸载 / 开发环境 / 进程清理 / 端口清理 / 图片瘦身 / 剪贴板）。支持 12 种语言，默认跟随系统语言，可随时手动切换。

## 多语言

支持：简体中文、繁體中文、English、日本語、한국어、Deutsch、Français、Español、Português、Italiano、Русский、Türkçe。

- **自动识别**：默认 `auto`，按系统偏好语言（含区域变体归一，如 pt-BR → pt、zh-TW → 繁中）匹配；回到前台会重新解析。
- **手动切换**：主窗口标题栏的地球菜单，选择即持久化（`SMLanguage`）并即时刷新全部界面、状态栏文案与应用菜单。
- 语言表内置代码（`SimpleMole/L10n/`，覆盖 12 种语言），缺失键回退英文；格式化占位符保持一致。

## 定位

ForgeSweep 受到 [Mole](https://github.com/tw93/Mole) 启发。核心清理、磁盘分析、应用卸载和系统优化由 Swift `NativeCore` 直接实现；Mole 的库代码只为尚未原生迁移的特色 bridge 提供基础能力：

- **核心路径原生化**。`NativeCore` 使用 `FileManager`、`Bundle`、`NSWorkspace` 和 `Process` 完成候选扫描、大小分析、应用身份校验、废纸篓/永久删除和优化命令。每条待删除路径携带扫描时的 `device:inode:mtime`，执行前再次读取并比对；软链接、保护目录、白名单和运行中的应用默认跳过。`vendor/mole/` 仍随仓库提供给 AI、Xcode、项目雷达、图片和其他尚未原生迁移的桥接能力，上游版本记录在 `vendor/mole/UPSTREAM_COMMIT`，许可证见 `vendor/mole/LICENSE`。
- **UI 层为 Swift + SwiftUI 原生实现**。周期指标（CPU / 内存 / 网络 / 磁盘）走系统 API；进程排行按需读取一次 `/bin/ps`。耗时扫描和清理通过日志抽屉展示阶段状态与聚合结果，结构化清单在完成后一次性更新，避免逐行 UI 调度拖慢文件扫描。

## 功能面

| 页面 | 能力 | 引擎路径 |
| --- | --- | --- |
| 硬盘清理 | 快速扫描常用缓存，深度扫描补充更多应用目录；只展示 Safe 垃圾，归入缓存、卸载残留、废纸篓、开发者缓存、AI 缓存五个可折叠大类，支持分类/子项勾选。一键清理永久删除所选垃圾；运行中的应用缓存默认不勾选 | `NativeCore.scanCleanup/applyCleanup` + `CleanupScanWorker`；AI/Xcode 缓存共用原生统计 |
| 磁盘分析 | 用于定位大文件和目录占用，按大小只展示 Top 10；开发环境与 AI 占用单独分组，需要判断、应用和系统内容均留给用户检查，支持按目录继续下钻；选中的可再生项目内容由原生删除入口复验后移入废纸篓 | `NativeCore.scanAnalyze` + `NativeCore.applyCleanup` |
| 应用卸载 | 列出 `/Applications`、用户 Applications 和 Setapp 应用；按 Bundle ID 精确生成缓存、日志和需复核数据明细，应用本体与关联路径在串行队列中逐项复验身份后移入废纸篓 | `NativeCore.scanInstalledApps` + `NativeCore.uninstallPlan/applyUninstall` |
| 系统优化 | 刷新 DNS、Quick Look、LaunchServices，清理 30 天以前的保存状态，并只读检查 Spotlight 状态；每项独立显示 applied/unchanged/unavailable/failed | `NativeCore.runOptimize` |
| 状态监控 | 菜单栏和主窗口实时显示 CPU、内存、磁盘容量与读写、网络速率；可读取电池电量/健康/循环次数，快捷面板的内存榜也走原生进程快照 | `SystemMetrics.sample` + IOKit / Mach / sysctl / statfs / getifaddrs |
| 开发环境 | 识别 nvm 版本（默认/使用中锁定，可勾选清理旧版本）；fnm/Volta/asdf/pyenv/rbenv/rustup/Homebrew/JDK 版本及 Bun/Deno 等工具只读展示，版本移除交给各自管理器 | `app_env_scan.sh` + `app_apply.sh` |
| 进程/端口 | NSWorkspace 应用级管理、高级 PID 模式、lsof 监听端口 | 原生 + `app_runtime.sh` |
| 图片瘦身 | 图片清单、压缩（副本/替换）、重复图清理 | `app_{image,slim}_*.sh` |
| 白名单 | `~/.config/mole/whitelist` 的 GUI 维护，clean / purge / 全部桥接清理共用 | `load_mole_whitelist` / `is_path_whitelisted` |

卸载残留采用“证据优先”策略：应用仍在废纸篓时，用它的 Bundle ID 精确反查对应的用户缓存和日志；应用已经被手动删除且废纸篓也已清空时，不凭目录名猜测归属，而把可疑的大目录留给“磁盘分析”或后续深度审查。这样首屏可以保持快速，也不会把仍被其他应用使用的同名目录当成垃圾。

快速扫描先按预设路径发现缓存，完成风险分类、白名单过滤和路径去重后，再以最多 8 个工作线程统计实际磁盘占用。文件遍历预算为整体 45 秒、单目录 8 秒；遇到慢目录时保留已完成的结果，并提示尚未统计完的目录数。预算在遍历间检查，底层文件系统阻塞时可能超出预算，不承诺所有机器都在固定时间内完成。

深度扫描会补充应用容器和更多 Application Support 缓存，取消单目录时间限制，用户可随时取消。超时、无法读取或被取消的统计不会按完整容量展示，也不会写入完整结果缓存。页面可复用最近 5 分钟的完整快照，明确点击“快速扫描”或“深度扫描”会重新扫描。日志抽屉记录目录发现、容量统计耗时和未完成数量，便于实机比较。

扫描回归与吞吐测试：`bash script/test_cleanup_scan.sh`。它只创建独立测试目录，不启动 GUI、不扫描真实用户缓存；覆盖重叠目录、保护路径、深度补充、取消、部分结果、硬链接和大输出量进程读取。

### 自动目录清理

从主窗口顶部的“自动清理”进入规则管理。每个目录可选择“容量上限”（超限后按最旧优先清理至阈值）或“保留最近 X 天”；添加后的规则默认关闭，可先预览、手动确认清理，再显式开启。应用常驻期间每小时检查调度，实际扫描至少间隔六小时；执行失败会在下一次小时调度重试。

## 构建与 GitHub Release

需要 Xcode Command Line Tools（`swiftc`）。特色桥接所需的 Mole 源码已内置，无需另行安装或检出；核心清理、卸载、分析、优化和状态采集均由 Swift 实现：

```bash
bash script/build_and_run.sh
```

构建使用 `-O` 与 Swift 跨文件优化，签名前移除本地符号；本地默认只构建当前机器的
架构，输出到 `dist/arm64/ForgeSweep.app` 或 `dist/x86_64/ForgeSweep.app`，并自动选择钥匙串中的
`Apple Development` 身份。也可以显式指定身份：

```bash
SM_CODESIGN_IDENTITY="Apple Development: ..." bash script/build_and_run.sh
```

没有开发证书时，本机运行也可以显式使用 ad-hoc 签名：

```bash
SM_CODESIGN_IDENTITY=- SM_ALLOW_ADHOC=1 bash script/build_and_run.sh
```

稳定签名用于让 macOS 在重启和版本更新后仍能识别同一个 App；它不会绕过用户的隐私授权。
可用 `SM_BUILD_ARCHS=arm64`（或 `x86_64`）指定架构；`build.sh` 接受
`SM_BUILD_ARCHS="arm64 x86_64"`，会生成两个独立 App。没有开发证书时，
本机调试和 GitHub 开源 DMG 可以显式使用
`SM_CODESIGN_IDENTITY=- SM_ALLOW_ADHOC=1`；不要用 ad-hoc GUI 包验证权限持久性。

本项目采用开源方式通过 GitHub Release 分发，不要求维护者购买 Apple Developer 计划。
没有 Apple Development 证书时，可以直接生成本机 App 或 GitHub 用 DMG：

```bash
SM_CODESIGN_IDENTITY=- SM_ALLOW_ADHOC=1 bash script/build.sh
bash script/package_dmg.sh
```

`package_dmg.sh` 默认分别生成 `dist/ForgeSweep-arm64.dmg`（M 系列 Mac）和
`dist/ForgeSweep-x86_64.dmg`（Intel Mac）。每个包仅包含对应架构的 `ForgeSweep.app`
和 `/Applications` 快捷方式，使用 ad-hoc 签名。只生成一个包时设置
`SM_BUILD_ARCHS=arm64` 或 `SM_BUILD_ARCHS=x86_64`；自定义 `SM_DMG_PATH` 也只接受单架构。
用户首次从互联网下载后，如果 Finder 的“右键打开”仍被 Gatekeeper
拦截，可以在终端执行（将路径替换为实际安装位置）：

```bash
xattr -dr com.apple.quarantine /Applications/ForgeSweep.app
open /Applications/ForgeSweep.app
```

这只是绕过下载隔离检查，不会自动授予“完全磁盘访问”或“屏幕录制”等隐私权限。
ad-hoc 签名没有稳定的开发者身份，重编译或替换 App 后 macOS 可能要求重新授权；需要稳定
权限识别时再使用 Apple Development 签名。

如果要生成可被 Gatekeeper 直接接受的签名发布包，才需要使用 Developer ID 签名并完成 Apple 公证：

```bash
SM_CODESIGN_IDENTITY="Developer ID Application: ..." \
SM_NOTARY_PROFILE="forgesweep" \
bash script/release.sh
```

`SM_NOTARY_PROFILE` 是预先通过 `xcrun notarytool store-credentials` 保存的钥匙串配置名。
`release.sh` 默认校验并使用 `vendor/mole/UPSTREAM_COMMIT`。升级 Mole 时应整体更新
`vendor/mole/`、重新审计并运行完整测试；开发者仍可通过 `MOLE_SRC=/path/to/Mole`
临时验证新的上游检出。
`release.sh` 是可选的签名公证发布流程；默认分别公证两个架构，生成
`dist/ForgeSweep-arm64.zip` 和 `dist/ForgeSweep-x86_64.zip`（其中 App 已 stapled）。
也可用 `SM_BUILD_ARCHS` 只发布指定架构。GitHub 的开源发布不需要执行该流程，使用上面的 ad-hoc DMG 即可。

## App 图标

ImageGen 主图、菜单栏模板、生成提示词与 ICNS 分别位于 `SimpleMole/Support/AppIcon-1024.png`、`MenuBarIconTemplate.png`、`AppIcon.prompt.txt` 和 `AppIcon.icns`。更新主图后运行：

```bash
bash script/make_icon.sh
```

主窗口应用栏及 Dock / Finder App 封面使用彩色 App 图标；菜单栏状态项使用独立的单色 Template 图标，由 macOS 自动适配深浅色。

`dist/<架构>/ForgeSweep.app` 内嵌 Swift 主程序、`bridge/` 脚本，以及 `lib/core/`、
`lib/clean/project.sh` 和 `lib/clean/purge_shared.sh`。构建与桥接回归共用
`script/stage_bridge_resources.sh`，避免未被调用的 Mole 模块进入成品；
不再打包 Mole CLI、旧卸载入口或 Go 辅助程序。有 Apple Development
证书时使用稳定签名，没有证书时使用上面的显式 ad-hoc 选项。签名公证
发布流程会强制校验 Developer ID、TeamIdentifier、公证和 stapling；开源 GitHub Release
使用 `package_dmg.sh` 生成的 ad-hoc DMG。

## 目录

```
SimpleMole/   Swift 源码（AppKit 骨架 + SwiftUI 视图 + 服务层）
bridge/       app_*.sh 桥接脚本（删除边界复用引擎函数）
vendor/mole/  固定版本的 Mole 桥接支持源码与 GPLv3 许可证
script/       构建、运行、发布、测试与图标脚本
Support/      Info.plist 与应用图标
dist/         构建产物（gitignored）
```

## 验证

```bash
bash script/test.sh
```

测试覆盖脚本语法、Plist、受保护路径权限门禁、关键删除身份绑定、GC 退出码、图片计划互斥，并可执行 Swift 构建与签名检查。测试数据只在临时目录内创建。

## 安全约定

- 磁盘清理、全盘分析、卸载残留和图片全目录扫描统一经过权限门禁。未检测到“完全磁盘访问”时只打开 App 内权限中心，不启动扫描；授权后自动恢复用户刚才的操作。后台任务在未授权时安静跳过。
- Swift 只在实测授权成功后向扫描子进程传递 `FORGESWEEP_FULL_DISK_AUTHORIZED=1`。桥接脚本默认拒绝或跳过 Desktop、Documents、Downloads、Pictures、其他 App 的 Application Support / Containers 等受保护根，避免未来调用点遗漏门禁后触发原生文件夹弹窗。
- 完全磁盘访问和屏幕录制是 macOS 的两项独立权限：前者一次授权覆盖 ForgeSweep 的磁盘扫描，后者仅在使用截图功能时单独请求。开发者签名用于稳定识别 App，不会自动授予这两项权限。

- 所有原生删除计划同时携带确认时捕获的 `device:inode:mtime` 身份，并在最终落盘前复验；桥接删除仍使用 NUL 协议传递，文件名中的空格或换行不会改变边界。
- 卸载同时绑定应用绝对路径、Bundle ID、应用目录身份和 `Info.plist` 身份；预览与执行都重新扫描并要求精确匹配，拒绝同名应用或中途替换。
- 卸载队列为每个已确认任务独立保存应用身份与预览快照，实际卸载保持串行并与其他磁盘清理互斥。等待项可取消，执行中的任务不可通过单项取消中断；退出会停止队列，重启不会自动继续删除。
- 白名单在扫描与执行两侧同时生效（`is_path_whitelisted`），预览与清理结果一致。
- 手动破坏性操作一律先确认并写明容量估算。硬盘清理只接受 Safe 垃圾并明确提示“永久删除、不可恢复”；卸载、磁盘分析与自动目录规则仍默认使用废纸篓保护。
- 自动目录规则默认关闭，只处理用户选择目录的第一层子项；容量策略保护最近一小时仍有写入的内容，父规则也不会移走另一个已配置规则的目录。执行侧重新验证规则根目录、直接父子关系、扫描时文件身份和白名单，再移入废纸篓。
- 原生卸载只自动处理已确认身份的应用本体与用户目录数据；LaunchAgent、LaunchDaemon、PrivilegedHelper 和诊断报告等系统位置只展示为人工复核项，不自动提权删除。
- 系统清理选择清单使用 NUL 编码、SHA-256、私有权限和执行侧白名单复验，拒绝被替换、软链接或权限过宽的清单。
- 测试与联调使用 `MOLE_TEST_NO_AUTH=1` 避免真实授权弹窗。
