###############################################################################
# jtagid_vivado_gui.tcl -- native Vivado GUI for the jtagid driver.
#
# No Tk, no external runtime: it uses Vivado's own custom-command dialogs
# (create_gui_custom_command), which exist in 2018.3, 2022.2 and 2024.2.
#
# Use it inside a Vivado GUI session:
#
#       source D:/.../jtag_identify/jtagid.tcl
#       source D:/.../jtag_identify/jtagid_vivado_gui.tcl
#
# It adds these items under  Tools -> Custom Commands :
#
#       jtagid: Identify FPGA     dialog -> BSDL dir / package hint / part
#       jtagid: Use 1: <model> <pkg> ...      one clickable item per candidate
#       jtagid: Use by path       dialog -> BSDL path (manual, or the default)
#       jtagid: Scan chain
#       jtagid: Environment
#
# Why not Tk: Vivado's Tcl has no Tk runtime.  Verified in GUI mode on 2018.3
# (Tcl 8.5.14) and 2024.2 (Tcl 8.6.13): "package require Tk" fails and the
# commands toplevel/wm/ttk::button do not exist at all (2024.2 only ships the
# Tk script library, the DLL is missing).  Every wish/tclsh found on this
# machine -- including the copies inside the Vivado/Vitis trees -- belongs to
# Git for Windows.
#
# Vivado's custom-command arguments are plain text fields (options are only
# -default / -comment / -optional, there is no -arg_type or -choice_list), so
# candidate selection is done with dynamically registered menu items instead
# of a combo box.
#
# ASCII only on purpose (Vivado decodes sourced files with the system code
# page); the display strings come from jtagid_gui_msgs.txt (UTF-8).
#
# 2026-10
###############################################################################

namespace eval ::jtagid::vgui {
    variable MSG
    variable S
    array set MSG {}
    array set S {
        candidates {}
        chosen     ""
        last_pkg   ""
        pick_names {}
    }
}

set ::jtagid::vgui::HERE [file dirname [file normalize [info script]]]

#==============================================================================
# display strings (UTF-8 file, English fallback)
#==============================================================================

proc ::jtagid::vgui::load_msgs {} {
    variable MSG
    array set MSG {}
    set file [file join $::jtagid::vgui::HERE jtagid_gui_msgs.txt]
    if {![file exists $file]} { return 0 }
    if {[catch {open $file r} fh]} { return 0 }
    fconfigure $fh -encoding utf-8
    while {[gets $fh line] >= 0} {
        set line [string trimright $line "\r\n"]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set parts [split $line \t]
        if {[llength $parts] < 2} { continue }
        set MSG([string trim [lindex $parts 0]]) [join [lrange $parts 1 end] \t]
    }
    close $fh
    return 1
}

proc ::jtagid::vgui::T {key default} {
    variable MSG
    if {[info exists MSG($key)]} { return $MSG($key) }
    return $default
}

#==============================================================================
# driver / defaults
#==============================================================================

proc ::jtagid::vgui::ensure_driver {} {
    if {[llength [info commands ::jtagid::collect_report]] > 0} { return 1 }
    set driver [file join $::jtagid::vgui::HERE jtagid.tcl]
    if {![file exists $driver]} { return 0 }
    uplevel #0 [list source $driver]
    return [expr {[llength [info commands ::jtagid::collect_report]] > 0}]
}

proc ::jtagid::vgui::default_bsdl_dir {} {
    if {[llength [info commands ::jtagid::default_bsdl_dir]] > 0} {
        return [::jtagid::default_bsdl_dir]
    }
    return ""
}

#==============================================================================
# registration helpers (exact 2018.3/2022.2/2024.2 syntax)
#   create_gui_custom_command     -name N [-menu_name M] [-description D]
#                                 [-command C] [-show_on_toolbar]
#   create_gui_custom_command_arg -command_name N -arg_name A
#                                 [-default V] [-comment T] [-optional]
#==============================================================================

