###############################################################################
# jtagid_tk_server.tcl -- Tk side of the jtagid GUI.
#
# This file is NOT run by Vivado.  It runs inside a Tcl/Tk shell (wish) that the
# Vivado side (jtagid_tk_gui.tcl) starts, and it speaks Xilinx's official
# TclStore bridge ::tclapp::xilinx::tk_tunnel with Vivado:
#
#   * Vivado  -> this shell : rexec / rexec_wait   (Tk commands to build/update
#                                                 the window)
#   * this shell -> Vivado  : broadcast            (button clicks run driver
#                                                 procedures back in Vivado)
#
# argv: <tk_tunnel app dir> <port> <log file>
#
# We do not use the app's server/start.tcl because it insists on Tcl 8.5 and
# launches through "exec cmd /c start", which deadlocks on Windows pipes.
#
# ASCII only on purpose.
#
# 2026-10
###############################################################################

package require Tk

namespace eval ::jtagid::srv {
    variable logfile ""
    variable port    8001
}

set ::jtagid::srv::appdir  [lindex $argv 0]
set ::jtagid::srv::port    [lindex $argv 1]
set ::jtagid::srv::logfile [lindex $argv 2]

proc ::jtagid::srv::note {text} {
    variable logfile
    if {$logfile eq ""} { return }
    if {[catch {open $logfile a} fh]} { return }
    catch {
        fconfigure $fh -encoding utf-8
        puts $fh "[clock format [clock seconds] -format {%H:%M:%S}] $text"
        close $fh
    }
    return
}

::jtagid::srv::note "server starting: tcl [info patchlevel], tclversion [info tclversion]"
::jtagid::srv::note "app dir: $::jtagid::srv::appdir"

# the Tk commands sent by Vivado are evaluated in this interpreter, so the
# package's server side (accept_connection / socket_event / broadcast) must be
# available here
if {[catch {source [file join $::jtagid::srv::appdir communication.tcl]} err]} {
    ::jtagid::srv::note "FATAL: cannot source communication.tcl: $err"
    puts "jtagid server: cannot source communication.tcl: $err"
    exit 1
}
catch {source [file join $::jtagid::srv::appdir gui_helpers.tcl]}

# hide the default Tk root window (the GUI uses its own toplevel)
catch {wm withdraw .}
catch {wm title . "jtagid (Tk tunnel server)"}

# the app's own start_server also registers a stdin listener; a windowless
# launch has no usable stdin, so set up just the socket listener
if {[catch {
    set ::jtagid::srv::server [socket -server ::tclapp::xilinx::tk_tunnel::accept_connection \
                                   $::jtagid::srv::port]
} err]} {
    ::jtagid::srv::note "FATAL: cannot listen on port $::jtagid::srv::port: $err"
    puts "jtagid server: cannot listen on port $::jtagid::srv::port: $err"
    after 4000 { exit 1 }
    vwait ::jtagid::srv::never
}

::jtagid::srv::note "listening on 127.0.0.1:$::jtagid::srv::port"
puts "jtagid Tk tunnel server listening on port $::jtagid::srv::port"
flush stdout

# stay alive; the Tk event loop serves the socket and the window
vwait ::tclapp::xilinx::tk_tunnel::local_wait_on
::jtagid::srv::note "server event loop finished"
