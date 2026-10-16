@echo off
rem ===========================================================================
rem  jtagid_tk.cmd -- open the jtagid GUI (native Tk window) with its backend.
rem
rem  It starts the Vivado IDE, which, through Xilinx's official TclStore app
rem  ::tclapp::xilinx::tk_tunnel, launches a Tcl/Tk shell, ships the window code
rem  into it and then keeps serving button clicks from its idle event loop.
rem
rem  The Vivado IDE is what makes this work: in GUI mode Vivado keeps servicing
rem  Tcl events while its console sits at the prompt (measured on 2018.3), so the
rem  console is free and the backend stays resident.  "vivado -mode tcl" (the
rem  plain Tcl REPL) does NOT service events while it waits for input, so it is
rem  deliberately not used here.
rem
rem  Closing the Tk window only hides it; the backend keeps running.  Run
rem  "jtagid gui" again in the Vivado console to bring the window back, or
rem  "::jtagid::tkhost::stop" to stop the service.
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
echo [jtagid] opening the Vivado IDE (the Tk window appears once it is up).
echo [jtagid] that IDE is the backend: keep it open, and the console stays free.
echo [jtagid] log: %LOCALAPPDATA%\jtag_identify\tk_gui.log
start "" "%VIVADO%" -mode gui -nolog -nojournal -notrace -source "%HERE%jtagid_tk_gui.tcl"
exit /b 0
