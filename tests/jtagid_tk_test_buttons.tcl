###############################################################################
# jtagid_tk_test_buttons.tcl -- drive the whole GUI flow from outside.
#
# A click does this: the Tk side runs tkgui::do_*, which broadcasts the matching
# tkhost::cmd_* command into Vivado, which answers with a payload that the window
# renders.  This script does exactly that (plus a deliberately broken backend
# command) and prints what the window ended up showing, so a regression in any of
# those paths shows up without anyone touching the mouse:
#
#   * nothing happens on its own: no candidates, no chooser before identify
#   * identify -> the chooser opens with every candidate, busy returns to 0
#   * the package/model filters narrow the table (they must separate siblings)
#   * "use this BSDL" binds the device and closes the chooser
#   * a broken backend command reaches the window as an error AND unlocks it
#     (that is the "clicked and nothing happens" bug: no reply ever arrived)
#
# Run it in the Vivado IDE (about 70 s):
#
#     vivado -mode gui -nolog -nojournal -notrace -source tests/jtagid_tk_test_buttons.tcl
#
# Measured on Vivado 2018.3 IDE, 2026-10:
#     BTN|on-open|busy=0 chooser=0 rows=0              <- nothing automatic
#     BTN|after-identify|busy=0 chooser=1 rows=8
#     BTN|after-filter|busy=0 chooser=1 rows=2
#     BTN|after-model|busy=0 chooser=1 rows=1
#     BTN|after-use|busy=0 chooser=0 rows=1
#     BTN|bound=bsdl/.../xczu3eg_sfvc784.bsd
#     BTN|after-bogus|busy=0 chooser=0 rows=1
#     BTN|after-bogus|status=failed: invalid command name "..."  (red)
#
# The binding line is ".g.bd.e", the chooser is ".g.pick" (rows in
# ".g.pick.cand.tv"), the filters are ".g.pick.cand.f.pkg|model|kw".
#
# Temporary/diagnostic helper.  ASCII only.
###############################################################################

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ..]]
source [file join $root jtagid_tk_gui.tcl]

proc report {tag} {
    set busy [::jtagid::tkhost::query {set ::jtagid::tkgui::S(busy)}]
    set open [::jtagid::tkhost::query {winfo ismapped .g.pick}]
    set rows [::jtagid::tkhost::query {llength [.g.pick.cand.tv children {}]}]
    puts "BTN|$tag|busy=$busy chooser=$open rows=$rows"
}
proc report_status {tag} {
    puts "BTN|$tag|status=[::jtagid::tkhost::query {.g.st cget -text}]"
}

after 12000 {
    report "on-open"                      ;# must show chooser=0 rows=0
    puts "BTN|pressing IDENTIFY (button path, not the self test)"
    ::jtagid::tkhost::send_line {::jtagid::tkgui::do_identify}
}
after 30000 { report "after-identify" }
after 31000 {
    puts "BTN|filtering: package SFVC784"
    ::jtagid::tkhost::send_line {.g.pick.cand.f.pkg set SFVC784; ::jtagid::tkgui::apply_filters}
}
after 33000 { report "after-filter" }
after 34000 {
    puts "BTN|filtering: model XCZU3EG"
    ::jtagid::tkhost::send_line {.g.pick.cand.f.model set XCZU3EG; ::jtagid::tkgui::apply_filters}
}
after 36000 { report "after-model" }
after 37000 {
    puts "BTN|selecting the visible row and using it"
    ::jtagid::tkhost::send_line {set f [lindex [.g.pick.cand.tv children {}] 0]; .g.pick.cand.tv selection set $f; ::jtagid::tkgui::on_select; ::jtagid::tkgui::use_selected}
}
after 41000 {
    report "after-use"
    puts "BTN|bound=[::jtagid::tkhost::query {.g.bd.e get}]"
    puts "BTN|injecting a broken BACKEND command (error net)"
    ::jtagid::tkhost::run_line {::jtagid::tkhost::cmd_this_does_not_exist}
}
after 44000 {
    report "after-bogus"
    report_status "after-bogus"
    puts "BTN|closing the window"
    ::jtagid::tkhost::send_line {::jtagid::tkgui::quit_app}
}
after 47000 { puts "BTN|done" }
puts "BTN|armed at [clock format [clock seconds] -format {%H:%M:%S}] - prompt free"
