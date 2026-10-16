###############################################################################
# jtagid_tk_probe_idle.tcl -- measure whether THIS Vivado session keeps
#                             servicing Tcl events while the console is idle.
#
# Why it matters: the tk_tunnel GUI is non blocking only because Vivado
# delivers socket fileevents from its idle event loop.  This probe registers
# two "after" timers and a socket listener and then RETURNS; if the markers
# below appear afterwards, that session is fine for the GUI.
#
# Measured on Vivado 2018.3 IDE (GUI mode), 2026-10:
#
#     script end            -> console free
#     AFTER_2000            -> idle timers fire
#     LINE:PING1            -> socket fileevents fire
#
# and measured NOT to work in "vivado -mode tcl" (the plain Tcl REPL): the
# source returns but no marker ever appears, because that shell blocks on
# stdin without servicing events.  So the GUI uses the IDE (jtagid_tk.cmd
# starts -mode gui) and the front end warns if Vivado never answers.
#
# Usage (Vivado Tcl console):
#     source <this file>
# then, from another shell, connect to the port and send a line, e.g.
#     powershell: (New-Object Net.Sockets.TcpClient('127.0.0.1',8099)).GetStream()
# or simply watch the "after" timers in the log file.
#
# Environment: PROBE_PORT (default 8099), PROBE_LOG (default
# %LOCALAPPDATA%\jtag_identify\idle_probe.log)
#
# Temporary/diagnostic helper.  ASCII only.
###############################################################################

set ::probe_port 8099
set ::probe_log [file join $::env(LOCALAPPDATA) jtag_identify idle_probe.log]
if {[info exists ::env(PROBE_PORT)]} { set ::probe_port $::env(PROBE_PORT) }
if {[info exists ::env(PROBE_LOG)]}  { set ::probe_log  $::env(PROBE_LOG) }
catch {file mkdir [file dirname $::probe_log]}
catch {file delete $::probe_log}

proc probe {msg} {
    catch {
        set fh [open $::probe_log a]
        puts $fh "[clock format [clock seconds] -format {%H:%M:%S}] $msg"
        close $fh
    }
    puts "PROBE|$msg"
    flush stdout
}

proc probe_accept {s a p} {
    probe "ACCEPT from $a:$p"
    fconfigure $s -buffering line
    fileevent $s readable [list probe_read $s]
}

proc probe_read {s} {
    if {[eof $s]} { probe "EOF"; catch {close $s}; return }
    set line [gets $s]
    probe "LINE:[string trim $line]"
    catch {puts $s "ACK:[string trim $line]"}
    flush $s
}

probe "script start (mode=$::tcl_platform(platform))"
after 2000 {probe "AFTER_2000"}
after 6000 {probe "AFTER_6000"}
after 12000 {probe "AFTER_12000"}
if {[catch {set srv [socket -server probe_accept $::probe_port]} e]} {
    probe "socket error: $e"
} else {
    probe "listening $::probe_port: $srv"
}
probe "script end - console should be free now"