proc ::jtagid::vgui::add_command {name menu description command} {
    if {[catch {create_gui_custom_command -name $name -menu_name $menu \
                   -description $description -command $command} err]} {
        puts "jtagid: cannot register '$name': $err"
        return 0
    }
    return 1
}

proc ::jtagid::vgui::add_arg {command_name arg_name default comment {optional 0}} {
    set cmd [list create_gui_custom_command_arg -command_name $command_name \
                 -arg_name $arg_name -default $default -comment $comment]
    if {$optional} { lappend cmd -optional }
    if {[catch {eval $cmd} err]} {
        puts "jtagid: cannot add argument '$arg_name' to '$command_name': $err"
        return 0
    }
    return 1
}

proc ::jtagid::vgui::remove_commands {names} {
    if {[llength $names] == 0} { return }
    if {[llength [info commands remove_gui_custom_command_args]] > 0} {
        catch {remove_gui_custom_command_args -quiet {*}$names}
    }
    if {[llength [info commands remove_gui_custom_commands]] > 0} {
        catch {remove_gui_custom_commands -quiet {*}$names}
    }
    return
}

#==============================================================================
# dialog argument handling (key/value or positional, defensive)
#==============================================================================

proc ::jtagid::vgui::args_to_array {argsVar argList names} {
    upvar 1 $argsVar opt
    foreach n $names { set opt($n) "" }
    set flat $argList
    if {[llength $flat] == 1 && [llength [lindex $flat 0]] > 1} { set flat [lindex $flat 0] }
    if {[llength $flat] > 0 && [string match -* [lindex $flat 0]]} {
        set i 0
        while {$i < [llength $flat]} {
            set key [string trimleft [lindex $flat $i] -]
            set value ""
            if {[expr {$i + 1}] < [llength $flat]} { set value [lindex $flat [expr {$i + 1}]] }
            set opt($key) $value
            incr i 2
        }
    } else {
        # positional values in registration order
        set i 0
        foreach n $names {
            if {$i < [llength $flat]} { set opt($n) [lindex $flat $i] }
            incr i
        }
    }
    return
}

#==============================================================================
# callbacks
#==============================================================================

proc ::jtagid::vgui::identify {args} {
    variable S
    ::jtagid::vgui::args_to_array opt $args {bsdl_dir package part}
    if {![::jtagid::vgui::ensure_driver]} {
        puts "jtagid: jtagid.tcl not found next to jtagid_vivado_gui.tcl"
        return
    }
    puts "================================================================"
    puts " jtagid: identify  (bsdl_dir='$opt(bsdl_dir)' package='$opt(package)' part='$opt(part)')"
    puts "================================================================"
    if {[catch {
        set res [::jtagid::collect_report -bsdl-dir $opt(bsdl_dir) -part $opt(part)]
    } err]} {
        puts "jtagid: identification failed: $err"
        return
    }
    set info [dict get $res info]
    foreach key {vivado url bsdl_dir bsdl_files} {
        if {[dict exists $info $key]} { puts [format "  %-11s: %s" $key [dict get $info $key]] }
    }
    foreach d [dict get $res devices] {
        set decoded ""
        if {[dict get $d idcode] ne ""} {
            set decoded "[dict get $d mfg] family=[dict get $d family] array=[dict get $d array]"
        }
        puts [format "  %-14s PART=%-12s IDCODE=%-12s %s" \
                  [dict get $d name] [dict get $d part] [dict get $d idcode] $decoded]
    }
    set part [dict get $res part]
    if {$part ne ""} {
        puts "  part check  : [dict get $part given] -> '[dict get $part matched]' ([dict get $part message])"
    }
    foreach e [dict get $res errors] { puts "  ERROR: $e" }
    set all [dict get $res candidates]
    set pkg [string trim $opt(package)]
    set filtered [list]
    foreach c $all {
        if {$pkg ne "" && ![string equal -nocase [dict get $c package] $pkg]} { continue }
        lappend filtered $c
    }
    set S(candidates) $filtered
    set S(last_pkg) $pkg
    puts "  BSDL matched: [llength $all] file(s); shown: [llength $filtered]"
    set i 0
    foreach c $filtered {
        incr i
        puts [format "   %2d. %-16s package=%-9s IRL=%-3s BSR=%-5s %s" $i \
                  [dict get $c models] [dict get $c package] [dict get $c irl] \
                  [dict get $c bsr] [file tail [dict get $c path]]]
    }
    set packages [list]
    foreach c $all {
        if {[lsearch -exact $packages [dict get $c package]] < 0} { lappend packages [dict get $c package] }
    }
    if {[llength $packages] > 1 && $pkg eq ""} {
        puts "  note: this IDCODE matches several packages -> $packages"
        puts "        filter them with the 'package' field, or click a 'jtagid: Use ...' item below"
    }
    ::jtagid::vgui::register_picks $filtered
    puts "  pick one: Tools -> Custom Commands -> 'jtagid: Use ...'  (also available: Use by path)"
    update
    return
}

