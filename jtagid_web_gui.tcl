###############################################################################
# jtagid_web_gui.tcl -- the jtagid GUI: a local web interface served by Tcl.
#
# It is a real GUI (buttons, tables, filters, click to select), but it runs
# without Tk, because Vivado's Tcl has no Tk runtime at all:
#   verified in GUI mode -- Vivado 2018.3 (Tcl 8.5.14) and 2024.2 (Tcl 8.6.13)
#   both fail "package require Tk" and do not even define toplevel/wm/ttk;
#   2024.2 ships only the Tk script library (tps/tk), the DLL is missing.
# Every wish/tclsh on this machine, including the copies inside the Vivado and
# Vitis_HLS trees, belongs to Git for Windows.
#
# Usage
#   1) double click  jtagid_gui.cmd          (starts Vivado, opens the browser)
#   2) or from any Vivado Tcl console:       source jtagid_web_gui.tcl
#   3) or in a batch/console session:        vivado -mode tcl -source jtagid_web_gui.tcl
#
# The page is served on http://127.0.0.1:<port>/ (default 8760, override with
# the environment variable JTAGID_PORT).  The Tcl side does all the work
# (boundary scan, BSDL lookup) and the browser only renders it.
#
# ASCII only on purpose: Vivado decodes sourced files with the system code page,
# so non-ASCII text here would break parsing.  All display text lives in
# jtagid_web_gui.html (UTF-8).
#
# 2026-10
###############################################################################

namespace eval ::jtagid::web {
    variable S
    array set S {
        port     8760
        server   ""
        selected ""
        result   ""
        html     ""
        requests 0
    }
}

set ::jtagid::web::HERE [file dirname [file normalize [info script]]]

#==============================================================================
# backend log (written by Tcl, so the .cmd launcher needs no shell redirection)
#==============================================================================

proc ::jtagid::web::logfile {} {
    if {![info exists ::env(LOCALAPPDATA)]} { return "" }
    set dir [file join $::env(LOCALAPPDATA) jtag_identify]
    catch {file mkdir $dir}
    return [file join $dir web_backend.log]
}

proc ::jtagid::web::note {text {truncate 0}} {
    set path [::jtagid::web::logfile]
    if {$path eq ""} { return }
    if {[catch {open $path [expr {$truncate ? "w" : "a"}]} fh]} { return }
    catch {
        fconfigure $fh -encoding utf-8
        if {$truncate} {
            puts $fh "jtagid web GUI backend log"
            puts $fh "started [clock format [clock seconds]]"
            puts $fh "tcl     [info patchlevel]"
            puts $fh "script  [info script]"
            puts $fh "------------------------------------------------------------"
        }
        puts $fh "[clock format [clock seconds] -format {%H:%M:%S}] $text"
        close $fh
    }
    return
}

#==============================================================================
# tiny JSON helpers (Tcl 8.5 has no json package)
#==============================================================================

proc ::jtagid::web::js {text} {
    # JSON string, ASCII only: non printable / non ASCII become \uXXXX
    set out ""
    foreach ch [split $text ""] {
        scan $ch %c code
        switch -- $ch {
            \"  { append out "\\\"" }
            \\  { append out "\\\\" }
            "\n" { append out "\\n" }
            "\r" { append out "\\r" }
            "\t" { append out "\\t" }
            default {
                if {$code < 32 || $code > 126} {
                    append out [format "\\u%04X" $code]
                } else {
                    append out $ch
                }
            }
        }
    }
    return "\"$out\""
}

proc ::jtagid::web::jlist {items} {
    return "\[[join $items ,]\]"
}

proc ::jtagid::web::jobj {kv} {
    set parts [list]
    dict for {key value} $kv { lappend parts "[::jtagid::web::js $key]:$value" }
    return "{[join $parts ,]}"
}

#==============================================================================
# driver access
#==============================================================================

