# ChatGPT Desktop 更新器

这是一个只面向当前 Windows 用户的社区更新器。请先阅读
[English README](README.md)，或阅读详细的[中文运行指南](chatgpt-updater/README.md)。
这是非官方项目，与 OpenAI 或 Microsoft 没有隶属关系。

延迟安装与注册已在 Windows 11 x64 上实际验证。代码包含 x64 和 ARM64
路径，但本版本没有验证或保证 ARM64、Windows 10 硬件部署。真实桌面的鼠标和
焦点验收仍不完整。工具不会改变 ChatGPT
内置更新策略，也不会改变 Microsoft Store 的更新策略。

## 要求与边界

- 运行更新命令需要 Windows PowerShell 5.1。
- 使用系统自带的 `curl.exe`。curl 8.4 或更新版本适合并行连接；旧版本请使用
  单连接。
- 终端用户不需要 Python、Node.js、第三方 PowerShell 模块或其他运行时。PowerShell
  7 可用于离线测试，但不是更新器的运行要求。
- 工具只作用于当前用户，不创建自身的服务或托盘程序，不自动提权，也不删除现有的 ChatGPT
  包和用户数据。
- 只有用户在本工具确认窗口中明确点击安装按钮才授权部署。脚本、计划任务、键盘
  快捷键、关闭窗口、稍后和超时都不能代替这次授权。

如果已安装版本已经是最新或更高版本，默认操作会直接结束，不弹出安装确认，也不
执行包 GET。候选包在安装前会再次完整验证。
只有已经完整验证成功的包才能从受控缓存复用，安装前还会重复这次验证。

更新器自身的脚本只能从部署目录显式运行 `update-updater.cmd -Apply` 来替换。
它会校验固定的 GitHub Release 清单和 SHA-256，先暂存，等当前进程退出后再替换，
并保留回滚备份。后台任务不会调用该命令，也不会静默更新更新器自身。
0.2.0.2 增加可取消的激活事务、经过校验的恢复备份、共同更新锁和明确的恢复状态。
中断后使用 `-Status` 检查事务，使用 `-Rollback` 取消或恢复。Release 提供运行 ZIP、
源码 ZIP、清单及 SHA-256 校验值。

`0x80073D02` 表示 Windows 报告应用包资源正在使用。官方应用包可能包含开机自启动的
Windows 服务，因此没有打开应用窗口也可能遇到此错误，关闭窗口未必能解除占用。
更新器会请求 Windows 在包被使用时延迟注册：安装内容先暂存，等待 Windows 可以完成注册；
包内服务持续运行时可能需要重启 Windows 并登录。它不强制关闭应用、不停止或修改服务，也不提权。如果延迟注册仍被拒绝，
候选包会保留且不会报告为安装成功。

## 常用命令

从仓库根目录执行：

```powershell
cd chatgpt-updater
.\update-chatgpt.cmd
.\update-chatgpt.cmd -CheckOnly
.\update-chatgpt.cmd -DownloadOnly
```

`-CheckOnly` 只读检查；`-DownloadOnly` 下载并完整验证包但不安装。并行下载支持
1、4、8、16 个连接；默认 8 个，16 个是可选值；旧版本 curl 请使用
`-Connections 1`。

可选的当前用户后台任务必须显式启用：

```powershell
.\manage-background.cmd -Install -Connections 8
.\manage-background.cmd -Status
.\manage-background.cmd -Enable
.\manage-background.cmd -Disable
.\manage-background.cmd -Remove
```

任务在当地每天 12:00 和当前用户登录时触发。健康状态下远端 HEAD 最多每七天一次；
准备失败至少六小时后重试。点击稍后、关闭窗口、Escape 或无人响应超时后，候选至少
延后 24 小时；如果桌面锁定或确认窗口无法启动，则保留候选，等待后续触发。后台任务
会走受控缓存的完整验证路径，只准备并验证候选，不会绕过确认按钮安装。

## 离线验证

下面的命令需在仓库根目录执行。

测试运行器会解析项目和运行器中的全部 PowerShell 文件，然后在当前 Windows
PowerShell 5.1 或 PowerShell 7 的子进程中执行六个离线测试套件。测试对网络、AppX
和计划任务边界使用 mock，不访问真实地址、不注册任务、不部署 AppX，也不自动控制
桌面输入。

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Run-OfflineTests.ps1
pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Run-OfflineTests.ps1
```

项目许可证见 [LICENSE](LICENSE)，上游结构设计参考及完整许可声明见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
