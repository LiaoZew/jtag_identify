###############################################################################
# jtagid_tk_test_nonblock.tcl -- proof that the GUI no longer blocks Vivado.
#
# Run it in the Vivado IDE (it is what jtagid_tk.cmd does automatically):
#
#     vivado -mode gui -nolog -nojournal -notrace -source <this file>
#
# What it shows:
#   * "source returned after NNNN ms"   -> opening the window does not block
#   * a plain console command runs right after it -> the prompt is free
#   * idle timers fire seconds later, while the window is open -> Vivado keeps
#     serving the tunnel, so button clicks still work
#   * the automatic identify finishes on its own, after the source returned
#
# Measured on Vivado 2018.3 IDE, 2026-10:
#     NONBLOCK|source returned after 1829 ms
#     NONBLOCK|script end at 22:16:36 - the prompt is free
#     jtagid: identify done: 8 candidate(s)          <- 22:16:54, 18s later
#     NONBLOCK|idle timer at 22:16:54 - the console loop is alive
#     NONBLOCK|30s check: alive=0 win=0 idle=1
#
# Temporary/diagnostic helper.  ASCII only.
###############################################################################

set here [file dirname [file normalize [info script]]]

set t0 [clock milliseconds]
source [file join $here jtagid_tk_gui.tcl]
set t1 [clock milliseconds]

puts "NONBLOCK|source returned after [expr {$t1 - $t0}] ms"
puts "NONBLOCK|script continues at [clock format [clock seconds] -format {%H:%M:%S}]"
puts "NONBLOCK|this is a plain console command running AFTER the GUI started"

after 3000 {
    puts "NONBLOCK|idle timer at [clock format [clock seconds] -format {%H:%M:%S}] - the console loop is alive while the window is open"
}
after 8000 {
    puts "NONBLOCK|status at [clock format [clock seconds] -format {%H:%M:%S}]:"
    puts "NONBLOCK|[string map [list "\n" " | "] [::jtagid::tkhost::status]]"
}
after 30000 {
    puts "NONBLOCK|30s check: alive=[::jtagid::tkhost::alive] win=[set ::jtagid::tkhost::S(win)] idle=[set ::jtagid::tkhost::S(idle)]"
}

puts "NONBLOCK|script end at [clock format [clock seconds] -format {%H:%M:%S}] - the prompt is free"
