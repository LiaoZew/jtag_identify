###############################################################################
# jtagid_gui.tcl -- Tk GUI for the jtagid boundary-scan identification driver
#
# Standalone Tk application (run it with wish):
#       jtagid_gui.cmd                     (Windows launcher, recommended)
#       wish jtagid_gui.tcl                (any Tcl/Tk 8.5+)
#
# Design notes
#   * The GUI never talks to the cable itself. It starts a persistent
#     "vivado -mode tcl" backend, sources jtagid.tcl there, and drives it with
#     marker delimited commands (GB|<token> ... GE|<token>). After the first
#     start each action takes 1-3 seconds.
#   * Works with any Vivado that has the labtools feature; it does NOT need
#     Vivado to ship Tk (Vivado 2018.3 does not).
#   * This file is ASCII only on purpose: Vivado decodes sourced scripts with
#     the system code page, so non-ASCII text would break parsing. All display
#     strings live in jtagid_gui_msgs.txt (UTF-8, key<TAB>text) and can be
#     edited without touching code.
#
# 2026-10
###############################################################################

package require Tk

namespace eval ::jtagid::gui {
    variable H      ;# widget handles
    variable S      ;# state
    variable MSG    ;# display strings (loaded from jtagid_gui_msgs.txt)
    array set MSG {}
    array set S {
        token        0
        busy         0
        chan         ""
        pid          ""
        buf          {}
        in_block     0
        candidates   {}
        devices      {}
        selected     ""
        watchdog     ""
        done_var     ""
        vivado       ""
        started      0
        debug        0
        filter_pkg   ""
        filter_model ""
        filter_text  ""
    }
}

set ::jtagid::gui::HERE [file dirname [file normalize [info script]]]

#==============================================================================
# messages (UTF-8 file, English fallback)
#==============================================================================

