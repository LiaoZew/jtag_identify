###############################################################################
# jtagid_tk_test_resident.tcl -- proof that the back end outlives the window.
#
# The split is deliberate: the Tk window is a disposable front end, the Vivado
# session is the back end that owns the cable.  This test drives that path:
#
#   * "Close" on the window  -> wm withdraw: the Tk PROCESS and the back end
#                               both stay (closing is not quitting)
#   * jtagid gui (::jtagid::tkhost::main) -> same Tk process, window mapped
#                               again, its table still holds the rows
#   * ::jtagid::tkhost::stop -> front end gone, Vivado session untouched
#
# Run in the Vivado IDE (about 45 s including the IDE start):
#     vivado -mode gui -nolog -nojournal -notrace -source tests/jtagid_tk_test_resident.tcl
#
# Measured on Vivado 2018.3 IDE, 2026-10:
#     RESIDENT|pid before hide = 30972  alive=1 win=1
#     jtagid: identify done: 8 candidate(s), die ZU3
#     RESIDENT|rows the chooser holds: 8
#     jtagid: window hidden - backend stays resident; run jtagid gui to re-open
#     RESIDENT|after Close: pid=30972 alive=1 win=0     <- same Tk process
#     RESIDENT|rows still held by the window: 8
#     jtagid: window restored (service was already running)
#     RESIDENT|rows after re-open: 8
#     RESIDENT|window is mapped again: 1
#     RESIDENT|after stop: alive=0 pid=
#
# Note: the Close click can arrive while an identify is still executing; the
# re-entrancy guard queues it instead of nesting into it (the command runs once
# the outer one finishes) - visible in the log as the "window hidden" line
# landing after the "after Close" check.
#
# Temporary/diagnostic helper.  ASCII only.
###############################################################################

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ..]]
source [file join $root jtagid_tk_gui.tcl]

after 6000 {
    puts "RESIDENT|pid before hide = [set ::jtagid::tkhost::S(pid)]  alive=[::jtagid::tkhost::alive] win=[set ::jtagid::tkhost::S(win)]"
    puts "RESIDENT|pressing Identify (nothing runs by itself any more)"
    ::jtagid::tkhost::send_line {::jtagid::tkgui::do_identify}
}
after 26000 {
    puts "RESIDENT|rows the chooser holds: [::jtagid::tkhost::query {llength [.g.pick.cand.tv children {}]}]"
    puts "RESIDENT|clicking the window close (it only hides the window)"
    ::jtagid::tkhost::send_line {::jtagid::tkgui::do_close}
}
after 29000 {
    puts "RESIDENT|after Close: pid=[set ::jtagid::tkhost::S(pid)] alive=[::jtagid::tkhost::alive] win=[set ::jtagid::tkhost::S(win)]"
    puts "RESIDENT|rows still held by the window: [::jtagid::tkhost::query {llength [.g.pick.cand.tv children {}]}]"
    puts "RESIDENT|re-opening with jtagid gui"
    ::jtagid::tkhost::main
}
after 33000 {
    puts "RESIDENT|after re-open: pid=[set ::jtagid::tkhost::S(pid)] alive=[::jtagid::tkhost::alive] win=[set ::jtagid::tkhost::S(win)]"
    puts "RESIDENT|rows after re-open: [::jtagid::tkhost::query {llength [.g.pick.cand.tv children {}]}]"
    puts "RESIDENT|window is mapped again: [::jtagid::tkhost::query {winfo ismapped .g}]"
    puts "RESIDENT|stopping the front end"
    ::jtagid::tkhost::stop
}
after 37000 {
    puts "RESIDENT|after stop: alive=[::jtagid::tkhost::alive] pid=[set ::jtagid::tkhost::S(pid)]"
    puts "RESIDENT|done"
}
puts "RESIDENT|front end started at [clock format [clock seconds] -format {%H:%M:%S}] - prompt free"
