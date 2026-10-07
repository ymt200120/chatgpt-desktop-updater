# ChatGPT Desktop updater

This repository contains a source-only community Beta updater for the
current Windows user. Read the [中文说明](README.zh-CN.md) or the detailed
[operational guide](chatgpt-updater/README.md).
It is unofficial and is not affiliated with OpenAI or Microsoft.

The current Beta was personally verified on Windows 11 x64. The code contains
x64 and ARM64 paths, but ARM64 and Windows 10 hardware deployment are not
verified or guaranteed in this version. Actual desktop mouse and focus
acceptance is incomplete, and real AppX deployment of these modules has not
been newly exercised. The updater does not change ChatGPT's built-in updater
policy or Microsoft Store update policy.

## Requirements and boundaries

- Windows PowerShell 5.1 is required for the operational commands.
- Use the inbox `curl.exe`. Curl 8.4 or newer is suitable for parallel
  connections; with an older version use one connection.
- End users do not need Python, Node.js, third-party PowerShell modules, or a
  separate runtime. PowerShell 7 is optional for the offline test runner.
- The tool is user-scoped. It does not install services, tray programs, or
  automatically elevate, and it does not remove the existing ChatGPT package
  or user data.
- Only an explicit click on the installation button inside this tool authorizes
  deployment. Scripts, scheduled tasks, keyboard shortcuts, closing the dialog,
  snoozing, and timeouts do not authorize installation.

When the installed version is already current or newer, the default operation
finishes without a prompt or package GET. A prepared candidate is fully
validated again before an installation attempt.
Validated packages are reused from the managed cache only after full validation
has succeeded, and installation repeats that validation.

## Commands

From the repository root:

```powershell
cd chatgpt-updater
.\update-chatgpt.cmd
.\update-chatgpt.cmd -CheckOnly
.\update-chatgpt.cmd -DownloadOnly
```

`-CheckOnly` performs a read-only check. `-DownloadOnly` downloads and fully
validates a package without installing it. Parallel downloads support
connections 1, 4, 8, and 16; the default is 8 and 16 is optional. Use
`-Connections 1` with older curl versions.

The optional current-user background task is explicit:

```powershell
.\manage-background.cmd -Install -Connections 8
.\manage-background.cmd -Status
.\manage-background.cmd -Enable
.\manage-background.cmd -Disable
.\manage-background.cmd -Remove
```

The task triggers daily at local 12:00 and at the current user's logon. Healthy
background state gates remote HEAD checks to at most once every seven days. A
preparation failure retries after at least six hours. A ready candidate is
snoozed for at least 24 hours after Later, closing the window, Escape, or a
no-response timeout. If the desktop is locked or the prompt cannot launch, the
ready candidate is retained for a later trigger. The task prepares and
validates a candidate, including the managed-cache validation path; it never
installs without the same explicit button click.

## Offline validation

Run these commands from the repository root.

The runner parses all project and runner PowerShell files, then starts exactly
the five offline suites in a child Windows PowerShell 5.1 or PowerShell 7
process. The suites mock network, AppX, and task boundaries; they do not access
live endpoints, register tasks, deploy AppX packages, or automate desktop input.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Run-OfflineTests.ps1
pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Run-OfflineTests.ps1
```

See [LICENSE](LICENSE) for this project's license and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the upstream structural
design reference and notice.