proc ::jtagid::web::ensure_driver {} {
    if {[llength [info commands ::jtagid::collect_report]] > 0} { return 1 }
    set driver [file join $::jtagid::web::HERE jtagid.tcl]
    if {![file exists $driver]} { return 0 }
    uplevel #0 [list source $driver]
    return [expr {[llength [info commands ::jtagid::collect_report]] > 0}]
}

proc ::jtagid::web::default_bsdl_dir {} {
    if {[llength [info commands ::jtagid::default_bsdl_dir]] > 0} {
        return [::jtagid::default_bsdl_dir]
    }
    return ""
}

proc ::jtagid::web::load_html {} {
    variable S
    if {$S(html) ne ""} { return $S(html) }
    set file [file join $::jtagid::web::HERE jtagid_web_gui.html]
    if {![file exists $file]} {
        return "<html><body><h2>jtagid</h2><p>jtagid_web_gui.html is missing next to jtagid_web_gui.tcl</p></body></html>"
    }
    set fh [open $file r]
    fconfigure $fh -encoding utf-8
    set S(html) [read $fh]
    close $fh
    return $S(html)
}

#==============================================================================
# result -> JSON
#==============================================================================

proc ::jtagid::web::result_json {res} {
    variable S
    set devs [list]
    foreach d [dict get $res devices] {
        lappend devs [::jtagid::web::jobj [dict create \
            name   [::jtagid::web::js [dict get $d name]] \
            part   [::jtagid::web::js [dict get $d part]] \
            idcode [::jtagid::web::js [dict get $d idcode]] \
            family [::jtagid::web::js [dict get $d family]] \
            array  [::jtagid::web::js [dict get $d array]] \
            mfg    [::jtagid::web::js [dict get $d mfg]] \
            fpga   [::jtagid::web::js [dict get $d fpga]]]]
    }
    set cands [list]
    foreach c [dict get $res candidates] {
        lappend cands [::jtagid::web::jobj [dict create \
            models  [::jtagid::web::js [dict get $c models]] \
            package [::jtagid::web::js [dict get $c package]] \
            irl     [::jtagid::web::js [dict get $c irl]] \
            bsr     [::jtagid::web::js [dict get $c bsr]] \
            cells   [::jtagid::web::js [dict get $c cells]] \
            path    [::jtagid::web::js [dict get $c path]] \
            entity  [::jtagid::web::js [dict get $c entity]] \
            file    [::jtagid::web::js [file tail [dict get $c path]]]]]
    }
    set errs [list]
    foreach e [dict get $res errors] { lappend errs [::jtagid::web::js $e] }
    set info [dict create]
    dict for {key value} [dict get $res info] {
        dict set info $key [::jtagid::web::js $value]
    }
    set part "null"
    set p [dict get $res part]
    if {$p ne ""} {
        set part [::jtagid::web::jobj [dict create \
            given   [::jtagid::web::js [dict get $p given]] \
            matched [::jtagid::web::js [dict get $p matched]] \
            message [::jtagid::web::js [dict get $p message]]]]
    }
    set ok [expr {[llength [dict get $res errors]] == 0}]
    return [::jtagid::web::jobj [dict create \
        ok         $ok \
        devices    [::jtagid::web::jlist $devs] \
        candidates [::jtagid::web::jlist $cands] \
        errors     [::jtagid::web::jlist $errs] \
        info       [::jtagid::web::jobj $info] \
        part       $part \
        selected   [::jtagid::web::js $S(selected)]]]
}

#==============================================================================
# HTTP plumbing
#==============================================================================

proc ::jtagid::web::url_decode {text} {
    set text [string map [list + " "] $text]
    set out ""
    set i 0
    set n [string length $text]
    while {$i < $n} {
        set ch [string index $text $i]
        if {$ch eq "%" && [expr {$i + 2}] < $n} {
            set hex [string range $text [expr {$i + 1}] [expr {$i + 2}]]
            if {[string is xdigit -strict $hex]} {
                append out [format %c 0x$hex]
                incr i 3
                continue
            }
        }
        append out $ch
        incr i
    }
    return $out
}

