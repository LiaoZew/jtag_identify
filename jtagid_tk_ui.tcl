###############################################################################
# jtagid_tk_ui.tcl -- the jtagid GUI window (Tk widgets).
#
# This file is not sourced by Vivado directly: Vivado side (jtagid_tk_gui.tcl)
# reads it, sends it through Xilinx's tk_tunnel bridge, and it is evaluated in
# the Tk shell.  Everything here therefore runs in the Tk process:
#
#   buttons/entries/filters  -> local Tk code
#   "identify" / "scan" ...  -> broadcast back to Vivado, which owns the cable
#
# Display strings come from jtagid_gui_msgs.txt (UTF-8, key<TAB>text) so this
# file can stay pure ASCII (Vivado decodes sourced files with the system code
# page, and the bridge transports lines as ASCII).
#
# 2026-10
###############################################################################

namespace eval ::jtagid::tkgui {
    variable S
    variable H
    variable MSG
    array set S {
        devices    {}
        candidates {}
        selected   ""
        busy       0
        ready      0
        watchdog   ""
        f_pkg      ""
        f_model    ""
        f_text     ""
    }
    array set MSG {}
}

#==============================================================================
# display strings
#==============================================================================

proc ::jtagid::tkgui::load_msgs {} {
    variable MSG
    array set MSG {}
    set file ""
    if {[info exists ::env(JTAGID_MSGS)]} { set file $::env(JTAGID_MSGS) }
    if {$file eq "" || ![file exists $file]} { return 0 }
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

proc ::jtagid::tkgui::L {key default} {
    variable MSG
    if {[info exists MSG($key)]} { return $MSG($key) }
    return $default
}

proc ::jtagid::tkgui::remote {cmd} {
    # run a command back in Vivado (button clicks end up in the driver there)
    catch {::tclapp::xilinx::tk_tunnel::broadcast $cmd} err
    return $err
}

#==============================================================================
# window
#==============================================================================

proc ::jtagid::tkgui::set_status {text {kind normal}} {
    variable H
    if {![winfo exists $H(status)]} { return }
    $H(status) configure -text $text
    switch -- $kind {
        error { $H(status) configure -foreground "#b00020" }
        ok    { $H(status) configure -foreground "#137333" }
        busy  { $H(status) configure -foreground "#9a6700" }
        default { $H(status) configure -foreground "#374151" }
    }
    update idletasks
    return
}

proc ::jtagid::tkgui::set_busy {flag {timeout 60000}} {
    variable S
    variable H
    set S(busy) $flag
    catch {after cancel $S(watchdog)}
    set S(watchdog) ""
    if {$flag} {
        # if Vivado never answers, say so instead of waiting forever: the plain
        # "vivado -mode tcl" REPL does not service the window at all.
        set S(watchdog) [after $timeout ::jtagid::tkgui::backend_timeout]
    }
    set state [expr {$flag ? "disabled" : "normal"}]
    foreach b {identify scan reindex} {
        catch {$H(btn_$b) configure -state $state}
    }
    return
}

proc ::jtagid::tkgui::backend_timeout {} {
    variable S
    if {!$S(busy)} { return }
    ::jtagid::tkgui::set_busy 0
    ::jtagid::tkgui::set_status \
        [::jtagid::tkgui::L status_nobackend \
             {no answer from Vivado - source this in the Vivado IDE Tcl console (the plain "-mode tcl" shell does not serve the window)}] \
        error
    return
}

proc ::jtagid::tkgui::handshake_timeout {} {
    variable S
    if {$S(ready)} { return }
    ::jtagid::tkgui::set_status \
        [::jtagid::tkgui::L status_nobackend \
             {no answer from Vivado - source this in the Vivado IDE Tcl console (the plain "-mode tcl" shell does not serve the window)}] \
        error
    return
}

proc ::jtagid::tkgui::backend_ready {} {
    variable S
    set S(ready) 1
    ::jtagid::tkgui::set_status \
        [::jtagid::tkgui::L status_backend_ok {Vivado backend ready - identifying}] ok
    after 100 [list ::jtagid::tkgui::do_identify]
    return
}

proc ::jtagid::tkgui::show {} {
    if {![winfo exists .g]} { catch {::jtagid::tkgui::build} }
    catch {wm deiconify .g}
    catch {raise .g}
    catch {focus .g}
    return
}

proc ::jtagid::tkgui::quit_app {} {
    catch {::jtagid::tkgui::remote {::jtagid::tkhost::cmd_window_closed}}
    catch {destroy .g}
    # let the broadcast reach Vivado before the socket goes away
    after 250 { catch {exit} }
    return
}

proc ::jtagid::tkgui::build {} {
    variable H
    variable S
    set w .g
    catch {destroy $w}
    toplevel $w
    wm title $w [::jtagid::tkgui::L win_title {jtagid - boundary scan FPGA identification}]
    wm minsize $w 900 620
    wm geometry $w 1020x740
    wm protocol $w WM_DELETE_WINDOW ::jtagid::tkgui::do_close

    set top [ttk::frame $w.top]
    grid $top -row 0 -column 0 -sticky ew -padx 8 -pady 6
    set H(btn_identify) [ttk::button $top.b1 -text [::jtagid::tkgui::L btn_identify {Identify FPGA}] \
                             -command ::jtagid::tkgui::do_identify]
    set H(btn_scan)     [ttk::button $top.b2 -text [::jtagid::tkgui::L btn_scan {Scan chain}] \
                             -command ::jtagid::tkgui::do_scan]
    set H(btn_reindex)  [ttk::button $top.b3 -text [::jtagid::tkgui::L btn_reindex {Re-index}] \
                             -command ::jtagid::tkgui::do_reindex]
    set H(btn_close)    [ttk::button $top.b4 -text [::jtagid::tkgui::L btn_close {Close}] \
                             -command ::jtagid::tkgui::do_close]
    ttk::label $top.l0 -text [::jtagid::tkgui::L lbl_bsdl_dir {BSDL dir}]
    set H(dir) [ttk::entry $top.dir -width 52]
    ttk::button $top.pick -text "..." -width 3 -command ::jtagid::tkgui::do_choose_dir
    ttk::label $top.l1 -text [::jtagid::tkgui::L lbl_pkg_hint {Package}]
    set H(pkg) [ttk::entry $top.pkg -width 10]
    ttk::label $top.l2 -text [::jtagid::tkgui::L lbl_part {Part}]
    set H(part) [ttk::entry $top.part -width 22]
    grid $H(btn_identify) -row 0 -column 0 -padx 2
    grid $H(btn_scan)     -row 0 -column 1 -padx 2
    grid $H(btn_reindex)  -row 0 -column 2 -padx 2
    grid $H(btn_close)    -row 0 -column 8 -padx 2 -sticky e
    grid $top.l0           -row 1 -column 0 -sticky e -pady {6 0}
    grid $H(dir)           -row 1 -column 1 -columnspan 3 -sticky ew -pady {6 0}
    grid $top.pick         -row 1 -column 4 -pady {6 0}
    grid $top.l1           -row 1 -column 5 -sticky e -padx {8 2} -pady {6 0}
    grid $H(pkg)           -row 1 -column 6 -sticky w -pady {6 0}
    grid $top.l2           -row 1 -column 7 -sticky e -padx {8 2} -pady {6 0}
    grid $H(part)          -row 1 -column 9 -sticky w -pady {6 0}
    grid columnconfigure $top 3 -weight 1

    set dev [ttk::labelframe $w.dev -text [::jtagid::tkgui::L lbl_chain {Devices on the JTAG chain}]]
    grid $dev -row 1 -column 0 -sticky nsew -padx 8 -pady 4
    set H(devtv) [ttk::treeview $dev.tv -columns {name part idcode decoded} -show headings -height 4]
    foreach {c width} {name 150 part 110 idcode 110 decoded 420} {
        $H(devtv) heading $c -text [::jtagid::tkgui::L col_$c $c]
        $H(devtv) column $c -width $width -anchor w
    }
    grid $H(devtv) -row 0 -column 0 -sticky nsew -padx 4 -pady 4

    set cand [ttk::labelframe $w.cand -text [::jtagid::tkgui::L lbl_candidates {BSDL candidates - filter, then click a row}]]
    grid $cand -row 2 -column 0 -sticky nsew -padx 8 -pady 4
    set f [ttk::frame $cand.f]
    grid $f -row 0 -column 0 -sticky ew -padx 4 -pady {4 2}
    ttk::label $f.l1 -text [::jtagid::tkgui::L lbl_package {Package}]
    set H(fpkg) [ttk::combobox $f.pkg -state readonly -width 14]
    ttk::label $f.l2 -text [::jtagid::tkgui::L lbl_model {Model}]
    set H(fmodel) [ttk::combobox $f.model -state readonly -width 18]
    ttk::label $f.l3 -text [::jtagid::tkgui::L lbl_keyword {Keyword}]
    set H(ftext) [ttk::entry $f.kw -width 24]
    ttk::button $f.clr -text [::jtagid::tkgui::L btn_clear {Clear}] \
        -command {::jtagid::tkgui::clear_filters}
    set H(count) [ttk::label $f.n -text ""]
    grid $f.l1 -row 0 -column 0; grid $H(fpkg) -row 0 -column 1 -padx {2 10}
    grid $f.l2 -row 0 -column 2; grid $H(fmodel) -row 0 -column 3 -padx {2 10}
    grid $f.l3 -row 0 -column 4; grid $H(ftext) -row 0 -column 5 -padx {2 10}
    grid $f.clr -row 0 -column 6 -padx 2
    grid $H(count) -row 0 -column 7 -padx 8
    bind $H(fpkg) <<ComboboxSelected>> {::jtagid::tkgui::apply_filters}
    bind $H(fmodel) <<ComboboxSelected>> {::jtagid::tkgui::apply_filters}
    bind $H(ftext) <KeyRelease> {::jtagid::tkgui::apply_filters}

    set H(candtv) [ttk::treeview $cand.tv -columns {models package irl bsr cells file} \
                       -show headings -selectmode browse -height 9]
    foreach {c width} {models 170 package 100 irl 60 bsr 60 cells 70 file 380} {
        $H(candtv) heading $c -text [::jtagid::tkgui::L col_$c $c]
        $H(candtv) column $c -width $width -anchor w
    }
    $H(candtv) column irl -anchor center
    $H(candtv) column bsr -anchor center
    $H(candtv) column cells -anchor center
    set sb [ttk::scrollbar $cand.sb -orient vertical -command "$H(candtv) yview"]
    $H(candtv) configure -yscrollcommand "$sb set"
    grid $H(candtv) -row 1 -column 0 -sticky nsew -padx 4 -pady 4
    grid $sb -row 1 -column 1 -sticky ns -pady 4
    bind $H(candtv) <<TreeviewSelect>> {::jtagid::tkgui::on_select}

    set sel [ttk::frame $w.sel]
    grid $sel -row 3 -column 0 -sticky ew -padx 8 -pady {0 4}
    ttk::label $sel.l -text [::jtagid::tkgui::L lbl_selected {Selected BSDL}]
    set H(selected) [ttk::entry $sel.e -state readonly]
    ttk::button $sel.b1 -text [::jtagid::tkgui::L btn_copy {Copy path}] \
        -command ::jtagid::tkgui::copy_path
    ttk::button $sel.b2 -text [::jtagid::tkgui::L btn_open {Open folder}] \
        -command ::jtagid::tkgui::open_folder
    grid $sel.l -row 0 -column 0
    grid $H(selected) -row 0 -column 1 -sticky ew -padx 4
    grid $sel.b1 -row 0 -column 2 -padx 2
    grid $sel.b2 -row 0 -column 3 -padx 2
    grid columnconfigure $sel 1 -weight 1

    set H(details) [text $w.det -height 6 -wrap none -state disabled -font TkFixedFont]
    grid $H(details) -row 4 -column 0 -sticky nsew -padx 8 -pady {0 4}

    set H(env) [ttk::label $w.env -text "" -anchor w]
    grid $H(env) -row 5 -column 0 -sticky ew -padx 10
    set H(status) [ttk::label $w.st -text [::jtagid::tkgui::L status_ready {ready}] -anchor w]
    grid $H(status) -row 6 -column 0 -sticky ew -padx 10 -pady {0 8}

    grid rowconfigure $w 2 -weight 1
    grid columnconfigure $w 0 -weight 1
    return $w
}

#==============================================================================
# data pushed in by Vivado
#==============================================================================

proc ::jtagid::tkgui::set_env {text} {
    variable H
    if {[winfo exists $H(env)]} { $H(env) configure -text $text }
    return
}

proc ::jtagid::tkgui::dget {d key {default ""}} {
    # never throw on a missing key: a redraw that throws used to leave the
    # window stuck in its busy state (buttons disabled, no reply shown)
    if {[catch {dict exists $d $key} have]} { return $default }
    if {$have} { return [dict get $d $key] }
    return $default
}

proc ::jtagid::tkgui::show_error {text} {
    ::jtagid::tkgui::set_busy 0
    ::jtagid::tkgui::set_status "[::jtagid::tkgui::L status_failed {failed}]: $text" error
    return
}

proc ::jtagid::tkgui::render {} {
    # safety net: whatever the backend sends, the window must end up usable
    if {[catch {::jtagid::tkgui::render_raw} err]} {
        ::jtagid::tkgui::show_error "redraw failed: $err"
    }
    return
}

proc ::jtagid::tkgui::render_raw {} {
    variable S
    variable H
    if {![info exists ::jtagid::tkgui::DATA]} { return }
    set data $::jtagid::tkgui::DATA
    # environment line
    if {[dict exists $data env]} { ::jtagid::tkgui::set_env [dict get $data env] }
    # devices
    $H(devtv) delete [$H(devtv) children {}]
    foreach d [::jtagid::tkgui::dget $data devices {}] {
        set idcode [::jtagid::tkgui::dget $d idcode]
        set decoded ""
        if {$idcode ne ""} {
            set decoded "[::jtagid::tkgui::dget $d mfg] family=[::jtagid::tkgui::dget $d family] array=[::jtagid::tkgui::dget $d array]"
            if {[::jtagid::tkgui::dget $d fpga] eq "1"} { append decoded "  [::jtagid::tkgui::L tag_fpga {Xilinx FPGA}]" }
        }
        $H(devtv) insert {} end -values [list [::jtagid::tkgui::dget $d name] \
            [::jtagid::tkgui::dget $d part] $idcode $decoded]
    }
    # candidates
    set norm {}
    foreach c [::jtagid::tkgui::dget $data candidates {}] {
        lappend norm [::jtagid::tkgui::norm_cand $c]
    }
    set S(candidates) $norm
    set sel [::jtagid::tkgui::dget $data selected]
    if {$sel ne ""} {
        set S(selected) $sel
        $H(selected) configure -state normal
        $H(selected) delete 0 end
        $H(selected) insert 0 $S(selected)
        $H(selected) configure -state readonly
    }
    ::jtagid::tkgui::fill_filters
    ::jtagid::tkgui::apply_filters
    ::jtagid::tkgui::set_busy 0
    set errors [::jtagid::tkgui::dget $data errors {}]
    if {[llength $errors] > 0} {
        ::jtagid::tkgui::set_status "[::jtagid::tkgui::L status_failed {failed}]: [join $errors { | }]" error
    } else {
        set msg "[::jtagid::tkgui::L status_done {done}]: [llength [::jtagid::tkgui::dget $data devices {}]] TAP, [llength $S(candidates)] BSDL"
        set part [::jtagid::tkgui::dget $data part]
        if {$part ne ""} {
            append msg "  |  [::jtagid::tkgui::dget $part given] -> [::jtagid::tkgui::dget $part matched] ([::jtagid::tkgui::dget $part message])"
        }
        ::jtagid::tkgui::set_status $msg ok
    }
    return
}

#==============================================================================
# filtering
#==============================================================================

proc ::jtagid::tkgui::norm_cand {c} {
    # give every candidate the full key set the window reads, so a short record
    # can never break a redraw
    set path [::jtagid::tkgui::dget $c path]
    set file [::jtagid::tkgui::dget $c file]
    if {$file eq ""} { set file [file tail $path] }
    return [dict create \
        path    $path \
        file    $file \
        entity  [::jtagid::tkgui::dget $c entity] \
        models  [::jtagid::tkgui::dget $c models] \
        package [::jtagid::tkgui::dget $c package] \
        irl     [::jtagid::tkgui::dget $c irl] \
        bsr     [::jtagid::tkgui::dget $c bsr] \
        cells   [::jtagid::tkgui::dget $c cells]]
}

proc ::jtagid::tkgui::fill_filters {} {
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
    set all [::jtagid::tkgui::L all {All}]
    $H(fpkg) configure -values [concat [list $all] [lsort $pkgs]]
    $H(fmodel) configure -values [concat [list $all] [lsort $models]]
    # honour the package hint that was typed before identifying
    set hint [string trim [$H(pkg) get]]
    if {$hint ne "" && [lsearch -exact $pkgs $hint] >= 0} {
        $H(fpkg) set $hint
    } elseif {[$H(fpkg) get] eq ""} {
        $H(fpkg) set $all
    }
    if {[$H(fmodel) get] eq ""} { $H(fmodel) set $all }
    return
}

proc ::jtagid::tkgui::clear_filters {} {
    variable H
    $H(fpkg) set [::jtagid::tkgui::L all {All}]
    $H(fmodel) set [::jtagid::tkgui::L all {All}]
    $H(ftext) delete 0 end
    ::jtagid::tkgui::apply_filters
    return
}

proc ::jtagid::tkgui::apply_filters {} {
    variable S
    variable H
    if {![winfo exists $H(candtv)]} { return 0 }
    set all [::jtagid::tkgui::L all {All}]
    set pkg [$H(fpkg) get]
    set model [$H(fmodel) get]
    set text [string tolower [string trim [$H(ftext) get]]]
    $H(candtv) delete [$H(candtv) children {}]
    set shown 0
    foreach c $S(candidates) {
        if {$pkg ne "" && $pkg ne $all && [string equal -nocase [dict get $c package] $pkg] == 0} { continue }
        if {$model ne "" && $model ne $all} {
            set hit 0
            foreach m [split [dict get $c models] /] {
                if {[string equal -nocase $m $model]} { set hit 1 }
            }
            if {!$hit} { continue }
        }
        if {$text ne ""} {
            set hay [string tolower "[dict get $c path] [dict get $c entity] [dict get $c models] [dict get $c package]"]
            if {[string first $text $hay] < 0} { continue }
        }
        $H(candtv) insert {} end -id [dict get $c path] -values [list [dict get $c models] \
            [dict get $c package] [dict get $c irl] [dict get $c bsr] [dict get $c cells] \
            [dict get $c file]]
        if {[dict get $c path] eq $S(selected)} {
            catch {$H(candtv) selection set [dict get $c path]}
        }
        incr shown
    }
    $H(count) configure -text "$shown / [llength $S(candidates)]"
    return $shown
}

#==============================================================================
# actions
#==============================================================================

proc ::jtagid::tkgui::do_identify {} {
    variable S
    variable H
    if {$S(busy)} { return }
    ::jtagid::tkgui::set_busy 1
    ::jtagid::tkgui::set_status [::jtagid::tkgui::L status_identifying {identifying - reading IDCODE and looking up BSDL}] busy
    set dir  [string trim [$H(dir) get]]
    set pkg  [string trim [$H(pkg) get]]
    set part [string trim [$H(part) get]]
    ::jtagid::tkgui::remote [list ::jtagid::tkhost::cmd_identify $dir $pkg $part]
    return
}

proc ::jtagid::tkgui::do_scan {} {
    variable S
    if {$S(busy)} { return }
    ::jtagid::tkgui::set_busy 1
    ::jtagid::tkgui::set_status [::jtagid::tkgui::L status_scanning {scanning the chain}] busy
    ::jtagid::tkgui::remote {::jtagid::tkhost::cmd_scan}
    return
}

proc ::jtagid::tkgui::do_reindex {} {
    variable S
    variable H
    if {$S(busy)} { return }
    ::jtagid::tkgui::set_busy 1 300000
    ::jtagid::tkgui::set_status [::jtagid::tkgui::L status_indexing {re-building the BSDL index}] busy
    ::jtagid::tkgui::remote [list ::jtagid::tkhost::cmd_reindex [string trim [$H(dir) get]]]
    return
}

proc ::jtagid::tkgui::do_choose_dir {} {
    variable H
    set start [string trim [$H(dir) get]]
    if {$start eq "" || ![file isdirectory $start]} { set start [pwd] }
    set answer [tk_chooseDirectory -title [::jtagid::tkgui::L btn_choose_dir {Choose the BSDL directory}] \
                    -initialdir $start -mustexist 1]
    if {$answer eq ""} { return }
    $H(dir) delete 0 end
    $H(dir) insert 0 [string map {\\ /} $answer]
    return
}

proc ::jtagid::tkgui::show_details {c} {
    variable H
    $H(details) configure -state normal
    $H(details) delete 1.0 end
    $H(details) insert end "entity   : [dict get $c entity]\n"
    $H(details) insert end "model    : [dict get $c models]\n"
    $H(details) insert end "package  : [dict get $c package]\n"
    $H(details) insert end "IRL      : [dict get $c irl] bit\n"
    $H(details) insert end "BSR      : [dict get $c bsr] cells\n"
    $H(details) insert end "file     : [dict get $c path]\n"
    $H(details) configure -state disabled
    return
}

proc ::jtagid::tkgui::on_select {} {
    variable S
    variable H
    set sel [$H(candtv) selection]
    if {[llength $sel] == 0} { return }
    set path [lindex $sel 0]
    foreach c $S(candidates) {
        if {[dict get $c path] ne $path} { continue }
        set S(selected) $path
        $H(selected) configure -state normal
        $H(selected) delete 0 end
        $H(selected) insert 0 $path
        $H(selected) configure -state readonly
        ::jtagid::tkgui::show_details $c
        ::jtagid::tkgui::set_status "[::jtagid::tkgui::L status_selected {selected}] [dict get $c file]" ok
        ::jtagid::tkgui::remote [list ::jtagid::tkhost::cmd_select $path]
        return
    }
    return
}

proc ::jtagid::tkgui::copy_path {} {
    variable S
    if {$S(selected) eq ""} { return }
    clipboard clear
    clipboard append $S(selected)
    ::jtagid::tkgui::set_status [::jtagid::tkgui::L status_copied {path copied to the clipboard}] ok
    return
}

proc ::jtagid::tkgui::open_folder {} {
    variable S
    if {$S(selected) eq ""} { return }
    catch {exec {*}[list explorer.exe /select,$S(selected)]}
    return
}

proc ::jtagid::tkgui::do_close {} {
    # closing the window only hides it: the Vivado backend keeps running, and
    # "jtagid gui" (or right-clicking jtagid_tk.cmd again) brings it straight
    # back without re-reading the JTAG chain.
    ::jtagid::tkgui::remote {::jtagid::tkhost::cmd_window_closed}
    catch {wm withdraw .g}
    return
}

proc ::jtagid::tkgui::do_quit_app {} {
    ::jtagid::tkgui::quit_app
    return
}

#==============================================================================
# start
#==============================================================================

::jtagid::tkgui::load_msgs
::jtagid::tkgui::build
catch {bind .g <Control-q> {::jtagid::tkgui::quit_app}}
::jtagid::tkgui::set_status \
    [::jtagid::tkgui::L status_waiting {talking to the Vivado backend...}] busy
# Tell the backend the window is up.  It answers with backend_ready, and THAT is
# what starts the automatic identify - so nothing long ever runs while Vivado is
# still sourcing the front end file (the console gets its prompt back first).
after 50 { catch {::jtagid::tkgui::remote {::jtagid::tkhost::cmd_hello}} }
after 8000 { catch {::jtagid::tkgui::handshake_timeout} }
