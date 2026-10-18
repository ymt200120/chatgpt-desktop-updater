# ChatGPT Desktop updater

This repository contains a community updater for the
current Windows user. Read the [中文说明](README.zh-CN.md) or the detailed
[operational guide](chatgpt-updater/README.md).
It is unofficial and is not affiliated with OpenAI or Microsoft.

Deferred installation and registration have been verified on Windows 11 x64.
The code contains x64 and ARM64 paths, but ARM64 and Windows 10 hardware deployment are not
verified or guaranteed in this version. Actual desktop mouse and focus
acceptance is incomplete. The updater does not change ChatGPT's built-in updater
policy or Microsoft Store update policy.

## Requirements and boundaries

- Windows PowerShell 5.1 is required for the operational commands.
- Use the inbox `curl.exe`. Curl 8.4 or newer is suitable for parallel
  connections; with an older version use one connection.
- End users do not need Python, Node.js, third-party PowerShell modules, or a
  separate runtime. PowerShell 7 is optional for the offline test runner.
- The tool is user-scoped. It does not create its own services, tray programs, or
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

The updater's own scripts are replaced only by an explicit
`update-updater.cmd -Apply` from the deployed directory. It verifies a pinned
GitHub release manifest and SHA-256 hashes, stages the files, waits for the
current process to exit, and keeps a rollback backup. The background task never
calls that command and never silently updates the updater.
Version 0.2.0.2 adds cancellation-aware activation, verified recovery backups,
shared update locking, and explicit recovery status. Use `-Status` to inspect an
interrupted transaction and `-Rollback` to cancel or restore it. Release assets
include the updater runtime ZIP, source ZIP, manifest, and SHA-256 checksums.

`0x80073D02` means Windows reports package resources in use. The official app
can include an automatically started Windows service, so this can happen even
if no app window was opened. Closing the window may not resolve it. This
updater requests Windows deferred registration when the package is in use: the
update is staged until Windows can complete registration. A packaged service
can require a Windows restart and sign-in before registration completes. It does not force
applications to close, stop or reconfigure services, or elevate. If deferral is
still rejected, the candidate is retained and the operation is never reported
as a successful installation.

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
the six offline suites in a child Windows PowerShell 5.1 or PowerShell 7
process. The suites mock network, AppX, and task boundaries; they do not access
live endpoints, register tasks, deploy AppX packages, or automate desktop input.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Run-OfflineTests.ps1
pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Run-OfflineTests.ps1
```

See [LICENSE](LICENSE) for this project's license and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the upstream structural
design reference and notice.