proc ::jtagid::web::parse_query {query} {
    set q [dict create]
    foreach pair [split $query &] {
        if {$pair eq ""} { continue }
        set i [string first = $pair]
        if {$i < 0} {
            dict set q [::jtagid::web::url_decode $pair] ""
        } else {
            dict set q [::jtagid::web::url_decode [string range $pair 0 [expr {$i - 1}]]] \
                          [::jtagid::web::url_decode [string range $pair [expr {$i + 1}] end]]
        }
    }
    return $q
}

proc ::jtagid::web::respond {chan status type body} {
    set bytes [encoding convertto utf-8 $body]
    set header "HTTP/1.1 $status\r\nContent-Type: $type; charset=utf-8\r\n\
Content-Length: [string length $bytes]\r\nCache-Control: no-store\r\n\
Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
    catch {
        fconfigure $chan -translation binary -blocking 1 -buffering none
        puts -nonewline $chan $header
        puts -nonewline $chan $bytes
        flush $chan
    }
    return
}

proc ::jtagid::web::json_reply {chan body} {
    ::jtagid::web::respond $chan "200 OK" "application/json" $body
}

proc ::jtagid::web::close_conn {chan} {
    variable S
    catch {fileevent $chan readable {}}
    catch {close $chan}
    catch {unset S(conn,$chan)}
}

proc ::jtagid::web::accept {chan addr port} {
    variable S
    incr S(requests)
    fconfigure $chan -blocking 0 -buffering none -translation binary
    set S(conn,$chan) ""
    fileevent $chan readable [list ::jtagid::web::readable $chan]
    return
}

proc ::jtagid::web::readable {chan} {
    variable S
    if {![info exists S(conn,$chan)]} { return }
    if {[catch {set data [read $chan]} err]} {
        ::jtagid::web::close_conn $chan
        return
    }
    if {$data eq ""} {
        if {[eof $chan]} { ::jtagid::web::close_conn $chan }
        return
    }
    append S(conn,$chan) $data
    set req $S(conn,$chan)
    set hdr_end [string first "\r\n\r\n" $req]
    if {$hdr_end < 0} {
        if {[string length $req] > 131072} { ::jtagid::web::close_conn $chan }
        return
    }
    set head [string range $req 0 [expr {$hdr_end + 3}]]
    set body [string range $req [expr {$hdr_end + 4}] end]
    set length 0
    foreach line [split $head "\r\n"] {
        if {[string match -nocase "Content-Length:*" $line]} {
            set length [string trim [string range $line 15 end]]
        }
    }
    if {[string length $body] < $length} { return }
    # request complete -> parse it and answer
    catch {unset S(conn,$chan)}
    catch {fileevent $chan readable {}}
    set request [lindex [split $head "\r\n"] 0]
    set method [lindex [split $request " "] 0]
    set uri    [lindex [split $request " "] 1]
    set query  ""
    set qpos [string first ? $uri]
    if {$qpos >= 0} {
        set query [string range $uri [expr {$qpos + 1}] end]
        set uri   [string range $uri 0 [expr {$qpos - 1}]]
    }
    set q [::jtagid::web::parse_query $query]
    if {[catch {::jtagid::web::dispatch $chan $method $uri $q $body} err]} {
        catch {
            ::jtagid::web::json_reply $chan [::jtagid::web::jobj [dict create \
                ok 0 error [::jtagid::web::js $err]]]
        }
    }
    catch {close $chan}
    return
}

