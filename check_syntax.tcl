# parse-only syntax check: compile the script without executing it
# usage: tclsh syntax_check.tcl <files...>
foreach f $argv {
    if {[catch {open $f r} fh]} { puts "OPEN-FAIL $f"; continue }
    set data [read $fh]
    close $fh
    if {[catch {::tcl::unsupported::disassemble script $data} res]} {
        puts "SYNTAX-ERROR $f"
        puts "  $res"
    } else {
        puts "OK $f ([string length $data] bytes)"
    }
}
