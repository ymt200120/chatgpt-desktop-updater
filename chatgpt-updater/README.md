# ChatGPT Desktop updater

这是一个只服务当前 Windows 用户的 ChatGPT Desktop MSIX 更新器 Beta。当前版本已在
Windows 11 x64 上实际验证；代码包含 x64 和 arm64 路径，但 ARM64 与 Windows 10
硬件部署没有验证或保证。真实桌面鼠标、焦点验收仍不完整，这些模块也没有新做真实
AppX 部署。工具不会改变 ChatGPT 内置更新策略或 Microsoft Store 更新策略。它只从
OpenAI 官方地址下载签名包，不使用 Microsoft Store、`winget msstore`、
第三方镜像。更新器自身更新必须显式运行 `update-updater.cmd -Apply`；它不会在
后台静默替换脚本。更新包和每个生产文件都经过 SHA-256 校验，先暂存，当前进程
退出后由独立 helper 替换，并保留可回滚备份。

- x64：`https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix`
- arm64：`https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix`

部署背景可参考 [官方 Windows deployment 文档](https://learn.chatgpt.com/docs/enterprise/windows-deployment)；其中的 all-users provisioning、卸载和管理员步骤不属于本工具。

固定 AppX 身份：

- Name：`OpenAI.Codex`
- PackageFamilyName：`OpenAI.Codex_2p2nqsd0c76g0`
- Manifest Publisher：`CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B`

## 要求与基本边界

- Beta 已在 Windows 11 x64 上验证；代码按原生系统架构判断，不按 PowerShell 进程位数判断。ARM64 与 Windows 10 硬件部署仍未验证，不构成支持保证。
- Windows PowerShell 5.1：`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`。
- 系统自带 `curl.exe`。默认 8 路，支持 1、4、8、16 路；curl 8.4 或更新版本适合并行 4/8/16 路，旧版本请使用 1 路。
- 不安装 Python、Node、第三方模块、服务、托盘程序或其他软件，不自动提权。
- 不建立开始菜单入口，不修改 PATH、PowerShell profile、注册表策略、旁加载策略、Store、Windows Update、防火墙或 UAC。
- 不卸载旧版本，不删除 `%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0`、`%LOCALAPPDATA%\OpenAI`、`%USERPROFILE%\.codex` 或用户数据。

## 常用命令

在本目录执行：

```bat
update-chatgpt.cmd
update-chatgpt.cmd -CheckOnly
update-chatgpt.cmd -DownloadOnly
update-chatgpt.cmd -OpenApp
```

`-CheckOnly` 只读检查；`-DownloadOnly` 下载、验证并保留完整包，不安装；`-OpenApp` 只在确认安装成功后启动 ChatGPT，不能和前两个选项组合。
`-Connections` 只能是 1、4、8、16，默认 8，例如：

```powershell
.\update-chatgpt.ps1 -Connections 1
.\update-chatgpt.ps1 -Connections 4
.\update-chatgpt.ps1 -Connections 8
.\update-chatgpt.ps1 -Connections 16
```

普通更新先检查、下载和完整验证，再启动独立的 Windows PowerShell 5.1 STA 确认窗口。只有用户本人点击 `立即安装` 才进入安装边界；脚本、任务、Enter、Escape、窗口 X、`稍后` 和超时都不能代替这次授权。

## 下载与验证流程

1. 查询当前用户的精确 AppX 身份、Family、四段版本和 `Status`；版本相等或更高时不下载、不降级。
2. 对匹配架构的官方 URL 执行 HEAD，读取最终响应的版本、长度和 ETag。必需的版本/长度缺失、重复、非法或 HTTP 错误直接失败；合法弱 ETag 或缺失 ETag 使用串行，非法 ETag 拒绝。
3. 并行传输前探测一个字节。合法分段响应必须是严格的 `206`，并且 `Content-Range`、长度、最终 URL 和 ETag 与 HEAD 快照一致；验证过的 `200` 探测只允许回退一次串行下载。
4. 同一范围的临时网络故障最多重试一次，从零重写该段；重定向、错误 `206`、错误 `Content-Range`/ETag、对象变化、`412` 等语义错误立即停止，不盲目重试。
5. 文件写入本工具自己的 `%LOCALAPPDATA%\ChatGPTUpdater\<run>`，先写 `.partial`，长度和验证通过后才改名。旧 partial、分段文件和不完整下载不会被续用。
6. 对同一个完整文件执行 Authenticode、Manifest、Name、Publisher、架构、版本、Windows 兼容性和依赖检查，并计算 SHA256 审计值。
7. 安装前再次获得 `update.lock`，重查当前版本和 HEAD，重新选择并完整验证缓存文件，持有同一文件的 read lease 到部署后；部署请求使用 Windows 的延迟注册（包被占用时不强关应用/服务），部署后再次核验 Family、版本和 `Status=Ok`。如果注册被合法延迟，返回独立的 Deferred 状态并保留候选，不把它报告为已安装。

## 完整包缓存

缓存索引只保存受控 key、版本和远端快照，不保存可执行路径、命令或授权。缓存路径由受控目录和严格 key 构造，拒绝 `..`、绝对路径跳转、reparse point 和链接逃逸。不会导入任意历史 DownloadOnly 目录，也不会信任状态文件中的任意 Path。

只复用已经完整验证并发布的 MSIX。相同快照的再次准备会复用同一个完整包，GET 计数为 0；不会复用 partial、分段或只满足长度的文件。缓存条目数量有界，最多保留 3 个受管理完整包，成功使用后只清理本工具明确知道的文件。状态原子替换、版本化并有大小限制；包与状态只写入本工具目录，重启或写入中断不会把半成品当作 Ready。

## 后台任务与确认窗口

任务不会自动创建。显式安装、查看和管理命令为：

```bat
manage-background.cmd -Install
manage-background.cmd -Status
manage-background.cmd -Enable
manage-background.cmd -Disable
manage-background.cmd -Remove
```

`-Install` 只把明确列出的生产模块复制到 `%LOCALAPPDATA%\Programs\ChatGPTUpdater`，并创建当前用户 SID 的 `ChatGPTUpdater-Background` 任务。当前清单为 14 个文件，包含 `VERSION`、`self-update.ps1`、`self-update-helper.ps1` 和 `update-updater.cmd`。任务使用 Interactive/Limited，不保存密码，要求用户已登录，不建立服务、常驻进程、托盘或开始菜单入口。首次安装和 `-Enable` 会立即启动一次准备流程；它不会直接安装 AppX。

任务在当地每天 12:00 和该 SID 登录时触发，`StartWhenAvailable`、`MultipleInstances=IgnoreNew`，允许电池启动且不因切换电池停止，不唤醒机器，任务执行时间限制为 `PT0S`。任务只覆盖带有本工具 marker、当前 SID、精确 PowerShell 路径、参数和工作目录的自有任务；名称冲突、查询权限错误或其他归属不明情况会停止，不会提权或强行覆盖。

健康状态下远端 HEAD 最多每 7 天一次；首次启用可立即检查。HEAD 成功和准备成功分开记录，准备失败按至少 6 小时重试，不把一次 HEAD 成功错误地延长为一周。Ready 候选只在提醒到期且桌面已解锁时弹窗；锁屏、不可见桌面或启动失败时保留 Ready，后续触发再尝试。状态、日志和候选有界、带版本并使用独立的状态、提示、日志锁；损坏状态会隔离后从空状态恢复，不触碰缓存。

确认窗口是普通 Windows Forms 对话框：显示当前实际版本和候选版本，安装按钮是唯一授权入口。窗口不置顶、不调用 Activate/SetForegroundWindow，并请求 `ShowWithoutActivation`；这不能保证所有桌面策略下都不改变焦点。Enter 被显式拦截，未设置默认 AcceptButton，用户主动点击仍可正常操作。等待最多 10 分钟，无人回应、`稍后`、X、Escape 都保存至少 24 小时 snooze、保留包且绝不安装。安装在独立 runspace 中进行，窗口保持响应；安装进度窗口关闭只隐藏窗口，不终止部署。安装请求 `DeferRegistrationWhenPackagesAreInUse`；如果 ChatGPT 或其后台服务占用应用包，更新会暂存并在下次启动时注册，不强制关闭应用或停止服务。`0x80073D02` 仍表示资源占用；完整错误保存在 `background.log`。更新未完成时保留候选，不强杀进程、不停止服务、不重新下载。

测试 UI 使用隔离 TEMP 状态和 `TEST/MOCK` 标题，永远不会触及生产状态或 AppX：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\confirm-install.ps1 -Demo -DemoResult Success
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\confirm-install.ps1 -Demo -DemoResult D02
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\confirm-install.ps1 -Demo -DemoResult Changed
```

需要快速无人值守演示时加 `-TimeoutSeconds 5`。真实安装永远由用户本人点击 `立即安装`，不会为了验收自动点击或伪造授权。

## 更新器自身更新

在部署目录 `%LOCALAPPDATA%\Programs\ChatGPTUpdater` 中显式运行：

```bat
update-updater.cmd -CheckOnly
update-updater.cmd -Status
update-updater.cmd -Apply
update-updater.cmd -Rollback
```

- `-CheckOnly` 只读取固定 GitHub Release 的 `updater-release.json` 并比较版本，不下载生产 ZIP、不替换文件。
- `-Apply` 是替换更新器自身代码的唯一显式授权。它下载 ZIP，校验 ZIP 和每个文件的 SHA-256，检查 `VERSION`、文件清单和 PowerShell 语法，然后暂存。后台任务会暂停；当前进程退出后，独立的 `self-update-helper.ps1` 才替换文件并重新启用任务。
- 替换前会把旧文件备份到 `%LOCALAPPDATA%\ChatGPTUpdater\updater\backups\`；`-Rollback` 可恢复最近一次备份。
- 替换期间会在部署目录写入 `self-update.pending.json`；直接运行 `update-chatgpt.ps1` 会以退出码 `12` 拒绝并发启动。
- 后台任务只会准备 ChatGPT 更新，不会调用 `-Apply`，不会静默更新自身。

信任边界：清单 URL 固定在 `https://github.com/ymt200120/chatgpt-desktop-updater-public`，ZIP 和文件哈希也来自该 Release。当前版本没有额外的发布签名密钥，因此信任根是该 GitHub 仓库账号、HTTPS 和用户显式 `-Apply`；仓库账号或本机被控制不在防护范围内。发布新版本可使用 `scripts\New-UpdaterRelease.ps1` 生成 `updater-release.json` 和生产 ZIP。

自更新退出码：`0` 成功/已是最新/仅检查；`1` 未预期错误；`2` 参数冲突；`3` 环境或非部署目录；`4` 网络；`5` 清单；`6` ZIP/文件一致性；`7` 安全校验；`8` 正在运行、已有 pending 或锁冲突。

## 关机、恢复与限制

- 检查或下载中关机：不会执行 Add-AppxPackage；partial 下次不续用，会重新准备。
- 完整包准备后关机：完整包和 Ready 状态保留；下次匹配时不重新 GET，安装前仍完整复核。
- 安装中突然断电：不能承诺绝对安全，结果依赖 Windows AppX 部署恢复；下次查询 Family、版本和 Status，异常只报告，不自动卸载、清数据或强制修复。
- 不阻止关机、不修改电源设置，也不假设 `finally` 一定执行；禁用任务不会终止已经启动的部署生命周期。

HTTP 版本、长度和 ETag 只是传输一致性信号，不是信任根。官方 HTTPS、有效 Authenticode、固定身份、Manifest/兼容性/依赖检查和部署后核验共同构成边界；即使 CDN 遵守 ETag，大小和版本也不能证明每一种同大小替换都不可能发生，也不能防御已控制当前用户或 Windows 信任存储的攻击者。

## 退出码

`0` 成功、无需更新、成功验证或成功安装；`1` 未预期错误；`2` 参数冲突；`3` 环境；`4` 网络；`5` 元数据；`6` 下载/一致性；`7` 安全/身份/Manifest；`8` Windows 兼容性；`9` 依赖；`10` 部署；`11` 安装后核验；`12` 锁冲突；`13` 已安装包状态；`14` 已暂存但注册被延迟（等待下次启动，不代表已安装）。

常见部署错误：`0x80073D02` 表示应用包资源被占用，后台服务也可能造成占用，不表示用户一定打开过窗口；`0x80073D06` 表示已有更高版本；`0x80073D28` 表示需要管理员权限。官方应用包可能包含自动启动的系统服务，因此仅退出窗口或重启电脑未必能解除占用。更新器会先请求延迟注册；如果 Windows 仍拒绝，候选包会保留，重启 Windows 后可再次运行更新器。工具不会通过强杀、停止服务、提权或 provisioning 绕过这些错误。

## 离线测试与真实验收

默认测试不注册任务、不安装 AppX、不访问真实网络；ZIP/XML、范围算法、拼接、状态恢复和文件锁使用真实隔离 fixture，OS、网络、签名、AppX 和任务 cmdlet 使用边界 mock。PS5 与 PS7 都应执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Updater.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Background.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Cache.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SegmentedDownload.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SelfUpdate.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-UIEvents.ps1
```

真实网络验收单独运行，不属于默认离线测试：`tests\Invoke-LiveRangeAcceptance.ps1` 每个 8/16 路批次只取官方对象前 64 KiB，验证真实响应和拼接；`tests\Invoke-LiveCacheAcceptance.ps1` 才会准备一次真实完整 MSIX，并验证匹配准备的第二次 GET 为 0。复验已有缓存加 `-RequireExistingCache`，可禁止所有包传输。两者都禁止部署，首次完整包验收仍可能消耗约 900 MB 流量。

## Attribution

部分结构思路（原生架构判断、跨验证和部署持有 read lease、部署前重查以及按 HRESULT 提示部署错误）参考 [pavelbe/codex-windows-store-helper](https://github.com/pavelbe/codex-windows-store-helper) 的 `scripts/Install-CodexDirect.ps1`，commit `bea80fb446e7b7f76f59dab33e6450519127f38d`，MIT License，Copyright (c) 2026 Pavel。本项目是独立实现，并始终在下载前比较版本。