proc ::jtagid::web::dispatch {chan method uri q body} {
    variable S
    switch -- $uri {
        "/" - "/index.html" {
            ::jtagid::web::respond $chan "200 OK" "text/html" [::jtagid::web::load_html]
            return
        }
        "/api/defaults" {
            if {![::jtagid::web::ensure_driver]} { error "jtagid.tcl not found" }
            # read the facts the driver already probed while loading: calling
            # probe_compat here would load labtools and stall the first request
            set vivado ""
            if {[info exists ::jtagid::compat(vivado)]} { set vivado $::jtagid::compat(vivado) }
            ::jtagid::web::json_reply $chan [::jtagid::web::jobj [dict create \
                ok 1 \
                bsdl_dir [::jtagid::web::js [::jtagid::web::default_bsdl_dir]] \
                vivado   [::jtagid::web::js $vivado] \
                port     $S(port) \
                selected [::jtagid::web::js $S(selected)] \
                tk       [::jtagid::web::js [expr {[catch {package require Tk}] ? {no} : {yes}}]]]]
            return
        }
        "/api/identify" {
            if {![::jtagid::web::ensure_driver]} { error "jtagid.tcl not found" }
            set dir  ""
            set pkg  ""
            set part ""
            if {[dict exists $q dir]}     { set dir  [dict get $q dir] }
            if {[dict exists $q package]} { set pkg  [dict get $q package] }
            if {[dict exists $q part]}    { set part [dict get $q part] }
            set res [::jtagid::collect_report -bsdl-dir $dir -part $part]
            set S(result) $res
            # keep all candidates; the page does the package filtering itself
            ::jtagid::web::json_reply $chan [::jtagid::web::result_json $res]
            return
        }
        "/api/state" {
            if {$S(result) eq ""} {
                ::jtagid::web::json_reply $chan [::jtagid::web::jobj [dict create \
                    ok 1 devices [::jtagid::web::jlist [list]] \
                    candidates [::jtagid::web::jlist [list]] \
                    errors [::jtagid::web::jlist [list]] \
                    info [::jtagid::web::jobj [dict create]] \
                    part null selected [::jtagid::web::js $S(selected)]]]
            } else {
                ::jtagid::web::json_reply $chan [::jtagid::web::result_json $S(result)]
            }
            return
        }
        "/api/reindex" {
            if {![::jtagid::web::ensure_driver]} { error "jtagid.tcl not found" }
            set dir ""
            if {[dict exists $q dir]} { set dir [dict get $q dir] }
            if {$dir ne ""} {
                if {![file isdirectory $dir]} { error "not a directory: $dir" }
                set ::jtagid::state(bsdl_dir) [file normalize $dir]
            }
            set count [::jtagid::bsdl_index 1]
            ::jtagid::web::json_reply $chan [::jtagid::web::jobj [dict create \
                ok 1 files $count dir [::jtagid::web::js $::jtagid::state(bsdl_dir)]]]
            return
        }
        "/api/select" {
            set path ""
            if {[dict exists $q path]} { set path [dict get $q path] }
            set path [string map {\\ /} $path]
            if {$path eq "" || ![file exists $path]} { error "not a file: $path" }
            set S(selected) $path
            set details "null"
            if {[llength [info commands ::jtagid::bsdl_details]] > 0} {
                if {![catch {set d [::jtagid::bsdl_details $path]}]} {
                    set kv [dict create]
                    foreach key {entity model package irl bsr cells} {
                        if {[dict exists $d $key]} {
                            dict set kv $key [::jtagid::web::js [dict get $d $key]]
                        }
                    }
                    set details [::jtagid::web::jobj $kv]
                }
            }
            set saved 0
            set dir [file join $::env(LOCALAPPDATA) jtag_identify]
            catch {file mkdir $dir}
            if {![catch {open [file join $dir selected_bsdl.txt] w} fh]} {
                puts $fh $path
                close $fh
                set saved 1
            }
            ::jtagid::web::json_reply $chan [::jtagid::web::jobj [dict create \
                ok 1 saved $saved path [::jtagid::web::js $path] details $details]]
            return
        }
        "/api/open" {
            set path ""
            if {[dict exists $q path]} { set path [dict get $q path] }
            set path [string map {\\ /} $path]
            set done 0
            # explorer needs a native (backslash) path, otherwise "/select,..."
            # just opens a "This PC" window
            set native [file nativename [file normalize $path]]
            if {[file exists $native]} {
                if {![catch {exec explorer.exe /select,$native &}]} { set done 1 }
            } elseif {[file isdirectory [file dirname $native]]} {
                if {![catch {exec explorer.exe [file dirname $native] &}]} { set done 1 }
            }
            ::jtagid::web::json_reply $chan [::jtagid::web::jobj [dict create \
                ok $done path [::jtagid::web::js $path]]]
            return
        }
        "/api/stop" {
            ::jtagid::web::json_reply $chan [::jtagid::web::jobj [dict create ok 1]]
            after 500 { ::jtagid::web::stop }
            return
        }
        default {
            ::jtagid::web::respond $chan "404 Not Found" "text/plain" "not found: $uri"
            return
        }
    }
}

