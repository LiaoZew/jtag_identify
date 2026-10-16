###############################################################################
# jtagid_tk_gui.tcl -- jtagid GUI through Xilinx's official TclStore app
#                      ::tclapp::xilinx::tk_tunnel  (no web UI, no HTML).
#
# This file runs INSIDE Vivado.  It:
#   1. starts a Tcl/Tk shell (wish) as the tunnel "server"  (hidden window),
#   2. connects to it with the tk_tunnel client,
#   3. ships the GUI code (jtagid_tk_ui.tcl) into that Tk shell as one line,
#   4. pumps Vivado's event loop so button clicks arrive as commands and are
#      executed here, where the cable and the driver live.
#
# Usage (Vivado Tcl console, or vivado -mode tcl):
#
#     source D:/.../jtag_identify/jtagid_tk_gui.tcl
#
# Environment (all optional):
#     JTAGID_TKSH        path to the wish/Tcl-Tk shell to use as the Tk side
#     JTAGID_TK_PORT     tunnel port, default 8001
#     JTAGID_TK_SELFTEST 1 = run the automated self test instead of waiting
#
# The tunnel transport is line based and the app never sets an encoding, so
# everything sent (this file's GUI code and all data) is kept ASCII.
#
# 2026-10
###############################################################################

namespace eval ::jtagid::tkhost {
    variable S
    array set S {
        port      8001
        sock      ""
        done      0
        pid       ""
        wish      ""
        appdir    ""
        selftest  0
        selected  ""
        here      ""
    }
}

set ::jtagid::tkhost::S(here) [file dirname [file normalize [info script]]]

#==============================================================================
# helpers
#==============================================================================

proc ::jtagid::tkhost::datadir {} {
    set dir [file join $::env(LOCALAPPDATA) jtag_identify]
    catch {file mkdir $dir}
    return $dir
}

proc ::jtagid::tkhost::note {text} {
    set path [file join [::jtagid::tkhost::datadir] tk_gui.log]
    if {[catch {open $path a} fh]} { return }
    catch {
        fconfigure $fh -encoding utf-8
        puts $fh "[clock format [clock seconds] -format {%H:%M:%S}] $text"
        close $fh
    }
    puts "jtagid: $text"
    flush stdout
    return
}

proc ::jtagid::tkhost::find_tksh {} {
    variable S
    # 1) explicit override
    if {[info exists ::env(JTAGID_TKSH)] && $::env(JTAGID_TKSH) ne ""} {
        if {[file exists $::env(JTAGID_TKSH)]} { return [file normalize $::env(JTAGID_TKSH)] }
        ::jtagid::tkhost::note "JTAGID_TKSH points at a missing file: $::env(JTAGID_TKSH)"
    }
    # 2) the Tcl/Tk shells that ship inside the Vivado installation
    set found [list]
    if {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
        set base $::env(XILINX_VIVADO)
        foreach pattern [list \
                "$base/tps/win64/git-*/mingw64/bin/wish.exe" \
                "$base/tps/win64/git-*/mingw64/bin/wish86.exe" \
                "$base/tps/win64/git-*/bin/wish85.exe" \
                "$base/tps/win64/git-*/bin/wish.exe" \
                "$base/tps/win64/*/bin/wish*.exe"] {
            foreach p [lsort -decreasing [glob -nocomplain $pattern]] { lappend found $p }
        }
    }
    # 3) anything on PATH
    foreach cand {wish.exe wish86.exe wish85.exe wish} {
        if {![catch {set p [auto_execok $cand]}] && $p ne "" && [file exists $p]} {
            lappend found $p
        }
    }
    foreach p $found {
        if {[file exists $p]} { return [file normalize $p] }
    }
    return ""
}

