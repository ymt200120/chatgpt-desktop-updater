@echo off
rem ChatGPT Desktop updater self-update launcher.
rem This wrapper only selects Windows PowerShell 5.1, forwards all arguments and
rem returns the real exit code.  It contains no download or file-replacement logic.
setlocal
set "UT_PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%UT_PWSH%" set "UT_PWSH=powershell.exe"
"%UT_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0self-update.ps1" %*
exit /b %ERRORLEVEL%
