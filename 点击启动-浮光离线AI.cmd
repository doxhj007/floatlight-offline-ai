@echo off
setlocal EnableExtensions DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PortableAI\Launch.ps1" -Engine Auto %*
set "AI_EXIT=%ERRORLEVEL%"
if "%AI_EXIT%"=="0" exit /b 0
echo.
echo PortableAI could not start. The error is shown above.
if "%~1"=="-SelfTest" exit /b %AI_EXIT%
pause
exit /b %AI_EXIT%