proc ::jtagid::vgui::register_picks {candidates} {
    variable S
    # drop the picker items of the previous run
    ::jtagid::vgui::remove_commands $S(pick_names)
    set S(pick_names) [list]
    set n 0
    set max 12
    foreach c $candidates {
        incr n
        if {$n > $max} { break }
        set name "jtagid_pick_$n"
        set label [format "jtagid: Use %d: %s %s" $n [dict get $c models] [dict get $c package]]
        set desc  "BSDL: [dict get $c path]\nentity=[dict get $c entity] IRL=[dict get $c irl] BSR=[dict get $c bsr]"
        set cmd   [list ::jtagid::vgui::choose [dict get $c path]]
        if {[::jtagid::vgui::add_command $name $label $desc $cmd]} {
            lappend S(pick_names) $name
        }
    }
    # and a manual entry point
    set first ""
    if {[llength $candidates] > 0} { set first [dict get [lindex $candidates 0] path] }
    if {[::jtagid::vgui::add_command jtagid_pick_path \
             [::jtagid::vgui::T menu_pick {jtagid: Use by path}] \
             [::jtagid::vgui::T desc_pick {Use a BSDL file given by path}] \
             ::jtagid::vgui::choose_by_path]} {
        ::jtagid::vgui::add_arg jtagid_pick_path bsdl $first \
            [::jtagid::vgui::T arg_pick {BSDL file to use (path)}]
        lappend S(pick_names) jtagid_pick_path
    }
    if {[llength $candidates] > $max} {
        puts "jtagid: only the first $max candidates got a menu item; use 'Use by path' for the rest"
    }
    return [llength $S(pick_names)]
}

proc ::jtagid::vgui::choose_by_path {args} {
    ::jtagid::vgui::args_to_array opt $args {bsdl}
    return [::jtagid::vgui::choose $opt(bsdl)]
}

proc ::jtagid::vgui::choose {path} {
    variable S
    set path [string trim $path]
    if {$path eq ""} { puts "jtagid: no BSDL given"; return "" }
    set path [string map {\\ /} $path]
    if {![file exists $path]} {
        puts "jtagid: not a file: $path"
        return ""
    }
    set S(chosen) $path
    puts "----------------------------------------------------------------"
    puts " jtagid: selected BSDL"
    puts "----------------------------------------------------------------"
    puts "  file     : $path"
    if {[llength [info commands ::jtagid::bsdl_details]] > 0} {
        if {![catch {set d [::jtagid::bsdl_details $path]} err]} {
            foreach key {entity model package irl bsr cells} {
                if {[dict exists $d $key]} { puts [format "  %-9s: %s" $key [dict get $d $key]] }
            }
            if {[llength [info commands ::jtagid::ints]] > 0} {
                puts "  usage    : jtagid boundary -bsdl [file tail $path]   (IRL/BSR above drive any further boundary-scan work)"
            }
        } else {
            puts "  (bsdl_details: $err)"
        }
    }
    set dir [file join $::env(LOCALAPPDATA) jtag_identify]
    catch {file mkdir $dir}
    if {![catch {open [file join $dir selected_bsdl.txt] w} fh]} {
        puts $fh $path
        close $fh
        puts "  remembered: [file join $dir selected_bsdl.txt]"
    }
    update
    return $path
}

