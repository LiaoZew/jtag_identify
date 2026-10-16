@echo off
rem ===========================================================================
rem  jtagid_tk_wish.cmd -- start the Tk side of the jtagid GUI (Tk tunnel server).
rem  Called by jtagid_tk_gui.tcl with these environment variables:
rem     JTAGID_TK_WISH    Tcl/Tk shell (wish.exe)
rem     JTAGID_TK_SERVER  jtagid_tk_server.tcl
rem     JTAGID_TK_APPDIR  the tk_tunnel TclStore app directory
rem     JTAGID_TK_PORT    tunnel port
rem     JTAGID_TK_LOG     log file written by the Tcl side
rem     JTAGID_TK_STDOUT  where this shell's own output goes
rem  ASCII only.
rem ===========================================================================
"%JTAGID_TK_WISH%" "%JTAGID_TK_SERVER%" "%JTAGID_TK_APPDIR%" "%JTAGID_TK_PORT%" "%JTAGID_TK_LOG%" > "%JTAGID_TK_STDOUT%" 2>&1