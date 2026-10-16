@echo off
rem ===========================================================================
rem  jtagid GUI launcher.
rem  Starts a dedicated Vivado Tcl process that serves the jtagid web GUI and
rem  then opens the interface in your browser.  No Tk and no external Tcl/Tk
rem  runtime is needed (Vivado's own Tcl has no Tk; every wish on a stock
rem  Windows box belongs to Git for Windows).
rem
rem  Options (set before running):
rem     set JTAGID_PORT=8760        preferred port (default 8760)
rem     set JTAGID_NO_BROWSER=1     do not open a browser
rem  ASCII only on purpose.
rem ===========================================================================
setlocal
set HERE=%~dp0
if "%JTAGID_PORT%"=="" set JTAGID_PORT=8760
set URLFILE=%LOCALAPPDATA%\jtag_identify\web_url.txt

rem ---- 1) find vivado.bat ------------------------------------------------
set VIVADO=
for /f "delims=" %%p in ('where vivado.bat 2^>nul') do if not defined VIVADO set VIVADO=%%p
if not defined VIVADO (
    for %%r in ("C:\Xilinx" "D:\Xilinx" "D:\xilinx" "E:\Xilinx") do (
        if not defined VIVADO for /f "delims=" %%p in ('dir /b /s "%%~r\*\Vivado\*\bin\vivado.bat" 2^>nul') do (
            if not defined VIVADO set VIVADO=%%p
        )
    )
)
if not defined VIVADO (
    echo [jtagid] vivado.bat not found.  Add Vivado's bin directory to PATH and retry.
    pause
    exit /b 1
)

rem ---- 2) start the backend ---------------------------------------------
if exist "%URLFILE%" del /q "%URLFILE%" >nul 2>nul
echo [jtagid] Vivado  : %VIVADO%
echo [jtagid] port    : %JTAGID_PORT%
echo [jtagid] starting the backend (a minimized window shows its log) ...
start "jtagid backend" /min cmd /c ""%VIVADO%" -mode tcl -nolog -nojournal -notrace -source "%HERE%jtagid_web_gui.tcl""

rem ---- 3) wait until the backend published its URL ----------------------
set /a tries=0
:wait
if exist "%URLFILE%" goto ready
set /a tries+=1
if %tries% GEQ 90 goto timeout
timeout /t 2 /nobreak >nul
goto wait

:ready
set URL=
for /f "usebackq delims=" %%u in ("%URLFILE%") do if not defined URL set URL=%%u
echo [jtagid] ready   : %URL%
if "%JTAGID_NO_BROWSER%"=="" start "" "%URL%"
exit /b 0

:timeout
echo [jtagid] the backend did not come up within 3 minutes.
echo          Look at the minimized "jtagid backend" window for the Vivado message.
pause
exit /b 1