proc ::jtagid::vgui::scan {args} {
    if {![::jtagid::vgui::ensure_driver]} { return }
    if {[catch {::jtagid::connect} err]} { puts "jtagid: $err"; return }
    if {[catch {::jtagid::ensure_target} err]} { puts "jtagid: $err"; return }
    set devs [::jtagid::devices]
    puts "================================================================"
    puts " jtagid: JTAG chain"
    puts "================================================================"
    foreach d $devs {
        puts [format "  %-14s PART=%-12s IDCODE=%-12s" \
                  [dict get $d name] [dict get $d part] [dict get $d idcode]]
    }
    if {[llength $devs] == 0} { puts "  (no device enumerated)" }
    update
    return
}

proc ::jtagid::vgui::environment {args} {
    if {![::jtagid::vgui::ensure_driver]} { return }
    set c [::jtagid::probe_compat 1]
    puts "================================================================"
    puts " jtagid: environment"
    puts "================================================================"
    foreach key {vivado tcl batch hw_commands load_features has_labtools hw_server} {
        if {[dict exists $c $key]} { puts [format "  %-14s: %s" $key [dict get $c $key]] }
    }
    puts [format "  %-14s: %s" bsdl_dir [::jtagid::vgui::default_bsdl_dir]]
    puts [format "  %-14s: %s" tk [expr {[catch {package require Tk}] ? {unavailable} : {available}}]]
    puts [format "  %-14s: %s custom command(s)" gui_commands [llength [get_gui_custom_commands]]]
    update
    return
}

#==============================================================================
# registration
#==============================================================================

proc ::jtagid::vgui::register {} {
    if {[llength [info commands create_gui_custom_command]] == 0} {
        puts "jtagid_vivado_gui.tcl: create_gui_custom_command not available here."
        return 0
    }
    ::jtagid::vgui::load_msgs
    set ok 0
    set bdir [::jtagid::vgui::default_bsdl_dir]
    ::jtagid::vgui::remove_commands {jtagid_identify jtagid_scan jtagid_env jtagid_pick jtagid_pick_path}
    foreach old [get_gui_custom_commands -quiet jtagid_pick_*] {
        ::jtagid::vgui::remove_commands $old
    }
    set S(pick_names) [list]
    if {[::jtagid::vgui::add_command jtagid_identify \
             [::jtagid::vgui::T menu_identify {jtagid: Identify FPGA}] \
             [::jtagid::vgui::T desc_identify {Read IDCODE and look up the model in BSDL}] \
             ::jtagid::vgui::identify]} {
        ::jtagid::vgui::add_arg jtagid_identify bsdl_dir $bdir \
            [::jtagid::vgui::T arg_bsdl_dir {BSDL directory to search}]
        ::jtagid::vgui::add_arg jtagid_identify package "" \
            [::jtagid::vgui::T arg_package {Package hint, empty = all packages}] 1
        ::jtagid::vgui::add_arg jtagid_identify part "" \
            [::jtagid::vgui::T arg_part {Part string to verify, optional}] 1
        incr ok
    }
    if {[::jtagid::vgui::add_command jtagid_scan \
             [::jtagid::vgui::T menu_scan {jtagid: Scan chain}] \
             [::jtagid::vgui::T desc_scan {List every TAP on the JTAG chain}] \
             ::jtagid::vgui::scan]} { incr ok }
    if {[::jtagid::vgui::add_command jtagid_env \
             [::jtagid::vgui::T menu_version {jtagid: Environment}] \
             [::jtagid::vgui::T desc_version {Show versions and hardware compatibility}] \
             ::jtagid::vgui::environment]} { incr ok }
    puts "jtagid: registered $ok command(s) under Tools -> Custom Commands"
    return $ok
}

#==============================================================================
# entry point
#==============================================================================

if {[llength [info commands create_gui_custom_command]] > 0} {
    ::jtagid::vgui::register
} else {
    puts "jtagid_vivado_gui.tcl: no custom-command API in this session (batch mode); nothing registered."
}
