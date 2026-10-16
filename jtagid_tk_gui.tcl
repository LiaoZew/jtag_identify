###############################################################################
# jtagid_tk_gui.tcl -- jtagid GUI through Xilinx's official TclStore app
#                      ::tclapp::xilinx::tk_tunnel  (no web UI, no HTML).
#
# Front end / back end split:
#   front end : a real Tk window in its own wish process (jtagid_tk_ui.tcl)
#   back end  : this file, running INSIDE Vivado, where the cable lives
#
# Sourcing this file does NOT block Vivado.  It launches the Tk shell, ships the
# window code, waits for the window's "hello" (a fraction of a second) and
# returns to the console.  Button clicks then arrive here as line commands
# delivered by the Tcl event loop, which the Vivado IDE keeps servicing while
# the console sits idle at its prompt, so the IDE stays usable and this service
# stays resident until Vivado is closed.
#
#   measured on 2018.3 in GUI mode: an "after" timer and a socket fileevent both
#   fire while the console is idle (see tt_idle_probe.tcl) -> non blocking.
#
# Usage (Vivado IDE Tcl console, or the jtagid_tk.cmd launcher):
#
#     source D:/.../jtag_identify/jtagid_tk_gui.tcl   ;# open / re-open window
#     ::jtagid::tkhost::status                        ;# what is running
#     ::jtagid::tkhost::stop                          ;# stop the service
#
# Environment (all optional):
#     JTAGID_TKSH        path to the wish/Tcl-Tk shell to use as the Tk side
#     JTAGID_TK_PORT     tunnel port, default 8001
#     JTAGID_TK_SELFTEST 1 = also run the automated self test (no clicking)
#
# The Vivado IDE is required: "vivado -mode tcl" (the plain Tcl REPL) does not
# service Tcl events while it waits for input, so a window started there would
# never be answered.  Use jtagid_tk.cmd (which opens the IDE) instead.
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
        pid       ""
        wish      ""
        appdir    ""
        selftest  0
        selected  ""
        here      ""
        running   0
        win       0
        hello     ""
        idle      0
        started   ""
        devices   {}
        candidates {}
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

