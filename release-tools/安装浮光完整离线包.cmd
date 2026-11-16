@echo off
chcp 65001 >nul
setlocal
title 浮光完整离线 AI 安装器
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-FloatlightFull.ps1"
if errorlevel 1 (
  echo.
  echo 安装失败，请查看上面的提示。
  pause
  exit /b 1
)
echo.
echo 安装完成。按任意键关闭窗口。
pause >nul