proc ::jtagid::gui::load_msgs {} {
    variable MSG
    array unset MSG
    array set MSG {}
    set file [file join $::jtagid::gui::HERE jtagid_gui_msgs.txt]
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

proc ::jtagid::gui::T {key {default ""}} {
    variable MSG
    if {[info exists MSG($key)]} { return $MSG($key) }
    return $default
}

#==============================================================================
# helpers
#==============================================================================

proc ::jtagid::gui::set_status {text {tag normal}} {
    variable H
    $H(status) configure -text $text
    switch -- $tag {
        error { $H(status) configure -foreground "#b00020" }
        ok    { $H(status) configure -foreground "#006400" }
        busy  { $H(status) configure -foreground "#8a6d00" }
        default { $H(status) configure -foreground "#000000" }
    }
}

proc ::jtagid::gui::log_line {text} {
    variable H
    variable S
    if {$S(debug)} { ::jtagid::gui::st "LOG|$text" }
    $H(log) configure -state normal
    $H(log) insert end "$text\n"
    $H(log) see end
    $H(log) configure -state disabled
}

proc ::jtagid::gui::set_busy {flag} {
    variable S
    variable H
    set S(busy) $flag
    set state [expr {$flag ? "disabled" : "normal"}]
    foreach b {identify scan reindex choosedir} {
        catch {$H(btn_$b) configure -state $state}
    }
}

proc ::jtagid::gui::resolve_tool {name} {
    # Resolve to a real file with a Windows extension. auto_execok("vivado")
    # happily returns the extension-less MSYS shell script, which cannot be
    # spawned as a process from Tcl, so .bat/.exe are tried first and the
    # result must exist on disk.
    foreach cand [list $name.bat $name.exe $name] {
        if {[catch {set p [auto_execok $cand]}] || $p eq ""} { continue }
        if {[file exists $p]} { return [file normalize $p] }
        foreach ext {.bat .exe} {
            if {[file exists "$p$ext"]} { return [file normalize "$p$ext"] }
        }
    }
    return ""
}

proc ::jtagid::gui::find_vivado {} {
    # PATH first (honours the user's PATH order), then the usual install roots
    set from_path [::jtagid::gui::resolve_tool vivado]
    if {$from_path ne ""} { return $from_path }
    set found {}
    foreach root {C:/Xilinx D:/Xilinx D:/xilinx E:/Xilinx} {
        if {![file isdirectory $root]} { continue }
        foreach pattern [list "$root/*/Vivado/*/bin/vivado.bat" "$root/*/*/Vivado/*/bin/vivado.bat"] {
            foreach p [lsort -decreasing [glob -nocomplain $pattern]] { lappend found $p }
        }
    }
    foreach p $found { if {[file exists $p]} { return [file normalize $p] } }
    return ""
}

#==============================================================================
# backend: persistent "vivado -mode tcl" driven by markers
#==============================================================================

proc ::jtagid::gui::start_backend {} {
    variable S
    variable H
    if {$S(started)} { return 1 }
    if {$S(chan) ne ""} {
        if {![catch {eof $S(chan)} e] && !$e} { return 1 }
        catch {close $S(chan)}
        set S(chan) ""
    }
    if {$S(vivado) eq ""} { set S(vivado) [::jtagid::gui::find_vivado] }
    if {$S(vivado) eq ""} {
        ::jtagid::gui::set_status [::jtagid::gui::T no_vivado "vivado.bat not found"] error
        return 0
    }
    set driver [file join $::jtagid::gui::HERE jtagid.tcl]
    if {![file exists $driver]} {
        ::jtagid::gui::set_status "jtagid.tcl not found next to jtagid_gui.tcl" error
        return 0
    }
    ::jtagid::gui::set_status "[::jtagid::gui::T backend_starting {starting backend}] ..." busy
    if {[catch {open "|[list $S(vivado) -mode tcl -nolog -nojournal -notrace]" r+} chan]} {
        ::jtagid::gui::set_status "cannot start Vivado: $chan" error
        return 0
    }
    set S(chan) $chan
    catch {set S(pid) [pid $chan]}
    fconfigure $chan -blocking 0 -buffering line -translation auto -encoding iso8859-1
    fileevent $chan readable [list ::jtagid::gui::on_readable]
    # Order matters: the driver must be sourced before anything touches
    # ::jtagid::... (setting state(quiet) first fails with "parent namespace
    # doesn't exist" and the interactive shell then swallows the source line).
    # tcl_traceExec is cleared so the backend does not echo every sourced line.
    ::jtagid::gui::send [list \
        "set ::tcl_traceExec 0" \
        "source [list $driver]" \
        "set ::jtagid::state(quiet) 1" \
        "puts \"GUIREADY\"" \
        "puts \"INFO\\tbsdl_dir\\t\[::jtagid::default_bsdl_dir\]\"" \
        "puts \"INFO\\tbackend\\t\$::jtagid::compat(vivado)\""]
    return 1
}

proc ::jtagid::gui::send {commands} {
    variable S
    variable H
    incr S(token)
    set tok $S(token)
    set S(buf) {}
    set S(in_block) 0
    if {[catch {
        puts $S(chan) "puts \"GB|$tok\"; flush stdout"
        foreach cmd $commands {
            if {[string trim $cmd] eq ""} { continue }
            puts $S(chan) $cmd
        }
        puts $S(chan) "puts \"GE|$tok\"; flush stdout"
        flush $S(chan)
    } err]} {
        ::jtagid::gui::st "SEND_ERROR|$err"
        ::jtagid::gui::log_line "send failed: $err"
        ::jtagid::gui::set_status "cannot talk to the Vivado backend: $err" error
        return 0
    }
    if {$S(debug)} { ::jtagid::gui::st "SENT|tok=$tok|cmds=[llength $commands]" }
    return $tok
}

proc ::jtagid::gui::send_guarded {commands} {
    # wrap in catch so a failing command still produces an ERR line and an end marker
    set body ""
    foreach cmd $commands { append body "    $cmd\n" }
    return [::jtagid::gui::send [list "if {\[catch {\n$body} __jerr\]} { puts \"ERR\\t\[::jtagid::one_line \$__jerr\]\" }"]]
}

proc ::jtagid::gui::on_readable {} {
    variable S
    if {$S(chan) eq ""} { return }
    if {[catch {
        while {[gets $S(chan) line] >= 0} {
            set line [string trimright $line "\r"]
            if {$S(debug)} { ::jtagid::gui::st "RECV|$line" }
            if {[string match "GB|*" $line]} {
                set S(buf) {}
                set S(in_block) 1
                continue
            }
            if {[string match "GE|*" $line]} {
                set S(in_block) 0
                ::jtagid::gui::finish_block
                continue
            }
            if {$S(in_block)} {
                lappend S(buf) $line
            } elseif {[string match "GUIREADY*" $line]} {
                set S(started) 1
                ::jtagid::gui::st "SELFTEST|gui_ready_seen"
                ::jtagid::gui::set_status [::jtagid::gui::T backend_ready {backend ready}] ok
            } elseif {[string trim $line] ne ""} {
                ::jtagid::gui::log_line $line
            }
        }
    } err]} {
        ::jtagid::gui::st "READ_ERROR|$err"
    }
    if {[eof $S(chan)]} {
        ::jtagid::gui::log_line "*** backend exited ***"
        ::jtagid::gui::set_status [::jtagid::gui::T backend_dead {backend exited}] error
        catch {close $S(chan)}
        set S(chan) ""
        set S(started) 0
        ::jtagid::gui::set_busy 0
    }
}

#==============================================================================
# result handling
#==============================================================================

proc ::jtagid::gui::finish_block {} {
    variable S
    variable H
    set devices {}
    set candidates {}
    set errors {}
    foreach line $S(buf) {
        set p [split $line \t]
        set key [lindex $p 0]
        switch -- $key {
            DEV {
                lappend devices [dict create name [lindex $p 1] part [lindex $p 2] \
                    idcode [lindex $p 3] family [lindex $p 4] array [lindex $p 5] \
                    mfg [lindex $p 6] fpga [lindex $p 7]]
            }
            CAND {
                lappend candidates [dict create models [lindex $p 1] package [lindex $p 2] \
                    irl [lindex $p 3] bsr [lindex $p 4] cells [lindex $p 5] \
                    path [lindex $p 6] entity [lindex $p 7]]
            }
            INFO {
                if {[lindex $p 1] eq "bsdl_dir"} {
                    $H(bsdl_dir_entry) delete 0 end
                    $H(bsdl_dir_entry) insert 0 [lindex $p 2]
                } elseif {[lindex $p 1] eq "bsdl_files"} {
                    ::jtagid::gui::log_line "BSDL index: [lindex $p 2] files"
                } elseif {[lindex $p 1] eq "backend"} {
                    ::jtagid::gui::log_line "backend Vivado [lindex $p 2]"
                } elseif {[lindex $p 1] eq "idcode"} {
                    ::jtagid::gui::log_line "FPGA IDCODE [lindex $p 2]"
                } elseif {[lindex $p 1] eq "vivado"} {
                    ::jtagid::gui::log_line "session Vivado [lindex $p 2]"
                }
            }
            ERR { lappend errors [lindex $p 1] }
            PART {
                ::jtagid::gui::log_line "part check: [lindex $p 1] -> [lindex $p 2] ([lindex $p 3])"
            }
            default { }
        }
    }
    if {[llength $devices] > 0} { set S(devices) $devices }
    if {[llength $candidates] > 0} { set S(candidates) $candidates }
    ::jtagid::gui::fill_devices
    ::jtagid::gui::fill_filters
    ::jtagid::gui::apply_filters
    ::jtagid::gui::cancel_watchdog
    ::jtagid::gui::set_busy 0
    if {[llength $errors] > 0} {
        ::jtagid::gui::set_status "[::jtagid::gui::T status_failed {failed}]: [join $errors { | }]" error
        foreach e $errors { ::jtagid::gui::log_line "ERROR: $e" }
    } elseif {[llength $candidates] > 0} {
        ::jtagid::gui::set_status "[::jtagid::gui::T status_done {done}]: [llength $candidates] BSDL file(s)" ok
    } else {
        ::jtagid::gui::set_status [::jtagid::gui::T status_ready {ready}] normal
    }
    if {$S(done_var) ne ""} {
        set $S(done_var) 1
        set S(done_var) ""
    }
}

proc ::jtagid::gui::fill_devices {} {
    variable S
    variable H
    $H(devices) delete [$H(devices) children {}]
    foreach d $S(devices) {
        set decoded ""
        if {[lindex [dict get $d idcode] 0] ne ""} {
            set decoded "[dict get $d mfg] family=[dict get $d family] array=[dict get $d array]"
        }
        $H(devices) insert {} end -values [list [dict get $d name] [dict get $d part] \
            [dict get $d idcode] $decoded]
    }
}

proc ::jtagid::gui::fill_filters {} {
    variable S
    variable H
    set pkgs {}
    set models {}
    foreach c $S(candidates) {
        if {[lsearch -exact $pkgs [dict get $c package]] < 0} { lappend pkgs [dict get $c package] }
        foreach m [split [dict get $c models] /] {
            if {[lsearch -exact $models $m] < 0} { lappend models $m }
        }
    }
    $H(pkg) configure -values [concat [list [::jtagid::gui::T all {All}]] [lsort $pkgs]]
    $H(model) configure -values [concat [list [::jtagid::gui::T all {All}]] [lsort $models]]
}

proc ::jtagid::gui::apply_filters {} {
    variable S
    variable H
    set S(filter_pkg)   [$H(pkg) get]
    set S(filter_model) [$H(model) get]
    set S(filter_text)  [$H(keyword) get]
    set all [::jtagid::gui::T all {All}]
    $H(cand) delete [$H(cand) children {}]
    set shown 0
    foreach c $S(candidates) {
        if {$S(filter_pkg) ne "" && $S(filter_pkg) ne $all && \
            ![string equal -nocase [dict get $c package] $S(filter_pkg)]} { continue }
        if {$S(filter_model) ne "" && $S(filter_model) ne $all && \
            [lsearch -exact [split [dict get $c models] /] $S(filter_model)] < 0} { continue }
        if {$S(filter_text) ne "" && \
            ![string match -nocase "*$S(filter_text)*" [dict get $c path]] && \
            ![string match -nocase "*$S(filter_text)*" [dict get $c entity]] && \
            ![string match -nocase "*$S(filter_text)*" [dict get $c models]]} { continue }
        $H(cand) insert {} end -iid [dict get $c path] -values [list [dict get $c models] \
            [dict get $c package] [dict get $c irl] [dict get $c bsr] [file tail [dict get $c path]]]
        incr shown
    }
    ::jtagid::gui::log_line "filter -> $shown / [llength $S(candidates)] candidate(s)"
    return $shown
}

proc ::jtagid::gui::on_select {} {
    variable S
    variable H
    set sel [$H(cand) selection]
    if {[llength $sel] == 0} { return }
    set path [lindex $sel 0]
    foreach c $S(candidates) {
        if {[dict get $c path] ne $path} { continue }
        $H(selected) configure -state normal
        $H(selected) delete 0 end
        $H(selected) insert 0 $path
        $H(selected) configure -state readonly
        set S(selected) $path
        $H(details) configure -state normal
        $H(details) delete 1.0 end
        $H(details) insert end "entity   : [dict get $c entity]\n"
        $H(details) insert end "model    : [dict get $c models]\n"
        $H(details) insert end "package  : [dict get $c package]\n"
        $H(details) insert end "IRL      : [dict get $c irl] bits\n"
        $H(details) insert end "BSR      : [dict get $c bsr] cells ([dict get $c cells] parsed)\n"
        $H(details) insert end "file     : $path\n"
        $H(details) configure -state disabled
        # remember the choice for other scripts
        set dir [file join $::env(LOCALAPPDATA) jtag_identify]
        catch {file mkdir $dir}
        if {![catch {open [file join $dir selected_bsdl.txt] w} fh]} {
            puts $fh $path
            close $fh
        }
        return
    }
}

#==============================================================================
# actions
#==============================================================================

proc ::jtagid::gui::cancel_watchdog {} {
    variable S
    if {$S(watchdog) ne ""} { catch {after cancel $S(watchdog)}; set S(watchdog) "" }
}

proc ::jtagid::gui::arm_watchdog {ms} {
    variable S
    ::jtagid::gui::cancel_watchdog
    set S(watchdog) [after $ms {
        ::jtagid::gui::set_busy 0
        ::jtagid::gui::set_status "timeout waiting for the Vivado backend" error
        ::jtagid::gui::log_line "*** timeout ***"
    }]
}

proc ::jtagid::gui::do_identify {} {
    variable S
    variable H
    if {$S(busy)} { return }
    if {![::jtagid::gui::start_backend]} { return }
    ::jtagid::gui::set_busy 1
    set S(candidates) {}
    set S(selected) ""
    ::jtagid::gui::set_status "[::jtagid::gui::T status_identifying {identifying}] ..." busy
    ::jtagid::gui::log_line "--- identify ---"
    ::jtagid::gui::arm_watchdog 240000
    set bdir [$H(bsdl_dir_entry) get]
    set part [$H(part_entry) get]
    ::jtagid::gui::send_guarded [list \
        "::jtagid::cmd_report -bsdl-dir [list $bdir] -part [list $part]"]
}

proc ::jtagid::gui::do_scan {} {
    variable S
    if {$S(busy)} { return }
    if {![::jtagid::gui::start_backend]} { return }
    ::jtagid::gui::set_busy 1
    ::jtagid::gui::set_status "[::jtagid::gui::T btn_scan {Scan chain}] ..." busy
    ::jtagid::gui::arm_watchdog 180000
    ::jtagid::gui::send_guarded [list "puts \"INFO\\tscan\\t\[::jtagid::ensure_target\]\""]
}

proc ::jtagid::gui::do_reindex {} {
    variable S
    variable H
    if {$S(busy)} { return }
    if {![::jtagid::gui::start_backend]} { return }
    ::jtagid::gui::set_busy 1
    set bdir [$H(bsdl_dir_entry) get]
    ::jtagid::gui::set_status "[::jtagid::gui::T btn_reindex {Re-index}] ..." busy
    ::jtagid::gui::arm_watchdog 180000
    ::jtagid::gui::send_guarded [list \
        "set ::jtagid::state(bsdl_dir) [list [file normalize $bdir]]" \
        "puts \"INFO\\tbsdl_files\\t\[::jtagid::bsdl_index 1\]\""]
}

proc ::jtagid::gui::choose_dir {} {
    variable H
    set current [$H(bsdl_dir_entry) get]
    set dir [tk_chooseDirectory -title [::jtagid::gui::T btn_bsdl_dir {Choose BSDL directory}] \
                 -initialdir $current -mustexist 1]
    if {$dir eq ""} { return }
    $H(bsdl_dir_entry) delete 0 end
    $H(bsdl_dir_entry) insert 0 [file normalize $dir]
    ::jtagid::gui::do_reindex
}

proc ::jtagid::gui::copy_path {} {
    variable S
    if {$S(selected) eq ""} { return }
    clipboard clear
    clipboard append $S(selected)
    ::jtagid::gui::set_status [::jtagid::gui::T copied {path copied to clipboard}] ok
}

proc ::jtagid::gui::open_folder {} {
    variable S
    if {$S(selected) eq ""} { return }
    # native path: "/select,D:/x/y.bsd" (forward slashes) opens a "This PC"
    # window instead of the folder
    set native [file nativename [file normalize $S(selected)]]
    if {[file exists $native]} {
        catch {exec explorer.exe /select,$native &}
    } elseif {[file isdirectory [file dirname $native]]} {
        catch {exec explorer.exe [file dirname $native] &}
    }
}

#==============================================================================
# window
#==============================================================================

proc ::jtagid::gui::build {} {
    variable H
    variable S
    wm title . [::jtagid::gui::T app_title {jtagid - boundary scan FPGA identification}]
    wm minsize . 820 560
    ttk::style configure TButton -padding {8 3}
    ttk::style configure TLabel -padding {2 2}

    set top [ttk::frame .top]
    grid $top -row 0 -column 0 -sticky ew -padx 6 -pady 4
    set H(btn_identify) [ttk::button $top.b1 -text [::jtagid::gui::T btn_identify {Identify FPGA}] \
                             -command ::jtagid::gui::do_identify]
    set H(btn_scan)     [ttk::button $top.b2 -text [::jtagid::gui::T btn_scan {Scan chain}] \
                             -command ::jtagid::gui::do_scan]
    ttk::label $top.l0 -text [::jtagid::gui::T lbl_part {Part (optional)}]
    set H(part_entry) [ttk::entry $top.part -width 26]
    ttk::label $top.l1 -text [::jtagid::gui::T lbl_bsdl_dir {BSDL dir}]
    set H(bsdl_dir_entry) [ttk::entry $top.dir -width 46]
    set H(btn_choosedir) [ttk::button $top.b3 -text "..." -width 3 -command ::jtagid::gui::choose_dir]
    set H(btn_reindex)   [ttk::button $top.b4 -text [::jtagid::gui::T btn_reindex {Re-index}] \
                              -command ::jtagid::gui::do_reindex]
    grid $H(btn_identify) -row 0 -column 0 -padx 2
    grid $H(btn_scan)     -row 0 -column 1 -padx 2
    grid $top.l0           -row 0 -column 2 -padx {10 2}
    grid $H(part_entry)    -row 0 -column 3 -padx 2
    grid $top.l1           -row 1 -column 0 -padx 2 -pady {4 0} -sticky e
    grid $H(bsdl_dir_entry) -row 1 -column 1 -columnspan 3 -sticky ew -padx 2 -pady {4 0}
    grid $H(btn_choosedir) -row 1 -column 4 -padx 2 -pady {4 0}
    grid $H(btn_reindex)   -row 1 -column 5 -padx 2 -pady {4 0}
    grid columnconfigure $top 3 -weight 1

    set mid [ttk::labelframe .mid -text [::jtagid::gui::T lbl_chain {Devices on the JTAG chain}]]
    grid $mid -row 1 -column 0 -sticky nsew -padx 6 -pady 4
    set H(devices) [ttk::treeview $mid.tv -columns {device part idcode decoded} -show headings -height 4]
    foreach {c w} {device 130 part 110 idcode 100 decoded 320} {
        $H(devices) heading $c -text [::jtagid::gui::T col_$c $c]
        $H(devices) column $c -width $w -anchor w
    }
    grid $H(devices) -row 0 -column 0 -sticky nsew -padx 4 -pady 4

    set cand [ttk::labelframe .cand -text [::jtagid::gui::T lbl_candidates {BSDL candidates (filter and pick one)}]]
    grid $cand -row 2 -column 0 -sticky nsew -padx 6 -pady 4
    set f [ttk::frame $cand.f]
    grid $f -row 0 -column 0 -sticky ew -padx 4 -pady {4 2}
    ttk::label $f.l1 -text [::jtagid::gui::T lbl_package {Package}]
    set H(pkg) [ttk::combobox $f.pkg -state readonly -width 14]
    ttk::label $f.l2 -text [::jtagid::gui::T lbl_model {Model}]
    set H(model) [ttk::combobox $f.model -state readonly -width 16]
    ttk::label $f.l3 -text [::jtagid::gui::T lbl_keyword {Keyword}]
    set H(keyword) [ttk::entry $f.kw -width 22]
    set H(btn_clear) [ttk::button $f.clr -text [::jtagid::gui::T btn_clear {Clear}] \
                          -command {::jtagid::gui::clear_filters}]
    grid $f.l1 -row 0 -column 0; grid $H(pkg) -row 0 -column 1 -padx {2 8}
    grid $f.l2 -row 0 -column 2; grid $H(model) -row 0 -column 3 -padx {2 8}
    grid $f.l3 -row 0 -column 4; grid $H(keyword) -row 0 -column 5 -padx {2 8}
    grid $H(btn_clear) -row 0 -column 6 -padx 2
    bind $H(pkg) <<ComboboxSelected>> {::jtagid::gui::apply_filters}
    bind $H(model) <<ComboboxSelected>> {::jtagid::gui::apply_filters}
    bind $H(keyword) <KeyRelease> {::jtagid::gui::apply_filters}

    set H(cand) [ttk::treeview $cand.tv -columns {models package irl bsr file} -show headings \
                     -selectmode browse -height 9]
    foreach {c w} {models 150 package 90 irl 60 bsr 60 file 380} {
        $H(cand) heading $c -text [::jtagid::gui::T col_$c $c]
        $H(cand) column $c -width $w -anchor w
    }
    $H(cand) column bsr -anchor center
    $H(cand) column irl -anchor center
    grid $H(cand) -row 1 -column 0 -sticky nsew -padx 4 -pady 4
    bind $H(cand) <<TreeviewSelect>> {::jtagid::gui::on_select}

    set sel [ttk::frame .sel]
    grid $sel -row 3 -column 0 -sticky ew -padx 6 -pady {0 4}
    ttk::label $sel.l -text [::jtagid::gui::T lbl_selected {Selected BSDL}]
    set H(selected) [ttk::entry $sel.e -state readonly]
    set H(btn_copy) [ttk::button $sel.b1 -text [::jtagid::gui::T btn_copy {Copy path}] \
                         -command ::jtagid::gui::copy_path]
    set H(btn_open) [ttk::button $sel.b2 -text [::jtagid::gui::T btn_open {Open folder}] \
                         -command ::jtagid::gui::open_folder]
    grid $sel.l -row 0 -column 0
    grid $H(selected) -row 0 -column 1 -sticky ew -padx 4
    grid $H(btn_copy) -row 0 -column 2 -padx 2
    grid $H(btn_open) -row 0 -column 3 -padx 2
    grid columnconfigure $sel 1 -weight 1

    set H(details) [text .det -height 6 -wrap none -state disabled -font TkFixedFont]
    grid $H(details) -row 4 -column 0 -sticky nsew -padx 6 -pady {0 4}

    set H(log) [text .log -height 5 -wrap none -state disabled -font TkFixedFont -background "#f7f7f7"]
    grid $H(log) -row 5 -column 0 -sticky nsew -padx 6 -pady {0 4}

    set H(status) [ttk::label .st -text [::jtagid::gui::T status_ready {ready}] -anchor w]
    grid $H(status) -row 6 -column 0 -sticky ew -padx 8 -pady {0 6}

    grid rowconfigure . 2 -weight 1
    grid rowconfigure . 4 -weight 0
    grid rowconfigure . 5 -weight 0
    grid columnconfigure . 0 -weight 1
    wm protocol . WM_DELETE_WINDOW ::jtagid::gui::on_close
    return
}

proc ::jtagid::gui::clear_filters {} {
    variable H
    $H(pkg) set [::jtagid::gui::T all {All}]
    $H(model) set [::jtagid::gui::T all {All}]
    $H(keyword) delete 0 end
    ::jtagid::gui::apply_filters
}

proc ::jtagid::gui::on_close {} {
    variable S
    if {$S(chan) ne ""} {
        catch {puts $S(chan) "exit"}
        catch {flush $S(chan)}
        if {$S(pid) ne ""} { catch {exec taskkill /PID $S(pid) /T /F > NUL 2> NUL} }
        catch {close $S(chan)}
    }
    catch {destroy .}
    return
}

#==============================================================================
# entry point
#==============================================================================

proc ::jtagid::gui::st {text} {
    # selftest trace: write to a file so nothing depends on stdout redirection
    if {![info exists ::env(TEMP)]} { return }
    if {[catch {open [file join $::env(TEMP) jtagid_gui_selftest.txt] a} f]} { return }
    fconfigure $f -encoding utf-8 -buffering line
    puts $f $text
    close $f
}

proc ::jtagid::gui::selftest {} {
    if {[catch {::jtagid::gui::selftest_body} err opts]} {
        ::jtagid::gui::st "SELFTEST|EXCEPTION|$err"
        if {[dict exists $opts -errorinfo]} {
            foreach l [split [dict get $opts -errorinfo] "\n"] { ::jtagid::gui::st "SELFTEST|TRACE|$l" }
        }
        puts "SELFTEST|EXCEPTION|$err"
        exit 1
    }
    exit 0
}

proc ::jtagid::gui::selftest_body {} {
    variable S
    variable H
    set S(debug) 1
    ::jtagid::gui::st "SELFTEST|begin"
    ::jtagid::gui::build
    ::jtagid::gui::st "SELFTEST|built"
    wm withdraw .
    set S(done_var) ::jtagid::gui::S(selftest_done)
    set S(selftest_done) 0
    if {![::jtagid::gui::start_backend]} { ::jtagid::gui::st "SELFTEST|FAIL|backend"; return }
    ::jtagid::gui::st "SELFTEST|backend_spawned|$S(vivado)"
    # wait for the backend to be ready
    set waited 0
    while {!$S(started) && $waited < 90000} { update; after 200; incr waited 200 }
    ::jtagid::gui::st "SELFTEST|backend_ready|$S(started)|waited=${waited}ms"
    if {!$S(started)} { return }
    ::jtagid::gui::do_identify
    set waited 0
    while {!$S(selftest_done) && $waited < 240000} { update; after 200; incr waited 200 }
    ::jtagid::gui::st "SELFTEST|devices|[llength $S(devices)]"
    puts "SELFTEST|devices|[llength $S(devices)]"
    foreach d $S(devices) {
        ::jtagid::gui::st "SELFTEST|DEV|[dict get $d name]|[dict get $d part]|[dict get $d idcode]"
        puts "SELFTEST|DEV|[dict get $d name]|[dict get $d part]|[dict get $d idcode]"
    }
    ::jtagid::gui::st "SELFTEST|candidates|[llength $S(candidates)]"
    puts "SELFTEST|candidates|[llength $S(candidates)]"
    foreach c $S(candidates) {
        set row "[dict get $c models]|[dict get $c package]|[dict get $c irl]|[dict get $c bsr]|[file tail [dict get $c path]]"
        ::jtagid::gui::st "SELFTEST|CAND|$row"
        puts "SELFTEST|CAND|$row"
    }
    $H(pkg) set SFVC784
    set shown [::jtagid::gui::apply_filters]
    ::jtagid::gui::st "SELFTEST|filter_SFVC784|$shown"
    puts "SELFTEST|filter_SFVC784|$shown"
    $H(pkg) set [::jtagid::gui::T all {All}]
    $H(model) set XCZU3EG
    set shown2 [::jtagid::gui::apply_filters]
    ::jtagid::gui::st "SELFTEST|filter_XCZU3EG|$shown2"
    puts "SELFTEST|filter_XCZU3EG|$shown2"
    $H(keyword) delete 0 end
    $H(keyword) insert 0 xczu3eg_sfvc784
    set shown3 [::jtagid::gui::apply_filters]
    ::jtagid::gui::st "SELFTEST|filter_keyword|$shown3"
    puts "SELFTEST|filter_keyword|$shown3"
    # selection must fill the details pane and remember the choice
    set first [$H(cand) children {}]
    if {[llength $first] > 0} {
        $H(cand) selection set [lindex $first 0]
        ::jtagid::gui::on_select
        ::jtagid::gui::st "SELFTEST|selected|$S(selected)"
        puts "SELFTEST|selected|$S(selected)"
    }
    ::jtagid::gui::st "SELFTEST|widgets|[winfo class $H(cand)]|[winfo class $H(devices)]|[winfo class $H(pkg)]"
    puts "SELFTEST|widgets|[winfo class $H(cand)]|[winfo class $H(devices)]|[winfo class $H(pkg)]"
    ::jtagid::gui::on_close
    return
}

proc ::jtagid::gui::main {} {
    ::jtagid::gui::load_msgs
    if {[lsearch -exact $::argv "-selftest"] >= 0} {
        ::jtagid::gui::selftest
        return
    }
    ::jtagid::gui::build
    ::jtagid::gui::set_status [::jtagid::gui::T status_ready {ready}] normal
    ::jtagid::gui::log_line "jtagid GUI -- [::jtagid::gui::T hint_start {press "Identify FPGA"}]"
    return
}

::jtagid::gui::main