proc ::jtagid::tkhost::find_appdir {} {
    # the TclStore app directory (provides communication.tcl on the Tk side and
    # the client procs here)
    set tries [list]
    if {[info exists ::env(XILINX_TCLAPP_REPO)] && $::env(XILINX_TCLAPP_REPO) ne ""} {
        lappend tries [file join $::env(XILINX_TCLAPP_REPO) tclapp xilinx tk_tunnel]
        lappend tries [file join $::env(XILINX_TCLAPP_REPO) xilinx tk_tunnel]
    }
    foreach dir $::auto_path {
        if {[string match "*tk_tunnel*" $dir] && [file isdirectory $dir]} { lappend tries $dir }
    }
    if {[info exists ::env(APPDATA)]} {
        foreach p [lsort -decreasing [glob -nocomplain \
                "$::env(APPDATA)/Xilinx/Vivado/*/XilinxTclStore/tclapp/xilinx/tk_tunnel"]] {
            lappend tries $p
        }
    }
    foreach dir $tries {
        if {[file exists [file join $dir communication.tcl]]} { return [file normalize $dir] }
    }
    return ""
}

proc ::jtagid::tkhost::require_tunnel {appdir} {
    if {[llength [info commands ::tclapp::xilinx::tk_tunnel::start_client]] > 0} { return 1 }
    if {![catch {package require ::tclapp::xilinx::tk_tunnel}]} { return 1 }
    # fall back to sourcing the app directly (works without the TclStore index)
    foreach f {communication.tcl tk_tunnel.tcl} {
        catch {uplevel #0 [list source [file join $appdir $f]]}
    }
    return [expr {[llength [info commands ::tclapp::xilinx::tk_tunnel::start_client]] > 0}]
}

proc ::jtagid::tkhost::escape {text} {
    # make arbitrary Tcl code safe inside a double quoted string
    set out ""
    foreach ch [split $text ""] {
        switch -- $ch {
            "\\" { append out "\\\\" }
            "\"" { append out "\\\"" }
            "\$" { append out "\\\$" }
            "\[" { append out "\\\[" }
            "\]" { append out "\\\]" }
            "\n" { append out "\\n" }
            "\r" { append out "\\r" }
            default { append out $ch }
        }
    }
    return $out
}

proc ::jtagid::tkhost::ascii_only {text} {
    set out ""
    foreach ch [split $text ""] {
        scan $ch %c code
        if {$code < 128} { append out $ch } else { append out "?" }
    }
    return [string map [list "\n" " " "\r" " " "\t" " "] $out]
}

#==============================================================================
# Tk side lifecycle
#==============================================================================

proc ::jtagid::tkhost::start_server {} {
    variable S
    set server [file join $S(here) jtagid_tk_server.tcl]
    if {![file exists $server]} { return "jtagid_tk_server.tcl not found next to jtagid_tk_gui.tcl" }
    if {$S(wish) eq ""} { set S(wish) [::jtagid::tkhost::find_tksh] }
    if {$S(wish) eq ""} { return "no Tcl/Tk shell found (set JTAGID_TKSH)" }
    # the Tk side reads its display strings from this UTF-8 file
    set msgs [file join $S(here) jtagid_gui_msgs.txt]
    if {[file exists $msgs]} { set ::env(JTAGID_MSGS) $msgs }
    set log [file join [::jtagid::tkhost::datadir] tk_server.log]
    set errlog [file join [::jtagid::tkhost::datadir] tk_server.err]
    catch {file delete $log}
    catch {file delete $errlog}
    # Launch through a tiny .cmd wrapper: it redirects the Tk shell's own output
    # to a file, so nothing inherits Tcl's exec pipe (a grandchild holding that
    # pipe would make exec wait forever) and the exec stays non-blocking thanks
    # to the trailing &.
    set wrapper [file join $S(here) jtagid_tk_wish.cmd]
    if {![file exists $wrapper]} { return "jtagid_tk_wish.cmd not found next to jtagid_tk_gui.tcl" }
    set ::env(JTAGID_TK_WISH)   $S(wish)
    set ::env(JTAGID_TK_SERVER) $server
    set ::env(JTAGID_TK_APPDIR) $S(appdir)
    set ::env(JTAGID_TK_PORT)   $S(port)
    set ::env(JTAGID_TK_LOG)    $log
    set ::env(JTAGID_TK_STDOUT) "$log.out"
    set S(pid) ""
    if {[catch {set S(pid) [exec cmd /c $wrapper &]} msg]} {
        return "cannot start the Tk shell ($S(wish)): $msg"
    }
    return ""
}

proc ::jtagid::tkhost::stop_server {} {
    variable S
    if {$S(pid) ne ""} {
        catch {exec taskkill /PID $S(pid) /T /F > NUL 2> NUL}
        set S(pid) ""
    }
    return
}

proc ::jtagid::tkhost::send_ui {} {
    variable S
    set ui [file join $S(here) jtagid_tk_ui.tcl]
    if {![file exists $ui]} { return "jtagid_tk_ui.tcl not found" }
    set fh [open $ui r]
    fconfigure $fh -encoding utf-8
    set code [read $fh]
    close $fh
    # the namespace must exist on the Tk side before a variable can be set in it
    ::tclapp::xilinx::tk_tunnel::rexec {namespace eval ::jtagid::tkgui {}}
    set cmd "set ::jtagid::tkgui::UICODE \"[::jtagid::tkhost::escape $code]\"\n"
    append cmd "uplevel #0 \$::jtagid::tkgui::UICODE"
    ::tclapp::xilinx::tk_tunnel::rexec [string map [list "\n" "; " "\r" " "] $cmd]
    return ""
}

proc ::jtagid::tkhost::query {code} {
    # Synchronous question to the Tk side.  The app's rexec_wait has no timeout,
    # so this wraps the same handshake with one, otherwise a lost answer would
    # block Vivado forever.
    set ::tclapp::xilinx::tk_tunnel::client_return {}
    set aft [after 15000 {set ::tclapp::xilinx::tk_tunnel::client_return {TIMEOUT}}]
    if {[catch {
        ::tclapp::xilinx::tk_tunnel::rexec \
            "::tclapp::xilinx::tk_tunnel::exec_push_return {$code}"
    } err]} {
        after cancel $aft
        return "ERR: $err"
    }
    catch {vwait ::tclapp::xilinx::tk_tunnel::client_return}
    catch {after cancel $aft}
    return $::tclapp::xilinx::tk_tunnel::client_return
}

proc ::jtagid::tkhost::push {data} {
    # ship the result set to the Tk side and let it render
    set cmd "set ::jtagid::tkgui::DATA [list $data]\n::jtagid::tkgui::render"
    ::tclapp::xilinx::tk_tunnel::rexec [string map [list "\n" "; " "\r" " "] $cmd]
    return
}

#==============================================================================
# callbacks executed here in Vivado (sent by the Tk side via broadcast)
#==============================================================================

proc ::jtagid::tkhost::data_from {res} {
    set devices [list]
    foreach d [dict get $res devices] {
        lappend devices [dict create name [dict get $d name] part [dict get $d part] \
            idcode [dict get $d idcode] family [dict get $d family] \
            array [dict get $d array] mfg [dict get $d mfg] fpga [dict get $d fpga]]
    }
    set cands [list]
    foreach c [dict get $res candidates] {
        lappend cands [dict create models [dict get $c models] package [dict get $c package] \
            irl [dict get $c irl] bsr [dict get $c bsr] cells [dict get $c cells] \
            path [dict get $c path] entity [dict get $c entity] file [file tail [dict get $c path]]]
    }
    set errors [list]
    foreach e [dict get $res errors] { lappend errors [::jtagid::tkhost::ascii_only $e] }
    set part ""
    if {[dict get $res part] ne ""} {
        set p [dict get $res part]
        set part [dict create given [dict get $p given] matched [dict get $p matched] \
            message [dict get $p message]]
    }
    set info [dict get $res info]
    set env ""
    foreach key {vivado url bsdl_dir bsdl_files} {
        if {[dict exists $info $key]} { append env "$key=[dict get $info $key]   " }
    }
    return [dict create env [string trim $env] devices $devices candidates $cands \
                errors $errors part $part selected $::jtagid::tkhost::S(selected)]
}

proc ::jtagid::tkhost::cmd_identify {args} {
    variable S
    set dir  [lindex $args 0]
    set pkg  [lindex $args 1]
    set part [lindex $args 2]
    ::jtagid::tkhost::note "identify: dir='$dir' package='$pkg' part='$part'"
    set res ""
    if {[catch {
        set res [::jtagid::collect_report -bsdl-dir $dir -part $part]
    } err]} {
        ::jtagid::tkhost::note "identify failed: $err"
        ::jtagid::tkhost::push [dict create env "" devices [list] candidates [list] \
            errors [list [::jtagid::tkhost::ascii_only $err]] part "" selected $S(selected)]
        return
    }
    # honour the package hint / offer the package list to the Tk side
    set data [::jtagid::tkhost::data_from $res]
    ::jtagid::tkhost::push $data
    ::jtagid::tkhost::note "identify done: [llength [dict get $res candidates]] candidate(s)"
    return
}

proc ::jtagid::tkhost::cmd_scan {} {
    variable S
    set res [dict create devices [list] candidates [list] errors [list] info [dict create] part ""]
    if {[catch {::jtagid::connect} err] || [catch {::jtagid::ensure_target} err2]} {
        if {$err2 ne ""} { set err $err2 }
        dict lappend res errors [::jtagid::tkhost::ascii_only $err]
        ::jtagid::tkhost::push [dict create env "" devices [list] candidates [list] \
            errors [dict get $res errors] part "" selected $S(selected)]
        return
    }
    foreach d [::jtagid::devices] {
        dict lappend res devices $d
    }
    ::jtagid::tkhost::push [dict create env "target $::jtagid::state(url)" \
        devices [dict get $res devices] candidates $S(candidates) errors [list] \
        part "" selected $S(selected)]
    return
}

proc ::jtagid::tkhost::cmd_reindex {args} {
    variable S
    set dir [lindex $args 0]
    set err ""
    if {$dir ne "" && [file isdirectory $dir]} {
        set ::jtagid::state(bsdl_dir) [file normalize $dir]
    }
    catch {set count [::jtagid::bsdl_index 1]} err
    set errors [list]
    set env "BSDL index: $count files"
    if {$err ne ""} { lappend errors [::jtagid::tkhost::ascii_only $err] }
    ::jtagid::tkhost::push [dict create env "$env   dir=$::jtagid::state(bsdl_dir)" \
        devices $S(devices) candidates $S(candidates) errors $errors part "" selected $S(selected)]
    return
}

proc ::jtagid::tkhost::cmd_select {args} {
    variable S
    set path [string map {\\ /} [lindex $args 0]]
    if {$path eq "" || ![file exists $path]} {
        ::jtagid::tkhost::note "select: not a file: $path"
        return
    }
    set S(selected) $path
    set fh [open [file join [::jtagid::tkhost::datadir] selected_bsdl.txt] w]
    puts $fh $path
    close $fh
    ::jtagid::tkhost::note "selected: $path (remembered in selected_bsdl.txt)"
    return $path
}

proc ::jtagid::tkhost::cmd_quit {} {
    variable S
    set S(done) 1
    return
}

#==============================================================================
# self test (JTAGID_TK_SELFTEST=1): no clicking required
#==============================================================================

proc ::jtagid::tkhost::selftest {} {
    variable S
    set report [list]
    lappend report "SELFTEST|window_exists|[::jtagid::tkhost::query {winfo exists .g}]"
    lappend report "SELFTEST|tk_version|[::jtagid::tkhost::query {info patchlevel}]"
    lappend report "SELFTEST|title|[::jtagid::tkhost::query {wm title .g}]"
    # give the automatic identify time to arrive
    set tries 0
    while {$tries < 60} {
        set rows [::jtagid::tkhost::query {llength [.g.cand.tv children {}]}]
        if {$rows ne "" && $rows ne "0" && ![string match "ERR:*" $rows]} { break }
        catch {update}
        after 500
        incr tries
    }
    lappend report "SELFTEST|candidate_rows|[::jtagid::tkhost::query {llength [.g.cand.tv children {}]}]"
    lappend report "SELFTEST|device_rows|[::jtagid::tkhost::query {llength [.g.dev.tv children {}]}]"
    lappend report "SELFTEST|filters|[::jtagid::tkhost::query {list [.g.cand.f.pkg get] [.g.cand.f.model get]}]"
    # filter the table down to SFVC784 through the same code path the combobox uses
    lappend report "SELFTEST|filter_pkg|[::jtagid::tkhost::query {set ::jtagid::tkgui::S(f_pkg) {}}]"
    ::tclapp::xilinx::tk_tunnel::rexec {.g.cand.f.pkg set SFVC784; ::jtagid::tkgui::apply_filters}
    catch {update}
    after 600
    lappend report "SELFTEST|rows_after_filter|[::jtagid::tkhost::query {llength [.g.cand.tv children {}]}]"
    # select the first visible row the way a click would
    ::tclapp::xilinx::tk_tunnel::rexec {set f [lindex [.g.cand.tv children {}] 0]; .g.cand.tv selection set $f; ::jtagid::tkgui::on_select}
    set tries 0
    while {$tries < 20 && $S(selected) eq ""} { catch {update}; after 300; incr tries }
    lappend report "SELFTEST|selected_here|$S(selected)"
    lappend report "SELFTEST|selected_there|[::jtagid::tkhost::query {set ::jtagid::tkgui::S(selected)}]"
    ::tclapp::xilinx::tk_tunnel::rexec {::jtagid::tkgui::do_close}
    catch {update}
    after 500
    set S(done) 1
    foreach line $report { puts $line; ::jtagid::tkhost::note $line }
    return
}

#==============================================================================
# main
#==============================================================================

proc ::jtagid::tkhost::pump {} {
    variable S
    set n 0
    while {!$S(done) && $n < 200000} {
        catch {update}
        after 40
        incr n
        if {$n % 250 == 0} {
            # make sure the window is still there; otherwise stop
            if {[catch {set alive [::jtagid::tkhost::query {winfo exists .g}]}] || $alive eq "0"} {
                ::jtagid::tkhost::note "window closed, stopping"
                break
            }
        }
    }
    return
}

proc ::jtagid::tkhost::main {} {
    variable S
    if {[info exists ::env(JTAGID_TK_PORT)] && $::env(JTAGID_TK_PORT) ne ""} {
        set S(port) $::env(JTAGID_TK_PORT)
    }
    if {[info exists ::env(JTAGID_TK_SELFTEST)] && $::env(JTAGID_TK_SELFTEST) ne ""} {
        set S(selftest) 1
    }
    if {[llength [info commands ::jtagid::collect_report]] == 0} {
        set driver [file join $S(here) jtagid.tcl]
        if {[file exists $driver]} { uplevel #0 [list source $driver] }
    }
    set S(appdir) [::jtagid::tkhost::find_appdir]
    if {$S(appdir) eq ""} {
        ::jtagid::tkhost::note "tk_tunnel app not found; install it from the Xilinx Tcl Store"
        return 0
    }
    set S(wish) [::jtagid::tkhost::find_tksh]
    if {$S(wish) eq ""} {
        ::jtagid::tkhost::note "no Tcl/Tk shell found (set JTAGID_TKSH)"
        return 0
    }
    ::jtagid::tkhost::note "tk_tunnel app : $S(appdir)"
    ::jtagid::tkhost::note "Tk shell      : $S(wish)"
    if {![::jtagid::tkhost::require_tunnel $S(appdir)]} {
        ::jtagid::tkhost::note "cannot load the tk_tunnel client procs"
        return 0
    }
    if {[catch {set err [::jtagid::tkhost::start_server]}]} { set err $err }
    if {$err ne ""} { ::jtagid::tkhost::note $err; return 0 }
    ::jtagid::tkhost::note "Tk shell pid  : $S(pid), tunnel port $S(port)"
    if {[catch {::tclapp::xilinx::tk_tunnel::start_client 127.0.0.1 $S(port)} msg]} {
        ::jtagid::tkhost::note "cannot connect to the Tk shell: $msg"
        ::jtagid::tkhost::stop_server
        return 0
    }
    ::jtagid::tkhost::note "tunnel connected"
    if {[catch {set err [::jtagid::tkhost::send_ui]}]} { set err $err }
    if {$err ne ""} { ::jtagid::tkhost::note $err; ::jtagid::tkhost::stop_server; return 0 }
    ::jtagid::tkhost::note "GUI shipped to the Tk shell"
    if {$S(selftest)} {
        after 1500 ::jtagid::tkhost::selftest
    }
    ::jtagid::tkhost::pump
    ::jtagid::tkhost::stop_server
    ::jtagid::tkhost::note "GUI closed"
    return 1
}

::jtagid::tkhost::main
