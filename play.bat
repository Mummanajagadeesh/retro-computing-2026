@echo off
py -3.12 host\play.py %*
if errorlevel 1 (
    echo.
    echo Press any key to exit...
    pause >nul
)
