@echo off
rem ChatGPT Desktop updater launcher.
rem This wrapper only selects Windows PowerShell 5.1, forwards all arguments and
rem returns the real exit code. It contains no download/install logic and does
rem not change the machine ExecutionPolicy.
setlocal
set "UT_PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%UT_PWSH%" set "UT_PWSH=powershell.exe"
"%UT_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-chatgpt.ps1" %*
exit /b %ERRORLEVEL%
