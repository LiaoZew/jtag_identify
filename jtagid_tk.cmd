@echo off
rem ===========================================================================
rem  jtagid_tk.cmd -- open the jtagid GUI as a native Tk window.
rem
rem  It starts a Vivado Tcl process which, through Xilinx's official TclStore
rem  app ::tclapp::xilinx::tk_tunnel, launches a Tcl/Tk shell, ships the window
rem  code into it and then serves button clicks back to the driver.
rem  The Tk window is independent of this console; closing the window ends it.
rem
rem  Options (set before running):
rem     set JTAGID_TKSH=<path to wish.exe>   use another Tcl/Tk shell
rem     set JTAGID_TK_PORT=8001              tunnel port
rem  ASCII only.
rem ===========================================================================
setlocal
set HERE=%~dp0
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
    if not defined JTAGID_NO_PAUSE pause
    exit /b 1
)
echo [jtagid] Vivado: %VIVADO%
echo [jtagid] opening the Tk window (start it from a Vivado Tcl console too if you prefer)
echo [jtagid] log: %LOCALAPPDATA%\jtag_identify\tk_gui.log
"%VIVADO%" -mode tcl -nolog -nojournal -notrace -source "%HERE%jtagid_tk_gui.tcl"
exit /b %ERRORLEVEL%