###############################################################################
# jtagid_tk_test_buttons.tcl -- drive the three buttons from outside.
#
# A click does this: the Tk side runs tkgui::do_*, which broadcasts the matching
# tkhost::cmd_* command into Vivado, which answers with a payload that the
# window renders.  This script does exactly that (plus a deliberately broken
# backend command) and prints what the window ended up showing, so a regression
# in any of those paths shows up without anyone touching the mouse:
#
#   * identify / scan / reindex all answer, and busy always returns to 0
#   * scan must keep the candidate table (2 TAP, 8 BSDL), not clear it
#   * a broken backend command must reach the window as an error AND unlock it
#     (that is the "clicked and nothing happens" bug: no reply ever arrived)
#
# Run it in the Vivado IDE (about 90 s):
#
#     vivado -mode gui -nolog -nojournal -notrace -source <this file>
#
# Measured on Vivado 2018.3 IDE, 2026-10:
#     BTN|after-identify|busy=0 dev_rows=2 cand_rows=8
#     BTN|after-scan|busy=0 dev_rows=2 cand_rows=8
#     BTN|after-reindex|busy=0 dev_rows=2 cand_rows=8
#     BTN|after-bogus|busy=0 dev_rows=2 cand_rows=8
#     ...|status=failed: invalid command name "::jtagid::tkhost::cmd_..."  (red)
#     jtagid: scan: 2 TAP(s), 0 problem(s)
#     jtagid: reindex: 840 BSDL file(s) in D:/.../vivado_tools/bsdl
#
# The three buttons read the status line through ".g.st cget -text"; the tables
# are ".g.dev.tv" (chain) and ".g.cand.tv" (BSDL candidates).
#
# Temporary/diagnostic helper.  ASCII only.
###############################################################################

set here [file dirname [file normalize [info script]]]
source [file join $here jtagid_tk_gui.tcl]

proc report {tag} {
    set busy [::jtagid::tkhost::query {set ::jtagid::tkgui::S(busy)}]
    set dev  [::jtagid::tkhost::query {llength [.g.dev.tv children {}]}]
    set cand [::jtagid::tkhost::query {llength [.g.cand.tv children {}]}]
    set stat [::jtagid::tkhost::query {.g.st cget -text}]
    puts "BTN|$tag|busy=$busy dev_rows=$dev cand_rows=$cand"
    puts "BTN|$tag|status=$stat"
}

after 30000 {
    report "after-identify"
    puts "BTN|injecting a broken BACKEND command (error net)"
    ::jtagid::tkhost::run_line {::jtagid::tkhost::cmd_this_does_not_exist}
}
after 33000 {
    report "after-bogus"
    puts "BTN|clicking SCAN"
    ::jtagid::tkhost::send_line {::jtagid::tkgui::do_scan}
}
after 40000 {
    report "after-scan"
    puts "BTN|clicking REINDEX"
    ::jtagid::tkhost::send_line {::jtagid::tkgui::do_reindex}
}
after 50000 {
    report "after-reindex"
    puts "BTN|closing the window"
    ::jtagid::tkhost::send_line {::jtagid::tkgui::quit_app}
}
after 54000 {
    puts "BTN|done"
}
puts "BTN|armed at [clock format [clock seconds] -format {%H:%M:%S}] - prompt free"
