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
# Run in the Vivado IDE:
#     vivado -mode gui -nolog -nojournal -notrace -source <this file>
#
# Measured on Vivado 2018.3 IDE, 2026-10 (18 s):
#     RESIDENT|pid before hide = 23532  alive=1 win=1
#     RESIDENT|after Close: pid=23532 alive=1        <- same Tk process
#     RESIDENT|rows still held by the window: 8
#     jtagid: window restored (service was already running)
#     RESIDENT|rows after re-open: 8
#     RESIDENT|window is mapped again: 1
#     RESIDENT|after stop: alive=0 pid=
#
# Note in that run: the Close click arrived while an identify was executing and
# was queued by the re-entrancy guard instead of nesting into it (the command
# is executed once the outer one finishes) - visible in the log as the
# "window hidden" line landing after the "after Close" check.
#
# Temporary/diagnostic helper.  ASCII only.
###############################################################################

set here [file dirname [file normalize [info script]]]
source [file join $here jtagid_tk_gui.tcl]

after 6000 {
    puts "RESIDENT|pid before hide = [set ::jtagid::tkhost::S(pid)]  alive=[::jtagid::tkhost::alive] win=[set ::jtagid::tkhost::S(win)]"
    puts "RESIDENT|clicking the Close button (it only hides the window)"
    ::jtagid::tkhost::send_line {::jtagid::tkgui::do_close}
}
after 9000 {
    puts "RESIDENT|after Close: pid=[set ::jtagid::tkhost::S(pid)] alive=[::jtagid::tkhost::alive] win=[set ::jtagid::tkhost::S(win)]"
    puts "RESIDENT|rows still held by the window: [::jtagid::tkhost::query {llength [.g.cand.tv children {}]}]"
    puts "RESIDENT|re-opening with jtagid gui"
    ::jtagid::tkhost::main
}
after 12000 {
    puts "RESIDENT|after re-open: pid=[set ::jtagid::tkhost::S(pid)] alive=[::jtagid::tkhost::alive] win=[set ::jtagid::tkhost::S(win)]"
    puts "RESIDENT|rows after re-open: [::jtagid::tkhost::query {llength [.g.cand.tv children {}]}]"
    puts "RESIDENT|window is mapped again: [::jtagid::tkhost::query {winfo ismapped .g}]"
    puts "RESIDENT|stopping the front end"
    ::jtagid::tkhost::stop
}
after 16000 {
    puts "RESIDENT|after stop: alive=[::jtagid::tkhost::alive] pid=[set ::jtagid::tkhost::S(pid)]"
    puts "RESIDENT|done"
}
puts "RESIDENT|front end started at [clock format [clock seconds] -format {%H:%M:%S}] - prompt free"
