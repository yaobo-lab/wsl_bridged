@echo off
setlocal

title WSL UDP Broadcast Test

echo Starting UDP broadcast test...
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Send-UdpBroadcast.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo Broadcast test failed with exit code %EXIT_CODE%.
) else (
    echo Broadcast test completed successfully.
)

echo.
pause
exit /b %EXIT_CODE%
