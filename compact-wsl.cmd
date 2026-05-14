@echo off
setlocal enabledelayedexpansion
title Compact WSL / Docker VHDX

echo.
echo ==============================================================
echo  WSL / Docker VHDX compactor
echo ==============================================================
echo.
echo This script reclaims unused space inside WSL distros and the
echo Docker Desktop VHDX. It is non-destructive: files inside WSL
echo are NOT modified, only unallocated blocks are returned to C:.
echo.
echo PRECONDITION (otherwise compact only frees a few hundred MB):
echo   Inside each WSL distro, run:    sudo fstrim -v /
echo   then re-run this script.
echo.

REM Check admin
net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] This script must be run as Administrator.
    echo Right-click the .cmd file and choose "Run as administrator".
    pause
    exit /b 1
)

echo [OK] Running as Administrator.
echo.

REM Discover VHDX files via PowerShell.
echo Searching for VHDX files...
set "VHDX_LIST=%TEMP%\compact-wsl-list-%RANDOM%.txt"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$paths = @(); ^
    foreach ($root in @(\"$env:LOCALAPPDATA\wsl\", \"$env:LOCALAPPDATA\Packages\", \"$env:LOCALAPPDATA\Docker\wsl\")) { ^
        if (Test-Path -LiteralPath $root) { ^
            Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.vhdx' -ErrorAction SilentlyContinue ^| ^
                ForEach-Object { $paths += $_.FullName } ^
        } ^
    }; ^
    $paths ^| Sort-Object -Unique ^| Set-Content -LiteralPath '%VHDX_LIST%' -Encoding ASCII"

if not exist "%VHDX_LIST%" (
    echo [ERROR] Could not enumerate VHDX files.
    pause
    exit /b 1
)

echo === Sizes before ===
for /f "usebackq delims=" %%F in ("%VHDX_LIST%") do (
    if exist "%%F" (
        for %%A in ("%%F") do echo   %%~zA bytes  %%F
    )
)
echo.

echo === Stopping Docker Desktop processes ===
taskkill /F /IM "Docker Desktop.exe" /T >nul 2>&1
taskkill /F /IM "com.docker.backend.exe" /T >nul 2>&1
taskkill /F /IM "com.docker.build.exe" /T >nul 2>&1
taskkill /F /IM "com.docker.proxy.exe" /T >nul 2>&1
taskkill /F /IM "com.docker.cli.exe" /T >nul 2>&1
taskkill /F /IM "docker.exe" /T >nul 2>&1
taskkill /F /IM "vpnkit.exe" /T >nul 2>&1
timeout /t 2 /nobreak >nul

echo === Shutting down WSL ===
wsl --shutdown
timeout /t 3 /nobreak >nul

echo === Stopping services that hold VHDX handles ===
sc stop "com.docker.service" >nul 2>&1
sc stop "LxssManager" >nul 2>&1
sc stop "vmcompute" >nul 2>&1

echo Waiting for vmcompute to stop...
set /a WAIT=0
:wait_loop
timeout /t 1 /nobreak >nul
set /a WAIT+=1
sc query vmcompute 2>nul | findstr /C:"STOPPED" >nul
if errorlevel 1 (
    if !WAIT! LSS 15 goto wait_loop
)
echo Services stopped (waited !WAIT!s).
echo.

REM Build diskpart script
set "DPSCRIPT=%TEMP%\compact-wsl-%RANDOM%.txt"
> "%DPSCRIPT%" echo rem WSL/Docker VHDX compact
for /f "usebackq delims=" %%F in ("%VHDX_LIST%") do (
    if exist "%%F" (
        >> "%DPSCRIPT%" echo select vdisk file="%%F"
        >> "%DPSCRIPT%" echo attach vdisk readonly
        >> "%DPSCRIPT%" echo compact vdisk
        >> "%DPSCRIPT%" echo detach vdisk
    )
)
>> "%DPSCRIPT%" echo exit

echo === Compacting (about 30s per GB of VHDX) ===
diskpart /s "%DPSCRIPT%"
set "RC=%errorlevel%"
del "%DPSCRIPT%" >nul 2>&1

echo.
echo === Sizes after ===
for /f "usebackq delims=" %%F in ("%VHDX_LIST%") do (
    if exist "%%F" (
        for %%A in ("%%F") do echo   %%~zA bytes  %%F
    )
)
del "%VHDX_LIST%" >nul 2>&1
echo.

echo === Restarting vmcompute (WSL/Docker will start on demand) ===
sc start "vmcompute" >nul 2>&1

if "%RC%"=="0" (
    echo [OK] Compact finished. Reclaimed space is now free on C:.
) else (
    echo [WARN] Diskpart exit code %RC%.
    echo        If files were locked, reboot Windows and re-run this script
    echo        BEFORE opening Docker Desktop or any WSL terminal.
)

echo.
echo Tip: rerun collect-storage.ps1 to refresh the dashboard.
echo Press any key to close.
pause >nul
