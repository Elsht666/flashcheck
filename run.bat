@echo off
title USB Disk Inspector

echo ============================================================
echo    USB Disk Inspector - USB Flash Drive Test Tool
echo ============================================================
echo.

:: Check PowerShell
powershell -Command "exit" >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] PowerShell not found. Please use Windows 10 or later.
    pause
    exit /b 1
)

:: Get script directory
set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%USB-Disk-Inspector.ps1"

:: Support command line argument (e.g. run.bat D)
set "DRIVE=%~1"

if not exist "%PS1%" (
    echo [ERROR] USB-Disk-Inspector.ps1 not found.
    pause
    exit /b 1
)

:: List removable drives
echo Detecting removable drives...
echo.
powershell -NoProfile -Command "Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } | ForEach-Object { Write-Host ('  ' + $_.DriveLetter + ':  ' + $_.FileSystemLabel + ' (' + [math]::Round($_.Size/1GB,1) + 'GB, ' + $_.FileSystem + ')') }"

echo.
if "%DRIVE%"=="" (
    set /p DRIVE="Enter drive letter (e.g. D), or press Enter for auto-detect: "
)

if "%DRIVE%"=="" (
    echo.
    echo Auto-selecting first removable drive...
    for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } | Select-Object -First 1).DriveLetter"') do set "DRIVE=%%i"
)

if "%DRIVE%"=="" (
    echo [ERROR] No removable drive detected. Please insert a USB drive.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Testing %DRIVE%: drive... (takes about 30-60 seconds)
echo  Do NOT remove the USB drive during testing.
echo ============================================================
echo.

:: Generate timestamped report filename
for /f "delims=" %%i in ('powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd_HHmmss'"') do set "TIMESTAMP=%%i"
set "REPORT=%SCRIPT_DIR%report_%DRIVE%_%TIMESTAMP%.html"

:: Run PowerShell script and generate HTML report
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -DriveLetter %DRIVE% -HTML "%REPORT%"

echo.
echo ============================================================
echo  Test complete!
echo  Report saved to: %REPORT%
echo ============================================================
echo.

:: Auto-open report
if exist "%REPORT%" (
    echo Opening report...
    start "" "%REPORT%"
)

echo.
pause