#==============================================================================
# server lifecycle
#==============================================================================

proc ::jtagid::web::stop {} {
    variable S
    if {$S(server) ne ""} { catch {close $S(server)}; set S(server) "" }
    ::jtagid::web::note "stopped"
    puts "jtagid: web GUI stopped"
    return
}

proc ::jtagid::web::open_browser {url} {
    if {![catch {exec {*}[list powershell -NoProfile -Command "Start-Process '$url'"]}]} { return 1 }
    catch {exec cmd /c start "" $url}
    return 0
}

proc ::jtagid::web::start {{port ""}} {
    variable S
    if {$port eq ""} {
        if {[info exists ::env(JTAGID_PORT)] && $::env(JTAGID_PORT) ne ""} {
            set port $::env(JTAGID_PORT)
        } else {
            set port $S(port)
        }
    }
    if {![::jtagid::web::ensure_driver]} {
        ::jtagid::web::note "FATAL: jtagid.tcl not found next to jtagid_web_gui.tcl"
        puts "jtagid: jtagid.tcl not found next to jtagid_web_gui.tcl"
        return 0
    }
    ::jtagid::web::note "driver loaded: Vivado [expr {[info exists ::jtagid::compat(vivado)] ? $::jtagid::compat(vivado) : {?}}]"
    # find a free port, prefer the requested one
    set bound ""
    foreach candidate [concat [list $port] [list [expr {$port + 1}] [expr {$port + 2}] [expr {$port + 3}]]] {
        if {![catch {set s [socket -server ::jtagid::web::accept $candidate]} err]} {
            set bound $candidate
            set S(server) $s
            break
        }
    }
    if {$bound eq ""} {
        ::jtagid::web::note "FATAL: cannot listen on port $port: $err"
        puts "jtagid: cannot listen on port $port: $err"
        return 0
    }
    set S(port) $bound
    fconfigure $S(server) -blocking 0
    set url "http://127.0.0.1:$bound/"
    ::jtagid::web::note "listening on $url"
    # hand the URL to the launcher (jtagid_gui.cmd) so it can open the browser
    catch {
        set dir [file join $::env(LOCALAPPDATA) jtag_identify]
        file mkdir $dir
        set fh [open [file join $dir web_url.txt] w]
        puts $fh $url
        close $fh
    }
    puts "================================================================"
    ::jtagid::web::note "ready: $url"
    puts " jtagid web GUI is running"
    puts "   $url"
    puts "   (Vivado [lindex [split [::jtagid::probe_compat_note] { }] 0], BSDL dir [::jtagid::web::default_bsdl_dir])"
    puts "   close this window or press Ctrl+C to stop"
    puts "================================================================"
    flush stdout
    if {[info exists ::env(JTAGID_NO_BROWSER)] && $::env(JTAGID_NO_BROWSER) ne ""} {
        puts "jtagid: not opening a browser (JTAGID_NO_BROWSER is set)"
    } else {
        ::jtagid::web::open_browser $url
    }
    vwait ::jtagid::web::forever
    return 1
}

#==============================================================================
# entry point
#==============================================================================

::jtagid::web::note "jtagid_web_gui.tcl entered" 1
::jtagid::web::start
::jtagid::web::note "start returned (server not running)"
