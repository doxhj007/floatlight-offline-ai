@echo off
setlocal EnableExtensions DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PortableAI\tools\Download-Models.ps1" -QualityOnly
set "AI_EXIT=%ERRORLEVEL%"
echo.
if "%AI_EXIT%"=="0" echo SDXL 精细模型已准备好，10GB 以上显存会自动启用。
if not "%AI_EXIT%"=="0" echo 模型下载未完成；保留 .part 文件，下次会从断点继续。
pause
exit /b %AI_EXIT%
