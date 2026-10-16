###############################################################################
# jtagid_tk_ui.tcl -- the jtagid GUI window (Tk widgets).
#
# This file is not sourced by Vivado directly: Vivado side (jtagid_tk_gui.tcl)
# reads it, sends it through Xilinx's tk_tunnel bridge, and it is evaluated in
# the Tk shell.  Everything here therefore runs in the Tk process:
#
#   main window            -> one button: identify the FPGA, plus the binding
#   chooser dialog         -> find the BSDL (all filters) and bind it
#   buttons/filters        -> local Tk code
#   "identify" / "bind"    -> broadcast back to Vivado, which owns the cable
#
# Flow: identify -> the chooser opens with every candidate -> pick a row ->
# "use this BSDL" stores device <-> BSDL in bindings.txt (the backend writes it,
# so "jtagid bsdl-for" prints the bound path later).
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
    variable P
    array set S {
        devices    {}
        candidates {}
        selected   ""
        bound      {}
        sku        {}
        busy       0
        ready      0
        watchdog   ""
        t0         0
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

proc ::jtagid::tkgui::dget {d key {default ""}} {
    # never throw on a missing key: a redraw that throws used to leave the
    # window stuck in its busy state (buttons disabled, no reply shown)
    if {[catch {dict exists $d $key} have]} { return $default }
    if {$have} { return [dict get $d $key] }
    return $default
}

#==============================================================================
# window helpers
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

proc ::jtagid::tkgui::center_window {w} {
    update idletasks
    set width  [winfo reqwidth $w]
    set height [winfo reqheight $w]
    catch {regexp {^(\d+)x(\d+)} [wm geometry $w] -> width height}
    if {$width < 100}  { set width 1020 }
    if {$height < 100} { set height 740 }
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set x [expr {($sw - $width) / 2}]
    set y [expr {($sh - $height) / 3}]
    if {$x < 0} { set x 0 }
    if {$y < 0} { set y 0 }
    catch {wm geometry $w "+$x+$y"}
    return
}

proc ::jtagid::tkgui::pop_up {w} {
    # just bring the window up when it is shown: deiconify, raise, take the
    # keyboard focus.  No topmost games - the window behaves normally after this.
    if {![winfo exists $w]} { return }
    catch {wm deiconify $w}
    catch {raise $w}
    catch {focus -force $w}
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
    foreach b {identify} {
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
    ::jtagid::tkgui::pop_up .g
    return
}

proc ::jtagid::tkgui::quit_app {} {
    catch {::jtagid::tkgui::remote {::jtagid::tkhost::cmd_window_closed}}
    catch {destroy .g}
    # let the broadcast reach Vivado before the socket goes away
    after 250 { catch {exit} }
    return
}

proc ::jtagid::tkgui::do_quit_app {} {
    ::jtagid::tkgui::quit_app
    return
}

#==============================================================================
# main window: identify the FPGA, show the binding
#==============================================================================

proc ::jtagid::tkgui::build {} {
    variable H
    variable S
    set w .g
    catch {destroy $w}
    toplevel $w
    wm withdraw $w      ;# placed centrally and shown by pop_up
    wm title $w [::jtagid::tkgui::L win_title {jtagid - boundary scan FPGA identification}]
    wm minsize $w 880 420
    wm geometry $w 900x420
    wm protocol $w WM_DELETE_WINDOW ::jtagid::tkgui::do_close

    set top [ttk::frame $w.top]
    grid $top -row 0 -column 0 -sticky ew -padx 8 -pady 6
    set H(btn_identify) [ttk::button $top.b1 -text [::jtagid::tkgui::L btn_identify {Identify FPGA}] \
                             -command ::jtagid::tkgui::do_identify]
    set H(btn_close) [ttk::button $top.b2 -text [::jtagid::tkgui::L btn_close {Close}] \
                          -command ::jtagid::tkgui::do_close]
    ttk::label $top.l0 -text [::jtagid::tkgui::L lbl_bsdl_dir {BSDL dir}]
    set H(dir) [ttk::entry $top.dir -width 44]
    ttk::button $top.pick -text "..." -width 3 -command ::jtagid::tkgui::do_choose_dir
    ttk::label $top.l1 -text [::jtagid::tkgui::L lbl_pkg_hint {Package}]
    set H(pkg) [ttk::entry $top.pkg -width 10]
    ttk::label $top.l2 -text [::jtagid::tkgui::L lbl_part {Part}]
    set H(part) [ttk::entry $top.part -width 22]
    grid $H(btn_identify) -row 0 -column 0 -padx 2
    grid $H(btn_close)    -row 0 -column 7 -padx 2 -sticky e
    grid $top.l0           -row 1 -column 0 -sticky e -pady {6 0}
    grid $H(dir)           -row 1 -column 1 -columnspan 2 -sticky ew -pady {6 0}
    grid $top.pick         -row 1 -column 3 -pady {6 0}
    grid $top.l1           -row 1 -column 4 -sticky e -padx {8 2} -pady {6 0}
    grid $H(pkg)           -row 1 -column 5 -sticky w -pady {6 0}
    grid $top.l2           -row 1 -column 6 -sticky e -padx {8 2} -pady {6 0}
    grid $H(part)          -row 1 -column 7 -sticky w -pady {6 0}
    grid columnconfigure $top 2 -weight 1

    set dev [ttk::labelframe $w.dev -text [::jtagid::tkgui::L lbl_chain {Devices on the JTAG chain}]]
    grid $dev -row 1 -column 0 -sticky nsew -padx 8 -pady 4
    set H(devtv) [ttk::treeview $dev.tv -columns {name part idcode decoded} -show headings -height 4]
    foreach {c width} {name 130 part 100 idcode 110 decoded 420} {
        $H(devtv) heading $c -text [::jtagid::tkgui::L col_$c $c]
        $H(devtv) column $c -width $width -anchor w
    }
    grid $H(devtv) -row 0 -column 0 -sticky nsew -padx 4 -pady 4

    set bd [ttk::labelframe $w.bd -text [::jtagid::tkgui::L lbl_bound {Bound device <-> BSDL}]]
    grid $bd -row 2 -column 0 -sticky ew -padx 8 -pady 4
    set H(bound) [ttk::entry $bd.e -state readonly]
    set H(btn_rechoose) [ttk::button $bd.b1 -text [::jtagid::tkgui::L btn_rechoose {Choose BSDL}] \
                             -command ::jtagid::tkgui::do_pick_bsdl]
    ttk::button $bd.b2 -text [::jtagid::tkgui::L btn_copy {Copy path}] \
        -command ::jtagid::tkgui::copy_path
    ttk::button $bd.b3 -text [::jtagid::tkgui::L btn_open {Open folder}] \
        -command ::jtagid::tkgui::open_folder
    grid $H(bound) -row 0 -column 0 -sticky ew -padx 4 -pady 4
    grid $H(btn_rechoose) -row 0 -column 1 -padx 2
    grid $bd.b2 -row 0 -column 2 -padx 2
    grid $bd.b3 -row 0 -column 3 -padx 2
    grid columnconfigure $bd 0 -weight 1

    set H(env) [ttk::label $w.env -text "" -anchor w]
    grid $H(env) -row 3 -column 0 -sticky ew -padx 10
    set H(status) [ttk::label $w.st -text [::jtagid::tkgui::L status_ready {ready}] -anchor w]
    grid $H(status) -row 4 -column 0 -sticky ew -padx 10 -pady {2 8}

    grid rowconfigure $w 1 -weight 1
    grid columnconfigure $w 0 -weight 1
    return $w
}

proc ::jtagid::tkgui::set_env {text} {
    variable H
    if {[winfo exists $H(env)]} { $H(env) configure -text $text }
    return
}

#==============================================================================
# the chooser dialog: find the BSDL (all filters) and bind it
#==============================================================================

proc ::jtagid::tkgui::build_picker {} {
    variable H
    variable P
    set w .g.pick
    catch {destroy $w}
    toplevel $w
    wm withdraw $w
    wm title $w [::jtagid::tkgui::L dlg_title {Pick the BSDL to bind to the device}]
    wm minsize $w 940 560
    wm geometry $w 1040x620
    wm protocol $w WM_DELETE_WINDOW ::jtagid::tkgui::close_picker
    wm transient $w .g

    set P(win) $w
    ttk::label $w.dev -text "" -anchor w
    grid $w.dev -row 0 -column 0 -sticky ew -padx 10 -pady {8 2}

    set cand [ttk::labelframe $w.cand -text [::jtagid::tkgui::L lbl_candidates {BSDL candidates}]]
    grid $cand -row 1 -column 0 -sticky nsew -padx 8 -pady 4
    set f [ttk::frame $cand.f]
    grid $f -row 0 -column 0 -sticky ew -padx 4 -pady {4 2}
    ttk::label $f.l1 -text [::jtagid::tkgui::L lbl_package {Package}]
    set P(fpkg) [ttk::combobox $f.pkg -state readonly -width 14]
    ttk::label $f.l2 -text [::jtagid::tkgui::L lbl_model {Model}]
    set P(fmodel) [ttk::combobox $f.model -state readonly -width 18]
    ttk::label $f.l3 -text [::jtagid::tkgui::L lbl_keyword {Keyword}]
    set P(ftext) [ttk::entry $f.kw -width 24]
    ttk::button $f.clr -text [::jtagid::tkgui::L btn_clear {Clear}] \
        -command {::jtagid::tkgui::clear_filters}
    set P(count) [ttk::label $f.n -text ""]
    grid $f.l1 -row 0 -column 0; grid $P(fpkg) -row 0 -column 1 -padx {2 10}
    grid $f.l2 -row 0 -column 2; grid $P(fmodel) -row 0 -column 3 -padx {2 10}
    grid $f.l3 -row 0 -column 4; grid $P(ftext) -row 0 -column 5 -padx {2 10}
    grid $f.clr -row 0 -column 6 -padx 2
    grid $P(count) -row 0 -column 7 -padx 8
    bind $P(fpkg) <<ComboboxSelected>> {::jtagid::tkgui::apply_filters}
    bind $P(fmodel) <<ComboboxSelected>> {::jtagid::tkgui::apply_filters}
    bind $P(ftext) <KeyRelease> {::jtagid::tkgui::apply_filters}

    set P(tv) [ttk::treeview $cand.tv -columns {model package irl bsr cells file} \
                   -show headings -selectmode browse -height 8]
    foreach {c width} {model 170 package 100 irl 60 bsr 60 cells 70 file 420} {
        $P(tv) heading $c -text [::jtagid::tkgui::L col_$c $c]
        $P(tv) column $c -width $width -anchor w
    }
    $P(tv) column irl -anchor center
    $P(tv) column bsr -anchor center
    $P(tv) column cells -anchor center
    catch {$P(tv) tag configure recommended -background "#fff3cd"}
    catch {$P(tv) tag configure bound -background "#d7f0dd"}
    set sb [ttk::scrollbar $cand.sb -orient vertical -command "$P(tv) yview"]
    $P(tv) configure -yscrollcommand "$sb set"
    grid $P(tv) -row 1 -column 0 -sticky nsew -padx 4 -pady 4
    grid $sb -row 1 -column 1 -sticky ns -pady 4
    bind $P(tv) <<TreeviewSelect>> {::jtagid::tkgui::on_select}
    bind $P(tv) <Double-1> {::jtagid::tkgui::use_selected}

    set P(details) [text $w.det -height 12 -wrap none -state disabled -font TkFixedFont]
    grid $P(details) -row 2 -column 0 -sticky nsew -padx 8 -pady {0 4}

    set btns [ttk::frame $w.btns]
    grid $btns -row 3 -column 0 -sticky ew -padx 8 -pady {0 8}
    set P(status) [ttk::label $btns.st -text "" -anchor w]
    ttk::button $btns.ok -text [::jtagid::tkgui::L btn_use {Use this BSDL}] \
        -command ::jtagid::tkgui::use_selected
    ttk::button $btns.cancel -text [::jtagid::tkgui::L btn_cancel {Cancel}] \
        -command ::jtagid::tkgui::close_picker
    grid $P(status) -row 0 -column 0 -sticky w
    grid $btns.ok -row 0 -column 1 -padx 4
    grid $btns.cancel -row 0 -column 2 -padx 4
    grid columnconfigure $btns 0 -weight 1

    grid rowconfigure $w 1 -weight 1
    grid columnconfigure $w 0 -weight 1
    bind $w <Escape> {::jtagid::tkgui::close_picker}
    return $w
}

proc ::jtagid::tkgui::pick_status {text {kind normal}} {
    variable P
    if {![winfo exists $P(status)]} { return }
    $P(status) configure -text $text
    switch -- $kind {
        error { $P(status) configure -foreground "#b00020" }
        ok    { $P(status) configure -foreground "#137333" }
        default { $P(status) configure -foreground "#374151" }
    }
    update idletasks
    return
}

proc ::jtagid::tkgui::bound_label {} {
    variable S
    set b $S(bound)
    if {$b eq ""} { return [::jtagid::tkgui::L status_nobound {nothing bound yet}] }
    return "[::jtagid::tkgui::dget $b device] ([::jtagid::tkgui::dget $b idcode], [::jtagid::tkgui::dget $b die]) -> [file tail [::jtagid::tkgui::dget $b bsdl]]"
}

proc ::jtagid::tkgui::show_picker {} {
    variable S
    variable P
    if {![winfo exists $P(win)]} { catch {::jtagid::tkgui::build_picker} }
    if {[llength $S(candidates)] == 0} {
        ::jtagid::tkgui::set_status [::jtagid::tkgui::L status_nocand {no candidates yet - press "Identify FPGA" first}] error
        return
    }
    # who will be bound
    set dev ""
    foreach d $S(devices) { if {[::jtagid::tkgui::dget $d fpga] eq "1"} { set dev $d; break } }
    if {$dev eq ""} { set dev [lindex $S(devices) 0] }
    set die [::jtagid::tkgui::dget $S(sku) die]
    catch {
        $P(win).dev configure -text "[::jtagid::tkgui::L lbl_bind_to {bind to device}]: \
            [::jtagid::tkgui::dget $dev name]  [::jtagid::tkgui::dget $dev idcode]  \
            [::jtagid::tkgui::dget $dev part]  die=$die"
    }
    ::jtagid::tkgui::fill_filters
    ::jtagid::tkgui::apply_filters
    ::jtagid::tkgui::pick_status [::jtagid::tkgui::L status_pick_hint {click the row you want, then "Use this BSDL"}]
    wm deiconify $P(win)
    ::jtagid::tkgui::center_window $P(win)
    catch {raise $P(win)}
    catch {focus -force $P(win)}
    catch {grab set $P(win)}
    return
}

proc ::jtagid::tkgui::close_picker {} {
    variable P
    if {[winfo exists $P(win)]} {
        catch {grab release $P(win)}
        catch {wm withdraw $P(win)}
    }
    return
}

proc ::jtagid::tkgui::do_pick_bsdl {} {
    ::jtagid::tkgui::show_picker
    return
}

#==============================================================================
# data pushed in by Vivado
#==============================================================================

proc ::jtagid::tkgui::render {} {
    # safety net: whatever the backend sends, the window must end up usable
    if {[catch {::jtagid::tkgui::render_raw} err]} {
        ::jtagid::tkgui::show_error "redraw failed: $err"
    }
    return
}

proc ::jtagid::tkgui::show_error {text} {
    ::jtagid::tkgui::set_busy 0
    ::jtagid::tkgui::set_status "[::jtagid::tkgui::L status_failed {failed}]: $text" error
    return
}

proc ::jtagid::tkgui::render_raw {} {
    variable S
    variable H
    if {![info exists ::jtagid::tkgui::DATA]} { return }
    set data $::jtagid::tkgui::DATA
    if {[dict exists $data env]} { ::jtagid::tkgui::set_env [dict get $data env] }
    # devices
    set S(devices) [::jtagid::tkgui::dget $data devices {}]
    $H(devtv) delete [$H(devtv) children {}]
    foreach d $S(devices) {
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
    set S(sku) [::jtagid::tkgui::dget $data sku {}]
    set b [::jtagid::tkgui::dget $data bound]
    set S(bound) $b
    # the binding line: full path in the entry, device <-> file beside the button
    $H(bound) configure -state normal
    $H(bound) delete 0 end
    if {$b ne ""} {
        $H(bound) insert 0 [::jtagid::tkgui::dget $b bsdl]
    } else {
        $H(bound) insert 0 [::jtagid::tkgui::L status_nobound {nothing bound yet}]
    }
    $H(bound) configure -state readonly
    if {$b ne ""} {
        set S(selected) [::jtagid::tkgui::dget $b bsdl]
    } elseif {[::jtagid::tkgui::dget $data selected] ne ""} {
        set S(selected) [::jtagid::tkgui::dget $data selected]
    }
    ::jtagid::tkgui::fill_filters
    # a short hint the backend resolved ("784" -> SFVC784): keep both in step
    set used [::jtagid::tkgui::dget $data pkg_used]
    if {$used ne "" && [string equal -nocase [$H(pkg) get] $used] == 0} {
        catch {$H(pkg) delete 0 end; $H(pkg) insert 0 $used}
    }
    ::jtagid::tkgui::apply_filters
    ::jtagid::tkgui::set_busy 0
    set errors [::jtagid::tkgui::dget $data errors {}]
    if {[llength $errors] > 0} {
        ::jtagid::tkgui::set_status "[::jtagid::tkgui::L status_failed {failed}]: [join $errors { | }]" error
    } else {
        set msg "[::jtagid::tkgui::L status_done {identified}]: [llength [::jtagid::tkgui::dget $data devices {}]] TAP, [llength $S(candidates)] BSDL"
        if {$b ne ""} { append msg "  |  [::jtagid::tkgui::L status_bound {bound}]: [::jtagid::tkgui::bound_label]" }
        if {[dict exists $data pkg_note] && [dict get $data pkg_note] ne ""} {
            append msg "  |  [dict get $data pkg_note]"
        }
        ::jtagid::tkgui::set_status $msg ok
    }
    ::jtagid::tkgui::save_hints
    # the point of identifying is to pick a BSDL, so open the chooser
    if {[llength $S(candidates)] > 0} { ::jtagid::tkgui::show_picker }
    return
}

#==============================================================================
# filtering (inside the chooser)
#==============================================================================

proc ::jtagid::tkgui::norm_cand {c} {
    # give every candidate the full key set the window reads, so a short record
    # can never break a redraw
    set path [::jtagid::tkgui::dget $c path]
    set file [::jtagid::tkgui::dget $c file]
    if {$file eq ""} { set file [file tail $path] }
    set model [::jtagid::tkgui::dget $c model]
    if {$model eq ""} {
        # fall back to the head of the entity (XCZU3EG_SFVC784 -> XCZU3EG)
        set model [lindex [split [::jtagid::tkgui::dget $c entity] _] 0]
    }
    if {$model eq ""} { set model [::jtagid::tkgui::dget $c models] }
    return [dict create \
        path    $path \
        file    $file \
        model   $model \
        models  [::jtagid::tkgui::dget $c models] \
        siblings [::jtagid::tkgui::dget $c siblings] \
        recommended [::jtagid::tkgui::dget $c recommended 0] \
        bound   [::jtagid::tkgui::dget $c bound 0] \
        entity  [::jtagid::tkgui::dget $c entity] \
        package [::jtagid::tkgui::dget $c package] \
        irl     [::jtagid::tkgui::dget $c irl] \
        bsr     [::jtagid::tkgui::dget $c bsr] \
        cells   [::jtagid::tkgui::dget $c cells]]
}

proc ::jtagid::tkgui::fill_filters {} {
    variable S
    variable H
    variable P
    if {![winfo exists $P(fpkg)]} { return }
    set pkgs {}
    set models {}
    foreach c $S(candidates) {
        set p [dict get $c package]
        if {[lsearch -exact $pkgs $p] < 0} { lappend pkgs $p }
        # one entry per real model (XCZU3CG / XCZU3EG), NOT the merged group
        # label, otherwise the model filter cannot separate sibling SKUs
        set m [dict get $c model]
        if {$m ne "" && [lsearch -exact $models $m] < 0} { lappend models $m }
    }
    set all [::jtagid::tkgui::L all {All}]
    $P(fpkg) configure -values [concat [list $all] [lsort $pkgs]]
    $P(fmodel) configure -values [concat [list $all] [lsort $models]]
    # honour the package hint that was typed before identifying
    set hint [string trim [$H(pkg) get]]
    if {$hint ne "" && [lsearch -exact $pkgs $hint] >= 0} {
        $P(fpkg) set $hint
    } elseif {[$P(fpkg) get] eq ""} {
        $P(fpkg) set $all
    }
    if {[$P(fmodel) get] eq ""} { $P(fmodel) set $all }
    return
}

proc ::jtagid::tkgui::clear_filters {} {
    variable P
    $P(fpkg) set [::jtagid::tkgui::L all {All}]
    $P(fmodel) set [::jtagid::tkgui::L all {All}]
    $P(ftext) delete 0 end
    ::jtagid::tkgui::apply_filters
    return
}

proc ::jtagid::tkgui::apply_filters {} {
    variable S
    variable P
    if {![winfo exists $P(tv)]} { return 0 }
    set all [::jtagid::tkgui::L all {All}]
    set pkg [$P(fpkg) get]
    set model [$P(fmodel) get]
    set text [string tolower [string trim [$P(ftext) get]]]
    $P(tv) delete [$P(tv) children {}]
    set shown 0
    set star [::jtagid::tkgui::L tag_recommended {recommended}]
    set btag [::jtagid::tkgui::L tag_bound {bound}]
    foreach c $S(candidates) {
        if {$pkg ne "" && $pkg ne $all && [string equal -nocase [dict get $c package] $pkg] == 0} { continue }
        if {$model ne "" && $model ne $all} {
            if {[string equal -nocase [dict get $c model] $model] == 0} { continue }
        }
        if {$text ne ""} {
            set hay [string tolower "[dict get $c path] [dict get $c entity] [dict get $c model] [dict get $c models] [dict get $c package]"]
            if {[string first $text $hay] < 0} { continue }
        }
        set label [dict get $c model]
        set tags {}
        if {[dict get $c bound] eq "1"} {
            set label "$label  \[$btag\]"
            lappend tags bound
        } elseif {[dict get $c recommended] eq "1"} {
            set label "$label  \[$star\]"
            lappend tags recommended
        }
        $P(tv) insert {} end -id [dict get $c path] -tags $tags -values [list $label \
            [dict get $c package] [dict get $c irl] [dict get $c bsr] [dict get $c cells] \
            [dict get $c file]]
        if {[dict get $c path] eq $S(selected)} {
            catch {$P(tv) selection set [dict get $c path]}
        }
        incr shown
    }
    $P(count) configure -text "$shown / [llength $S(candidates)]"
    return $shown
}

#==============================================================================
# selection / details
#==============================================================================

proc ::jtagid::tkgui::line {key default value} {
    variable P
    if {![winfo exists $P(details)]} { return }
    $P(details) insert end [format "%-12s: %s\n" [::jtagid::tkgui::L $key $default] $value]
    return
}

proc ::jtagid::tkgui::show_details {c} {
    variable S
    variable P
    $P(details) configure -state normal
    $P(details) delete 1.0 end
    set sku $S(sku)
    set die [::jtagid::tkgui::dget $sku die]
    set dec [::jtagid::tkgui::dget $sku decidable]
    if {$die ne ""} {
        # what JTAG proved (the die) vs what it cannot prove (the ordering code)
        ::jtagid::tkgui::line sku_line_die {die (from IDCODE)} $die
        ::jtagid::tkgui::line sku_line_models {same IDCODE} [::jtagid::tkgui::dget $sku models]
        if {$dec eq "0"} {
            ::jtagid::tkgui::line sku_line_same {verdict} \
                [::jtagid::tkgui::L sku_same_die {identical silicon: boundary scan cannot tell these models apart}]
        } else {
            ::jtagid::tkgui::line sku_line_same {verdict} \
                [::jtagid::tkgui::L sku_single {only one model carries this IDCODE}]
        }
        foreach key {ps pl} {
            set text [::jtagid::tkgui::dget $sku $key]
            if {$text eq ""} { continue }
            set first 1
            foreach part [split $text |] {
                if {[string trim $part] eq ""} { continue }
                if {$first} {
                    ::jtagid::tkgui::line "sku_line_$key" $key [string trim $part]
                    set first 0
                } else {
                    $P(details) insert end [format "%-12s  %s\n" "" [string trim $part]]
                }
            }
        }
    }
    ::jtagid::tkgui::line sku_line_this {this row} [dict get $c model]
    if {[llength [dict get $c siblings]] > 0} {
        ::jtagid::tkgui::line sku_line_sib {siblings} [join [dict get $c siblings] { }]
    }
    ::jtagid::tkgui::line col_package {package} [dict get $c package]
    ::jtagid::tkgui::line col_irl {IRL} "[dict get $c irl] bit"
    ::jtagid::tkgui::line col_bsr {BSR} "[dict get $c bsr] cells"
    ::jtagid::tkgui::line sku_line_entity {entity} [dict get $c entity]
    ::jtagid::tkgui::line col_file {file} [dict get $c path]
    if {$die ne "" && $dec eq "0"} {
        $P(details) insert end "\n[::jtagid::tkgui::L sku_how_title {how to settle the SKU}]\n"
        foreach i {1 2 3 4} {
            $P(details) insert end "  [::jtagid::tkgui::L sku_how_$i {}]\n"
        }
    }
    $P(details) configure -state disabled
    return
}

proc ::jtagid::tkgui::on_select {} {
    variable S
    variable P
    set sel [$P(tv) selection]
    if {[llength $sel] == 0} { return }
    set path [lindex $sel 0]
    foreach c $S(candidates) {
        if {[dict get $c path] ne $path} { continue }
        set S(selected) $path
        ::jtagid::tkgui::show_details $c
        ::jtagid::tkgui::pick_status "[::jtagid::tkgui::L status_selected {selected}] [dict get $c file]" ok
        return
    }
    return
}

proc ::jtagid::tkgui::show_details_for_selected {} {
    variable S
    foreach c $S(candidates) {
        if {[dict get $c path] eq $S(selected)} { ::jtagid::tkgui::show_details $c; return }
    }
    return
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

proc ::jtagid::tkgui::use_selected {} {
    variable S
    variable H
    variable P
    set path $S(selected)
    if {$path eq ""} {
        ::jtagid::tkgui::pick_status [::jtagid::tkgui::L status_pick_row {select a row first}] error
        return
    }
    set dev ""
    foreach d $S(devices) { if {[::jtagid::tkgui::dget $d fpga] eq "1"} { set dev $d; break } }
    if {$dev eq ""} { set dev [lindex $S(devices) 0] }
    set pkg ""
    foreach c $S(candidates) {
        if {[dict get $c path] eq $path} { set pkg [dict get $c package]; break }
    }
    # the backend writes bindings.txt, so the binding is reusable later
    ::jtagid::tkgui::remote [list ::jtagid::tkhost::cmd_bind \
        [::jtagid::tkgui::dget $dev idcode] [::jtagid::tkgui::dget $dev name] \
        [::jtagid::tkgui::dget $dev part] [::jtagid::tkgui::dget $S(sku) die] $pkg $path]
    $H(bound) configure -state normal
    $H(bound) delete 0 end
    $H(bound) insert 0 $path
    $H(bound) configure -state readonly
    ::jtagid::tkgui::set_status \
        "[::jtagid::tkgui::L status_bound {bound}]: [file tail $path]" ok
    ::jtagid::tkgui::close_picker
    return
}

proc ::jtagid::tkgui::binding_saved {rec} {
    variable S
    set S(bound) $rec
    ::jtagid::tkgui::set_status \
        "[::jtagid::tkgui::L status_bound {bound}]: [::jtagid::tkgui::bound_label]  ([::jtagid::tkgui::L status_saved {written to bindings.txt}])" ok
    # refresh the markers: the bound row wins over "recommended"
    set bsdl [::jtagid::tkgui::dget $rec bsdl]
    set new {}
    foreach c $S(candidates) {
        dict set c bound [expr {[string equal -nocase [dict get $c path] $bsdl] ? 1 : 0}]
        if {[dict get $c bound] eq "1"} { dict set c recommended 0 }
        lappend new $c
    }
    set S(candidates) $new
    set S(selected) $bsdl
    ::jtagid::tkgui::apply_filters
    ::jtagid::tkgui::show_details_for_selected
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

proc ::jtagid::tkgui::copy_path {} {
    variable S
    set p $S(selected)
    if {$p eq ""} { set p [::jtagid::tkgui::dget $S(bound) bsdl] }
    if {$p eq ""} { return }
    clipboard clear
    clipboard append $p
    ::jtagid::tkgui::set_status [::jtagid::tkgui::L status_copied {path copied to the clipboard}] ok
    return
}

proc ::jtagid::tkgui::open_folder {} {
    variable S
    set path $S(selected)
    if {$path eq ""} { set path [::jtagid::tkgui::dget $S(bound) bsdl] }
    if {$path eq ""} { return }
    # Explorer needs a NATIVE path.  The paths we hold use forward slashes
    # (BSDL/report/select all use them), and "/select,D:/x/y.bsd" opens nothing
    # useful - a "This PC" window, which is exactly what this button used to do.
    set native [file nativename [file normalize $path]]
    if {[file exists $native]} {
        catch {exec explorer.exe /select,$native &}
    } elseif {[file isdirectory [file dirname $native]]} {
        # the file is gone but its folder is still there: show the folder
        catch {exec explorer.exe [file dirname $native] &}
    } else {
        ::jtagid::tkgui::set_status \
            [::jtagid::tkgui::L status_notfound {file not found (was the BSDL folder moved?)}] error
    }
    return
}

proc ::jtagid::tkgui::do_close {} {
    # closing the window only hides it: the Vivado backend keeps running, and
    # "jtagid gui" brings it straight back without re-reading the JTAG chain.
    ::jtagid::tkgui::remote {::jtagid::tkhost::cmd_window_closed}
    ::jtagid::tkgui::close_picker
    catch {wm withdraw .g}
    return
}

#==============================================================================
# remember what the user already knows (package / part / BSDL dir)
#==============================================================================

proc ::jtagid::tkgui::hint_file {} {
    return [file join $::env(LOCALAPPDATA) jtag_identify gui_hints.txt]
}

proc ::jtagid::tkgui::save_hints {} {
    variable H
    set f [::jtagid::tkgui::hint_file]
    catch {file mkdir [file dirname $f]}
    if {[catch {open $f w} fh]} { return }
    catch {
        fconfigure $fh -encoding utf-8
        puts $fh [string trim [$H(pkg) get]]
        puts $fh [string trim [$H(part) get]]
        puts $fh [string trim [$H(dir) get]]
        close $fh
    }
    return
}

proc ::jtagid::tkgui::load_hints {} {
    variable H
    set f [::jtagid::tkgui::hint_file]
    if {![file exists $f]} { return }
    if {[catch {open $f r} fh]} { return }
    set lines {}
    catch {
        fconfigure $fh -encoding utf-8
        while {[gets $fh line] >= 0} { lappend lines [string trimright $line "\r\n"] }
        close $fh
    }
    foreach {w v} [list $H(pkg) [lindex $lines 0] $H(part) [lindex $lines 1] $H(dir) [lindex $lines 2]] {
        if {$v eq ""} { continue }
        catch {$w delete 0 end; $w insert 0 $v}
    }
    return
}

#==============================================================================
# start
#==============================================================================

::jtagid::tkgui::load_msgs
set ::jtagid::tkgui::S(t0) [clock milliseconds]
::jtagid::tkgui::build
::jtagid::tkgui::build_picker
::jtagid::tkgui::load_hints
catch {bind .g <Control-q> {::jtagid::tkgui::quit_app}}
::jtagid::tkgui::set_status \
    [::jtagid::tkgui::L status_waiting {talking to the Vivado backend...}] busy
# centred, and brought to the front once when it is shown
::jtagid::tkgui::center_window .g
::jtagid::tkgui::pop_up .g
# Tell the backend the window is up.  It answers with backend_ready, and THAT is
# what starts the automatic identify - so nothing long ever runs while Vivado is
# still sourcing the front end file (the console gets its prompt back first).
after 50 { catch {::jtagid::tkgui::remote {::jtagid::tkhost::cmd_hello}} }
after 8000 { catch {::jtagid::tkgui::handshake_timeout} }