proc ::jtagid::tkhost::sleep_ms {ms} {
    # bounded wait that keeps the event loop running (the app's own "wait")
    set ::jtagid::tkhost::S(sleep) 0
    after $ms [list set ::jtagid::tkhost::S(sleep) 1]
    catch {vwait ::jtagid::tkhost::S(sleep)}
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

proc ::jtagid::tkhost::wait_flag {name ms} {
    # wait (bounded, event loop stays alive) for $name to be written
    upvar #0 $name var
    set var ""
    set id [after $ms [list set $name TIMEOUT]]
    catch {vwait $name}
    catch {after cancel $id}
    return $var
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
    # Synchronous question to the Tk side; for the self test and for status.
    # The app's rexec_wait has no timeout, so this wraps the same handshake with
    # one, otherwise a lost answer would block Vivado forever.
    set ::tclapp::xilinx::tk_tunnel::client_return {}
    set aft [after 15000 {set ::tclapp::xilinx::tk_tunnel::client_return {TIMEOUT}}]
    if {[catch {::jtagid::tkhost::send_line \
            "::tclapp::xilinx::tk_tunnel::exec_push_return {$code}"} err]} {
        after cancel $aft
        return "ERR: $err"
    }
    catch {vwait ::tclapp::xilinx::tk_tunnel::client_return}
    catch {after cancel $aft}
    return $::tclapp::xilinx::tk_tunnel::client_return
}

proc ::jtagid::tkhost::send_line {line} {
    # one line to the Tk side (tk_tunnel's own rexec does the same thing)
    variable S
    if {![::jtagid::tkhost::alive]} { return -code error "not connected to the Tk window" }
    # the channel is non blocking (safe gets); a flush that cannot complete yet
    # is not a failure - Tcl keeps the bytes buffered and sends them later.
    catch {puts $S(sock) $line}
    catch {flush $S(sock)}
    return
}

proc ::jtagid::tkhost::push {data} {
    # ship the result set to the Tk side and let it render
    set cmd "set ::jtagid::tkgui::DATA [list $data]\n::jtagid::tkgui::render"
    catch {::jtagid::tkhost::send_line [string map [list "\n" "; " "\r" " "] $cmd]}
    return
}

proc ::jtagid::tkhost::alive {} {
    variable S
    if {$S(sock) eq ""} { return 0 }
    if {[catch {eof $S(sock)} e]} { return 0 }
    return [expr {!$e}]
}

#==============================================================================
# the socket: commands from the Tk window arrive here, executed in Vivado
#==============================================================================

proc ::jtagid::tkhost::connect_backend {host port} {
    variable S
    # the app's start_client sets its own socket variable and a fileevent; give
    # the Tk shell a moment to boot, then replace the handler with ours.
    ::jtagid::tkhost::sleep_ms 1200
    if {[catch {::tclapp::xilinx::tk_tunnel::start_client $host $port} msg]} {
        return "cannot connect to the Tk window: $msg"
    }
    set S(sock) $::tclapp::xilinx::tk_tunnel::sock
    fconfigure $S(sock) -blocking 0 -buffering line
    fileevent $S(sock) readable ::jtagid::tkhost::on_readable
    return ""
}

proc ::jtagid::tkhost::on_readable {} {
    variable S
    set ch $S(sock)
    if {$ch eq ""} { return }
    if {[eof $ch]} {
        catch {close $ch}
        set S(sock) ""
        set S(win) 0
        ::jtagid::tkhost::note "Tk window disconnected (backend stays resident)"
        return
    }
    set n 0
    while {$n < 200} {
        if {[catch {gets $ch line} got]} { break }
        if {$got < 0} { break }
        incr n
        set line [string trimright $line "\r\n"]
        if {$line eq ""} { continue }
        ::jtagid::tkhost::run_line $line
    }
    return
}

proc ::jtagid::tkhost::run_line {line} {
    variable S
    if {$S(running)} {
        # a command is already executing: queue this one instead of nesting
        after 50 [list ::jtagid::tkhost::run_line $line]
        return
    }
    set S(running) 1
    set code [catch {uplevel #0 $line} res]
    set S(running) 0
    if {$code} {
        ::jtagid::tkhost::note "command from the window failed: $res"
        ::jtagid::tkhost::note "  command was: [string range $line 0 200]"
        set trace [string map [list "\n" " // " "\t" " "] $::errorInfo]
        ::jtagid::tkhost::note "  trace: [string range $trace 0 400]"
        # never leave the window waiting for a reply that will not come
        catch {
            ::jtagid::tkhost::send_line \
                "::jtagid::tkgui::show_error [list [::jtagid::tkhost::ascii_only $res]]"
        }
    }
    return
}

#==============================================================================
# callbacks executed here in Vivado (sent by the Tk side via broadcast)
#==============================================================================

proc ::jtagid::tkhost::cmd_hello {} {
    variable S
    set S(hello) "1"
    set S(win) 1
    ::jtagid::tkhost::note "Tk window is up - backend answering (console stays free)"
    catch {::jtagid::tkhost::send_line {::jtagid::tkgui::backend_ready}}
    return
}

proc ::jtagid::tkhost::cmd_window_closed {} {
    variable S
    set S(win) 0
    ::jtagid::tkhost::note "window hidden - backend stays resident; run jtagid gui to re-open"
    return
}

proc ::jtagid::tkhost::data_from {res} {
    set devices [list]
    foreach d [dict get $res devices] {
        lappend devices [dict create name [dict get $d name] part [dict get $d part] \
            idcode [dict get $d idcode] family [dict get $d family] \
            array [dict get $d array] mfg [dict get $d mfg] fpga [dict get $d fpga]]
    }
    set cands [list]
    foreach c [dict get $res candidates] {
        lappend cands [dict create models [dict get $c models] model [dict get $c model] \
            siblings [dict get $c siblings] recommended [dict get $c recommended] \
            bound [expr {[dict exists $c bound] ? [dict get $c bound] : 0}] \
            package [dict get $c package] \
            irl [dict get $c irl] bsr [dict get $c bsr] cells [dict get $c cells] \
            path [dict get $c path] entity [dict get $c entity] file [file tail [dict get $c path]]]
    }
    set errors [list]
    foreach e [dict get $res errors] { lappend errors [::jtagid::tkhost::ascii_only $e] }
    set part ""
    if {[dict get $res part] ne ""} {
        set p [dict get $res part]
        set part [dict create given [dict get $p given] matched [dict get $p matched] \
            package [dict get $p package] message [dict get $p message]]
    }
    set info [dict get $res info]
    set env ""
    foreach key {vivado url bsdl_dir bsdl_files} {
        if {[dict exists $info $key]} { append env "$key=[dict get $info $key]   " }
    }
    set sku [dict create die "" models "" packages "" decidable "" note "" ps "" pl "" how ""]
    foreach key {die sku_models sku_packages sku_decidable sku_note sku_ps sku_pl sku_how} {
        if {[dict exists $info $key]} {
            set k [string map {sku_ ""} $key]
            dict set sku $k [::jtagid::tkhost::ascii_only [dict get $info $key]]
        }
    }
    # the binding made earlier (if any) travels with every payload
    set bound ""
    if {[dict exists $info bound_bsdl]} {
        set bound [dict create idcode [dict get $info bound_idcode] \
                       device [dict get $info bound_device] \
                       die [dict get $info die] \
                       bsdl [dict get $info bound_bsdl] \
                       when [dict get $info bound_when]]
        # package: take it from the candidate that was bound
        foreach c [dict get $res candidates] {
            if {[string equal -nocase [dict get $c path] [dict get $info bound_bsdl]]} {
                dict set bound package [dict get $c package]
            }
        }
    }
    set pkg_note ""
    if {[dict exists $info package_hint_note]} {
        set pkg_note [::jtagid::tkhost::ascii_only [dict get $info package_hint_note]]
    }
    return [dict create env [string trim $env] devices $devices candidates $cands \
                errors $errors part $part sku $sku bound $bound pkg_note $pkg_note \
                pkg_used [expr {[dict exists $info package_hint_used] ? [dict get $info package_hint_used] : ""}] \
                selected $::jtagid::tkhost::S(selected)]
}

proc ::jtagid::tkhost::cmd_identify {args} {
    variable S
    set dir  [lindex $args 0]
    set pkg  [lindex $args 1]
    set part [lindex $args 2]
    ::jtagid::tkhost::note "identify: dir='$dir' package='$pkg' part='$part'"
    set res ""
    if {[catch {
        set res [::jtagid::collect_report -bsdl-dir $dir -package $pkg -part $part]
    } err]} {
        ::jtagid::tkhost::note "identify failed: $err"
        ::jtagid::tkhost::push [dict create env "" devices [list] candidates [list] \
            errors [list [::jtagid::tkhost::ascii_only $err]] part "" selected $S(selected)]
        return
    }
    set data [::jtagid::tkhost::data_from $res]
    set S(devices) [dict get $res devices]
    set S(candidates) [dict get $res candidates]
    ::jtagid::tkhost::push $data
    ::jtagid::tkhost::note "identify done: [llength [dict get $res candidates]] candidate(s), die [dict get [dict get $res info] die]"
    return
}

proc ::jtagid::tkhost::cmd_scan {} {
    variable S
    set errors [list]
    foreach step {connect ensure_target} {
        if {[catch {::jtagid::$step} out]} {
            lappend errors [::jtagid::tkhost::ascii_only [::jtagid::one_line $out]]
        }
    }
    set recs [list]
    if {[llength $errors] == 0} {
        if {[catch {set recs [::jtagid::device_records]} err]} {
            lappend errors [::jtagid::tkhost::ascii_only [::jtagid::one_line $err]]
        } elseif {[llength $recs] == 0} {
            lappend errors "no devices enumerated on the chain"
        }
    }
    if {[llength $recs] > 0} { set S(devices) $recs }
    ::jtagid::tkhost::note "scan: [llength $recs] TAP(s), [llength $errors] problem(s)"
    ::jtagid::tkhost::push [dict create env "target $::jtagid::state(url)" \
        devices $S(devices) candidates $S(candidates) errors $errors \
        part "" selected $S(selected)]
    return
}

proc ::jtagid::tkhost::cmd_reindex {args} {
    variable S
    set dir [lindex $args 0]
    set errors [list]
    set count 0
    if {$dir ne "" && [file isdirectory $dir]} {
        set ::jtagid::state(bsdl_dir) [file normalize $dir]
    }
    # note: on success the catch variable holds the RESULT (the file count),
    # so it may only be read inside the failure branch
    if {[catch {set count [::jtagid::bsdl_index 1]} err]} {
        lappend errors [::jtagid::tkhost::ascii_only [::jtagid::one_line $err]]
    }
    ::jtagid::tkhost::note "reindex: $count BSDL file(s) in $::jtagid::state(bsdl_dir)"
    ::jtagid::tkhost::push [dict create env "BSDL index: $count files   dir=$::jtagid::state(bsdl_dir)" \
        devices $S(devices) candidates $S(candidates) errors $errors \
        part "" selected $S(selected)]
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

proc ::jtagid::tkhost::cmd_bind {args} {
    # The chooser in the Tk window picked a BSDL: remember device <-> BSDL so
    # the answer is reusable ("jtagid bsdl-for" prints the path later).
    variable S
    set idcode  [lindex $args 0]
    set device  [lindex $args 1]
    set part    [lindex $args 2]
    set die     [lindex $args 3]
    set package [lindex $args 4]
    set bsdl    [string map {\\ /} [lindex $args 5]]
    if {$idcode eq "" || $bsdl eq ""} {
        ::jtagid::tkhost::note "bind refused: idcode='$idcode' bsdl='$bsdl'"
        catch {::jtagid::tkhost::send_line \
            "::jtagid::tkgui::show_error {[::jtagid::tkhost::ascii_only {no FPGA device to bind to - identify first}]}"}
        return
    }
    if {![file exists $bsdl]} {
        ::jtagid::tkhost::note "bind refused: no such BSDL file: $bsdl"
        catch {::jtagid::tkhost::send_line \
            "::jtagid::tkgui::show_error {[::jtagid::tkhost::ascii_only {that BSDL file does not exist any more}]}"}
        return
    }
    if {[catch {set rec [::jtagid::binding_set $idcode $device $part $die $package $bsdl]} err]} {
        ::jtagid::tkhost::note "bind failed: $err"
        return
    }
    set S(selected) $bsdl
    ::jtagid::tkhost::note "bound: $idcode ($device) <- $bsdl  (bindings.txt)"
    catch {::jtagid::tkhost::send_line "::jtagid::tkgui::binding_saved [list $rec]"}
    return $rec
}

proc ::jtagid::tkhost::cmd_hide_window {} {
    ::jtagid::tkhost::cmd_window_closed
    return
}

proc ::jtagid::tkhost::cmd_quit {} {
    # kept for compatibility: closing the window only hides it now
    ::jtagid::tkhost::cmd_window_closed
    return
}

#==============================================================================
# control
#==============================================================================

proc ::jtagid::tkhost::status {} {
    variable S
    set lines [list]
    lappend lines "port       : $S(port)"
    lappend lines "Tk shell   : [expr {$S(wish) eq "" ? "(not searched yet)" : $S(wish)}]"
    lappend lines "shell pid  : [expr {$S(pid) eq "" ? "(none)" : $S(pid)}]"
    lappend lines "connected  : [::jtagid::tkhost::alive]"
    lappend lines "window up  : $S(win)"
    lappend lines "idle loop  : $S(idle)   (1 = an idle timer fired after startup)"
    lappend lines "started    : $S(started)"
    lappend lines "selected   : $S(selected)"
    return [join $lines \n]
}

proc ::jtagid::tkhost::show_window {} {
    if {![::jtagid::tkhost::alive]} { return 0 }
    catch {::jtagid::tkhost::send_line {::jtagid::tkgui::show}}
    set ::jtagid::tkhost::S(win) 1
    return 1
}

proc ::jtagid::tkhost::stop {} {
    variable S
    if {[::jtagid::tkhost::alive]} {
        catch {::jtagid::tkhost::send_line {::jtagid::tkgui::quit_app}}
        ::jtagid::tkhost::sleep_ms 200
        catch {close $S(sock)}
    }
    set S(sock) ""
    set S(win) 0
    ::jtagid::tkhost::stop_server
    ::jtagid::tkhost::note "GUI service stopped (Vivado console unaffected)"
    return
}

proc ::jtagid::tkhost::pump {{seconds 0}} {
    # Blocking fallback for hosts where the console does not service Tcl events
    # (e.g. "vivado -mode tcl").  The console is busy while this runs.
    variable S
    set deadline [expr {$seconds > 0 ? [clock seconds] + $seconds : 0}]
    while {[::jtagid::tkhost::alive]} {
        catch {update}
        after 40
        if {$deadline > 0 && [clock seconds] >= $deadline} { break }
    }
    return
}

#==============================================================================
# self test (JTAGID_TK_SELFTEST=1): no clicking required
#==============================================================================

proc ::jtagid::tkhost::selftest {} {
    variable S
    set report [list]
    lappend report "SELFTEST|backend_resident|[expr {$S(sock) ne ""}]"
    lappend report "SELFTEST|idle_loop_alive|$S(idle)"
    lappend report "SELFTEST|window_exists|[::jtagid::tkhost::query {winfo exists .g}]"
    lappend report "SELFTEST|ismapped|[::jtagid::tkhost::query {winfo ismapped .g}]"
    lappend report "SELFTEST|focus|[::jtagid::tkhost::query {focus}]"
    lappend report "SELFTEST|topmost|[::jtagid::tkhost::query {wm attributes .g -topmost}]"
    lappend report "SELFTEST|geometry|[::jtagid::tkhost::query {wm geometry .g}]"
    lappend report "SELFTEST|tk_version|[::jtagid::tkhost::query {info patchlevel}]"
    set title [::jtagid::tkhost::query {wm title .g}]
    lappend report "SELFTEST|title|[::jtagid::tkhost::ascii_only $title] ([string length $title] chars)"
    # give the automatic identify time to arrive, then look at the chooser,
    # which is the dialog the whole flow hangs on
    set tries 0
    while {$tries < 60} {
        set rows [::jtagid::tkhost::query {llength [.g.pick.cand.tv children {}]}]
        if {$rows ne "" && $rows ne "0" && ![string match "ERR:*" $rows]} { break }
        catch {update}
        after 500
        incr tries
    }
    lappend report "SELFTEST|chooser_mapped|[::jtagid::tkhost::query {winfo ismapped .g.pick}]"
    lappend report "SELFTEST|chooser_title|[::jtagid::tkhost::query {wm title .g.pick}]"
    lappend report "SELFTEST|candidate_rows|[::jtagid::tkhost::query {llength [.g.pick.cand.tv children {}]}]"
    lappend report "SELFTEST|device_rows|[::jtagid::tkhost::query {llength [.g.dev.tv children {}]}]"
    lappend report "SELFTEST|filters|[::jtagid::tkhost::query {list [.g.pick.cand.f.pkg get] [.g.pick.cand.f.model get]}]"
    # filter the table down to SFVC784 through the same code path the combobox uses
    catch {::jtagid::tkhost::send_line {.g.pick.cand.f.pkg set SFVC784; ::jtagid::tkgui::apply_filters}}
    catch {update}
    after 600
    lappend report "SELFTEST|rows_after_filter|[::jtagid::tkhost::query {llength [.g.pick.cand.tv children {}]}]"
    # the model filter must separate sibling SKUs (the whole point of the
    # per-file model column)
    lappend report "SELFTEST|model_choices|[::jtagid::tkhost::query {.g.pick.cand.f.model cget -values}]"
    catch {::jtagid::tkhost::send_line {.g.pick.cand.f.model set XCZU3EG; ::jtagid::tkgui::apply_filters}}
    catch {update}
    after 600
    lappend report "SELFTEST|rows_after_model_filter|[::jtagid::tkhost::query {llength [.g.pick.cand.tv children {}]}]"
    # select the visible row the way a click would, then use it
    catch {::jtagid::tkhost::send_line {set f [lindex [.g.pick.cand.tv children {}] 0]; .g.pick.cand.tv selection set $f; ::jtagid::tkgui::on_select}}
    catch {update}
    after 600
    lappend report "SELFTEST|selected_there|[::jtagid::tkhost::query {set ::jtagid::tkgui::S(selected)}]"
    lappend report "SELFTEST|details|[::jtagid::tkhost::query {regsub -all {\n} [string range [.g.pick.det get 1.0 end] 0 200] { // }}]"
    # also prove the chooser stays closed/opens on demand after a first binding
    puts "SELFTEST|using the selected BSDL"
    catch {::jtagid::tkhost::send_line {::jtagid::tkgui::use_selected}}
    catch {update}
    after 1200
    lappend report "SELFTEST|chooser_closed|[expr {[::jtagid::tkhost::query {winfo ismapped .g.pick}] eq "0"}]"
    lappend report "SELFTEST|binding_entry|[::jtagid::tkhost::query {.g.bd.e get}]"
    set brec [::jtagid::binding_get 0x14710093]
    if {$brec eq ""} {
        lappend report "SELFTEST|binding_stored|NONE"
        lappend report "SELFTEST|binding_idcode|NONE"
    } else {
        lappend report "SELFTEST|binding_stored|[dict get $brec bsdl]"
        lappend report "SELFTEST|binding_idcode|[dict get $brec idcode]"
    }
    lappend report "SELFTEST|status|[::jtagid::tkhost::query {.g.st cget -text}]"
    # console must still be free: an idle timer scheduled by start must have run
    lappend report "SELFTEST|idle_loop_after_start|$S(idle)"
    catch {::jtagid::tkhost::send_line {::jtagid::tkgui::quit_app}}
    catch {update}
    after 500
    foreach line $report { puts $line; ::jtagid::tkhost::note $line }
    return
}

#==============================================================================
# main: start (or re-open) the service and give the console straight back
#==============================================================================

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
    # already serving? then just bring the window back
    if {[::jtagid::tkhost::alive]} {
        if {[::jtagid::tkhost::show_window]} {
            ::jtagid::tkhost::note "window restored (service was already running)"
            puts "jtagid: window restored - the service never stopped"
            return 1
        }
    }
    # a leftover socket / shell from a front end that died in the meantime
    if {$S(sock) ne ""} { catch {close $S(sock)}; set S(sock) "" }
    if {$S(pid) ne ""} { ::jtagid::tkhost::stop_server }
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
    set err [::jtagid::tkhost::start_server]
    if {$err ne ""} { ::jtagid::tkhost::note $err; return 0 }
    ::jtagid::tkhost::note "Tk shell pid  : $S(pid), tunnel port $S(port)"
    set err [::jtagid::tkhost::connect_backend 127.0.0.1 $S(port)]
    if {$err ne ""} {
        ::jtagid::tkhost::note $err
        ::jtagid::tkhost::stop_server
        return 0
    }
    ::jtagid::tkhost::note "tunnel connected"
    set err [::jtagid::tkhost::send_ui]
    if {$err ne ""} {
        ::jtagid::tkhost::note $err
        ::jtagid::tkhost::stop
        return 0
    }
    ::jtagid::tkhost::note "GUI shipped to the Tk shell"
    # the window answers with cmd_hello as soon as it is built; wait for that
    # only (a fraction of a second) - the auto identify starts afterwards, so
    # nothing long ever runs inside this call.
    set greet [::jtagid::tkhost::wait_flag ::jtagid::tkhost::S(hello) 10000]
    if {$greet eq "TIMEOUT" || $greet eq ""} {
        ::jtagid::tkhost::note "no answer from the Tk window (is this the Vivado IDE console?)"
    }
    set S(started) [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]
    # proof that the IDE keeps servicing Tcl events while the console sits idle
    after 1500 [list ::jtagid::tkhost::heartbeat]
    if {$S(selftest)} { after 2500 [list ::jtagid::tkhost::selftest] }
    puts "jtagid: front end = Tk window, back end = this Vivado session"
    puts "jtagid: console is free, service stays resident until Vivado is closed"
    puts "jtagid: re-open the window with  jtagid gui   |   stop it with  ::jtagid::tkhost::stop"
    flush stdout
    return 1
}

proc ::jtagid::tkhost::heartbeat {} {
    variable S
    set S(idle) 1
    ::jtagid::tkhost::note "idle loop alive: the console is free and the backend keeps serving"
    return
}

::jtagid::tkhost::main
