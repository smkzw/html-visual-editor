@echo off
chcp 65001 >nul
setlocal
set PORT=9100
set ROOT=%~dp0..
set APP=%ROOT%\src\app

echo.
echo   ==============================================
echo     HTML 可视化编辑器 · HTML Visual Editor
echo   ==============================================
echo.
echo   端口 Port: %PORT%
echo.

where python >nul 2>&1
if errorlevel 1 (
  where py >nul 2>&1
  if errorlevel 1 (
    echo   [错误] 未找到 Python，请安装 https://www.python.org/downloads/
    pause
    exit /b 1
  )
  set PY=py
) else (
  set PY=python
)

if not exist "%APP%\.venv\Scripts\python.exe" (
  echo   创建虚拟环境…
  %PY% -m venv "%APP%\.venv"
)
set VPY=%APP%\.venv\Scripts\python.exe

"%VPY%" -c "import fastapi, uvicorn, multipart" >nul 2>&1
if errorlevel 1 (
  echo   安装依赖…
  "%VPY%" -m pip install -q -r "%ROOT%\requirements.txt"
)

echo   启动服务器… 浏览器将自动打开。
echo   关闭本窗口即可停止。
echo   ------------------------------------------------

start "" cmd /c "timeout /t 2 >nul & start http://127.0.0.1:%PORT%"

cd /d "%APP%"
set EDITOR_PORT=%PORT%
"%VPY%" -m uvicorn server:app --host 127.0.0.1 --port %PORT% --no-server-header

pause
