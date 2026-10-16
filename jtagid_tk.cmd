@echo off
rem ===========================================================================
rem  jtagid_tk.cmd -- open the jtagid GUI (native Tk window) with its backend.
rem
rem  It starts the Vivado IDE, which, through Xilinx's official TclStore app
rem  ::tclapp::xilinx::tk_tunnel, launches a Tcl/Tk shell, ships the window code
rem  into it and then keeps serving button clicks from its idle event loop.
rem
rem  The Vivado IDE is what makes this work: in GUI mode Vivado keeps servicing
rem  Tcl events while its console sits at the prompt (measured on 2018.3 and
rem  2024.2), so the console is free and the backend stays resident.
rem  "vivado -mode tcl" (the plain Tcl REPL) does NOT service events while it
rem  waits for input, which is why this launcher opens the IDE.
rem
rem  THIS CONSOLE WINDOW IS THE BACKEND: keep it open.  Its text is Vivado's
rem  log, including "jtagid: console is free, service stays resident ...".
rem  Closing the Tk window only hides it - the backend keeps running.  Run
rem  "jtagid gui" again in Vivado's console to bring the window back, or
rem  "::jtagid::tkhost::stop" to stop the service.
rem
rem  Options (set before running):
rem     set JTAGID_VIVADO=<path to vivado.bat>  use a specific Vivado version
rem     set JTAGID_TKSH=<path to wish.exe>      use another Tcl/Tk shell
rem     set JTAGID_TK_PORT=8001                tunnel port
rem     set JTAGID_NO_PAUSE=1                  never wait for a keypress
rem  ASCII only.
rem ===========================================================================
setlocal
set HERE=%~dp0
set VIVADO=
if defined JTAGID_VIVADO if exist "%JTAGID_VIVADO%" set VIVADO=%JTAGID_VIVADO%
if not defined VIVADO for /f "delims=" %%p in ('where vivado.bat 2^>nul') do if not defined VIVADO set VIVADO=%%p
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
echo [jtagid] starting the Vivado IDE; the Tk window appears once it is up (~15 s)
echo [jtagid] keep this window open: it is the backend, and closing it stops the GUI
echo [jtagid] front end / backend log: %LOCALAPPDATA%\jtag_identify\tk_gui.log
echo.
"%VIVADO%" -mode gui -nolog -nojournal -notrace -source "%HERE%jtagid_tk_gui.tcl"
echo.
echo [jtagid] Vivado exited (%ERRORLEVEL%): the back end and the window are gone.
if not defined JTAGID_NO_PAUSE pause
exit /b %ERRORLEVEL%
