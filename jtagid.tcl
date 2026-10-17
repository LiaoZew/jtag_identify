###############################################################################
# jtagid.tcl -- JTAG boundary-scan identification driver for the Vivado Tcl
#               console (pure Tcl, no Python, no bitstream download)
#
# What it does: identifies the FPGA model on the scan chain through
# IEEE 1149.1 boundary scan:
#         IDCODE (read from DR right after TAP reset)  ->  BSDL lookup
#         ->  model / package / instruction length / BSR length
#
# Usage (inside Vivado's Tcl Console):
#         source D:/work2026/ai/opencode/jtag_identify/jtagid.tcl
#         jtagid help
#         jtagid version
#         jtagid identify
#
# Notes:
#   * ASCII-only on purpose: Vivado's Tcl `source` decodes the file with the
#     system code page (cp936 here), so non-ASCII comments/strings can be
#     mis-decoded and break the parser. Keep this file ASCII.
#   * Auto-detects the Vivado/Tcl version and which hardware commands exist
#     (load_features labtools, open_hw_manager vs legacy open_hw, the
#     connect_hw_server option set).
#   * When the client cannot talk to an older hw_server
#     ("[Labtools 27-3366] Cannot support older hw_server version"), it starts
#     its own hw_server of the SAME version as the client on a free port.
#   * The BSDL directory index is cached on disk, so the second call is fast.
#
# 2026-10
###############################################################################

namespace eval ::jtagid {
    variable state
    array set state {
        url           localhost:3121
        bsdl_dir      ""
        cache_dir     ""
        own_server    ""
        quiet         0
    }
    variable BSDL        ;# bsdl,<path> -> idcode pattern
    variable compat      ;# compatibility probe results
}

#==============================================================================
# small helpers
#==============================================================================

proc ::jtagid::log {msg} {
    variable state
    if {!$state(quiet)} { puts $msg }
}

proc ::jtagid::find_tool {name} {
    # 1) next to the running Vivado executable (walk up a few levels)
    set dir [file dirname [file normalize [info nameofexecutable]]]
    foreach up {. .. ../.. ../../..} {
        foreach ext {.bat .exe {}} {
            set cand [file normalize [file join $dir $up $name$ext]]
            if {[file exists $cand]} { return $cand }
        }
    }
    # 2) PATH lookup, resolved to an absolute path when possible
    foreach cand [list $name.bat $name.exe $name] {
        if {[catch {set p [auto_execok $cand]}] || $p eq ""} { continue }
        if {[file pathtype $p] eq "absolute"} { return [file normalize $p] }
        if {[info exists ::env(PATH)]} {
            foreach d [split $::env(PATH) \;] {
                set full [file join $d $cand]
                if {[file exists $full]} { return [file normalize $full] }
            }
        }
        return $p
    }
    return ""
}

proc ::jtagid::read_text {path {limit 0}} {
    set fh [open $path r]
    fconfigure $fh -encoding utf-8 -translation auto
    if {$limit > 0} {
        set text [read $fh $limit]
    } else {
        set text [read $fh]
    }
    close $fh
    return $text
}

proc ::jtagid::strip_comments {text} {
    # BSDL comments run from "--" to end of line (never inside quotes).
    # "--" before the pattern stops regsub from reading it as an option.
    return [regsub -all -- {--[^\n]*} $text ""]
}

proc ::jtagid::quoted_concat {body} {
    set out ""
    foreach {- chunk} [regexp -all -inline {"([^"]*)"} $body] { append out $chunk }
    return $out
}

proc ::jtagid::walk {dir pattern outVar} {
    upvar 1 $outVar out
    if {![file isdirectory $dir]} { return }
    foreach entry [lsort [glob -nocomplain -directory $dir -types f *]] {
        if {[string match -nocase $pattern [file tail $entry]]} { lappend out $entry }
    }
    foreach sub [lsort [glob -nocomplain -directory $dir -types d *]] {
        ::jtagid::walk $sub $pattern out
    }
}

proc ::jtagid::table {headers rows} {
    set widths {}
    foreach h $headers { lappend widths [string length $h] }
    foreach row $rows {
        set i 0
        foreach cell $row {
            set len [string length $cell]
            if {$len > [lindex $widths $i]} { set widths [lreplace $widths $i $i $len] }
            incr i
        }
    }
    set line ""
    set i 0
    foreach h $headers {
        append line [format "%-*s  " [lindex $widths $i] $h]
        incr i
    }
    ::jtagid::log [string trimright $line]
    set line ""
    set i 0
    foreach h $headers {
        append line [string repeat - [lindex $widths $i]]
        append line "  "
        incr i
    }
    ::jtagid::log [string trimright $line]
    foreach row $rows {
        set line ""
        set i 0
        foreach cell $row {
            append line [format "%-*s  " [lindex $widths $i] $cell]
            incr i
        }
        ::jtagid::log [string trimright $line]
    }
}

proc ::jtagid::bits_to_int {bits} {
    # Tcl 8.5 (Vivado 2018.3) has no 0b literal in expr, so parse by hand
    set value 0
    foreach ch [split $bits ""] {
        if {$ch ne "0" && $ch ne "1"} { continue }
        set value [expr {($value << 1) | $ch}]
    }
    return $value
}

proc ::jtagid::int_to_bits {value {width 32}} {
    # Tcl 8.5 (Vivado 2018.3) has no %b in format and no "0b" in expr, so both
    # directions are implemented by hand. This bit the 2018.3 console with
    # 'bad field specifier "b"'.
    set out ""
    for {set i [expr {$width - 1}]} {$i >= 0} {incr i -1} {
        append out [expr {($value >> $i) & 1}]
    }
    return $out
}

proc ::jtagid::to_hex {value} {
    # Vivado reports IDCODE as a 32-character binary string; accept hex too
    set text [string trim [string trim $value] "\""]
    if {[regexp {^[01]{32}$} $text]} {
        return [format 0x%08X [::jtagid::bits_to_int $text]]
    }
    if {[regexp {0[xX][0-9A-Fa-f]+} $text hex]} { return [format 0x%08X $hex] }
    if {[regexp {^\d+$} $text]} { return [format 0x%08X $text] }
    return ""
}

proc ::jtagid::hex_value {hex} { return [expr {$hex}] }

proc ::jtagid::decode_idcode {hex} {
    set v [::jtagid::hex_value $hex]
    set version [expr {($v >> 28) & 0xF}]
    set part    [expr {($v >> 12) & 0xFFFF}]
    set family  [expr {$part >> 9}]
    set array   [expr {$part & 0x1FF}]
    set mfg     [expr {($v >> 1) & 0x7FF}]
    return [dict create version $version family $family array $array mfg $mfg part $part]
}

proc ::jtagid::mfg_name {mfg} {
    # switch compares strings, so compare the formatted hex form
    switch -- [format %03X $mfg] {
        049 { return Xilinx }
        23B { return ARM }
        00E { return Altera/Intel }
        061 { return Lattice }
        020 { return TI }
        default { return "?" }
    }
}

proc ::jtagid::grade_norm {name} {
    # Xilinx encodes commercial/automotive/defense grade in the 2nd letter
    # (xc / xa / xq): same silicon, same IDCODE -> normalize for comparison
    set text [string toupper $name]
    if {[string length $text] > 1} { return [string replace $text 1 1 ?] }
    return $text
}

#==============================================================================
# version / compatibility probe
#==============================================================================

proc ::jtagid::probe_compat {{force 0}} {
    variable compat
    if {!$force && [info exists compat(vivado)]} { return [array get compat] }
    array unset compat
    set compat(vivado) [expr {[catch {version -short} v] ? "unknown" : $v}]
    set compat(tcl) [info patchlevel]
    set compat(load_features) [expr {[llength [info commands load_features]] > 0}]
    set compat(has_labtools) 0
    if {$compat(load_features)} {
        if {![catch {load_features labtools} err]} {
            set compat(has_labtools) 1
        } else {
            set compat(labtools_error) $err
        }
    }
    # Hardware-manager commands only exist after "load_features labtools";
    # very old versions expose only the legacy "open_hw" command, and the
    # 2018.3 batch flow exposes neither (measured on this machine).
    set compat(open_hw_manager) [expr {[llength [info commands open_hw_manager]] > 0}]
    set compat(open_hw)        [expr {[llength [info commands open_hw]] > 0}]
    set compat(hw_commands)    [expr {[llength [info commands get_hw_devices]] > 0}]
    set compat(batch)          [expr {![info exists ::tcl_interactive] || !$::tcl_interactive}]
    set compat(hw_server)      [::jtagid::find_tool hw_server]
    set compat(exe_dir)        [file dirname [file normalize [info nameofexecutable]]]
    return [array get compat]
}

proc ::jtagid::probe_compat_note {} {
    set c [::jtagid::probe_compat]
    set note [dict get $c vivado]
    if {![dict get $c hw_commands]} { append note " (no hardware commands in this session)" }
    return $note
}

proc ::jtagid::labtools_ready {} {
    # Real hardware commands only work after open_hw_manager; before that they
    # either raise [Labtoolstcl 44-235] or just warn with 44-133/44-132, so the
    # only reliable strategy is to call open_hw_manager unconditionally once.
    variable state
    return [expr {[info exists state(manager_opened)] && $state(manager_opened)}]
}

proc ::jtagid::ensure_manager {} {
    variable state
    if {[::jtagid::labtools_ready]} { return 1 }
    if {[llength [info commands open_hw_manager]] == 0} {
        ::jtagid::probe_compat 1
        if {[llength [info commands open_hw_manager]] == 0 && \
            [llength [info commands open_hw]] > 0} {
            catch {open_hw}
        }
    }
    catch {open_hw_manager} err
    set state(last_error) $err
    if {[llength [info commands get_hw_devices]] > 0} {
        set state(manager_opened) 1
        return 1
    }
    return 0
}

proc ::jtagid::parse_opts {optsVar argList defaults} {
    # array set cannot handle bare switches such as -refresh / -shutdown-own
    upvar 1 $optsVar opts
    array set opts $defaults
    set i 0
    set n [llength $argList]
    while {$i < $n} {
        set key [lindex $argList $i]
        if {![string match -* $key]} { incr i; continue }
        set value ""
        if {[expr {$i + 1}] < $n} { set value [lindex $argList [expr {$i + 1}]] }
        # A bare switch (-refresh) is only assumed when nothing follows or the
        # next token is another option.  An EMPTY token is a real value, so
        # "-bsdl-dir {} -part {}" keeps its shape instead of shifting everything.
        if {[expr {$i + 1}] >= $n || [string match -* $value]} {
            set opts($key) 1
            incr i
        } else {
            set opts($key) $value
            incr i 2
        }
    }
    return
}

proc ::jtagid::require_hw {cmd} {
    ::jtagid::probe_compat
    variable compat
    if {!$compat(hw_commands)} {
        if {!$compat(open_hw_manager) && $compat(open_hw)} { catch {open_hw} }
        if {![catch {open_hw_manager}]} { ::jtagid::probe_compat 1 }
    }
    if {!$compat(hw_commands)} {
        set msg "No hardware-manager commands in this session (Vivado $compat(vivado), batch=$compat(batch))."
        append msg "\n  * They appear after a successful 'load_features labtools'."
        if {[info exists compat(labtools_error)]} {
            append msg "\n  * load_features said: $compat(labtools_error)"
        }
        append msg "\n  * Try manually: load_features labtools ; open_hw_manager ; then rerun $cmd"
        append msg "\n  * In the GUI it is enough to open the Hardware Manager once."
        append msg "\n  * Only bsdl-match / bsdl-index / bsdl-dir work without hardware commands"
        return -code error $msg
    }
    if {[::jtagid::ensure_manager]} { return 1 }
    variable state
    set msg "open_hw_manager could not initialize the labtools system."
    if {[info exists state(last_error)] && $state(last_error) ne ""} {
        append msg "\n  $state(last_error)"
    }
    append msg "\n  * In the GUI just run: open_hw_manager   then retry $cmd"
    return -code error $msg
}

#==============================================================================
# hw_server connection / target opening
#==============================================================================

proc ::jtagid::servers_connected {} {
    if {[catch {set s [get_hw_servers]}]} { return 0 }
    return [expr {[llength $s] > 0}]
}

proc ::jtagid::free_port {} {
    # prefer the default hw_server port so the URL stays familiar
    for {set p 3121} {$p < 3200} {incr p} {
        if {[catch {set c [socket 127.0.0.1 $p]}]} { return $p } else { close $c }
    }
    return 3121
}

proc ::jtagid::wait_port {port timeoutSec} {
    set deadline [expr {[clock milliseconds] + $timeoutSec * 1000}]
    while {[clock milliseconds] < $deadline} {
        if {![catch {set c [socket 127.0.0.1 $port]}]} { close $c; return 1 }
        after 400
    }
    return 0
}

proc ::jtagid::start_own_server {} {
    variable state
    set exe [::jtagid::find_tool hw_server]
    if {$exe eq ""} { return "" }
    set port [::jtagid::free_port]
    # Detach properly. Two things matter on Windows:
    #  * Tcl's exec captures stdout/stderr through pipes, so the child MUST NOT
    #    inherit them, otherwise exec blocks until the (long lived) hw_server
    #    exits. Everything is redirected to NUL.
    #  * "cmd /c start" with Tcl's exec proved unreliable here, so the launcher
    #    is PowerShell's Start-Process, which returns immediately.
    set exePs [string map {\\ /} $exe]
    set ps "Start-Process -FilePath '$exePs' -ArgumentList '-s','tcp::$port' -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id"
    set ok 0
    set pid ""
    if {![catch {set out [exec powershell -NoProfile -ExecutionPolicy Bypass -Command $ps \
                             2> NUL]} err]} {
        set ok 1
        if {[regexp {\d+} $out pid]} { set state(own_server_pid) $pid }
    } else {
        # fallback: cmd start, still fully redirected
        if {![catch {exec cmd /c start "jtagid_hw_server" /b $exe -s tcp::$port \
                        > NUL 2> NUL} err]} { set ok 1 }
    }
    if {!$ok} {
        ::jtagid::log "    failed to start hw_server: $err"
        return ""
    }
    if {![::jtagid::wait_port $port 30]} {
        ::jtagid::log "    hw_server did not come up on port $port"
        return ""
    }
    set state(own_server) "localhost:$port"
    ::jtagid::log "    started own hw_server (same version as this Vivado): $exe -s tcp::$port"
    return "localhost:$port"
}

proc ::jtagid::connect {args} {
    variable state
    ::jtagid::require_hw "jtagid connect"
    ::jtagid::parse_opts opts $args {-url "" -own-server 1}
    set url [expr {$opts(-url) ne "" ? $opts(-url) : $state(url)}]
    set had_server [::jtagid::servers_connected]

    if {$had_server} {
        ::jtagid::log "    hw_server already connected"
        set state(url) $url
        return $url
    }

    set errors {}
    # 1) direct connect: try the newer option set first, then the plain form
    foreach opt [list [list -url $url -allow_non_jtag] [list -url $url]] {
        if {![catch {eval connect_hw_server $opt} err]} {
            if {[::jtagid::servers_connected]} {
                set state(url) $url
                set state(spawned_url) $url   ;# Vivado may have launched hw_server
                return $url
            }
        } else {
            lappend errors $err
        }
    }

    # 2) version mismatch / no server -> start one that matches this client
    set joined [join $errors " | "]
    set mismatch [regexp {27-3(366|365)|older hw_server|version} $joined]
    if {$opts(-own-server)} {
        if {$mismatch} { ::jtagid::log "    existing server is incompatible, starting our own: $joined" }
        set own [::jtagid::start_own_server]
        if {$own ne ""} {
            if {![catch {connect_hw_server -url $own} err]} {
                if {[::jtagid::servers_connected]} { set state(url) $own; return $own }
            } else {
                lappend errors $err
            }
        }
    }
    set msg "Cannot connect to hw_server:"
    foreach e $errors { append msg "\n  $e" }
    append msg "\n  Try: jtagid connect -url tcp::3121  (or make sure hw_server is running)"
    return -code error $msg
}

proc ::jtagid::ensure_target {} {
    if {[llength [get_hw_devices]] > 0} { return 1 }
    foreach t [get_hw_targets] {
        if {[catch {current_hw_target $t}]} { continue }
        catch {open_hw_target}    ;# errors if already open (GUI): ignore
        if {[llength [get_hw_devices]] > 0} { return 1 }
    }
    foreach t [get_hw_targets] {
        catch {current_hw_target $t}
        catch {refresh_hw_target $t}
    }
    return [expr {[llength [get_hw_devices]] > 0}]
}

proc ::jtagid::device_prop {device prop {default ""}} {
    # Ask list_property first: reading a property that a device does not have
    # makes Vivado print "[Labtoolstcl 44-56] ... does not have a [X] property"
    # even when the error is caught.
    if {[catch {set props [list_property $device]}]} { return $default }
    if {[lsearch -exact $props $prop] < 0} { return $default }
    if {[catch {set value [get_property $prop $device]}]} { return $default }
    return $value
}

proc ::jtagid::devices {} {
    set out {}
    foreach d [get_hw_devices] {
        set rec [dict create name $d part "" idcode "" usercode "" raw ""]
        dict set rec part [::jtagid::device_prop $d PART]
        foreach key {IDCODE REGISTER.IDCODE} {
            if {[dict get $rec idcode] ne ""} { break }
            set raw [::jtagid::device_prop $d $key]
            if {$raw eq ""} { continue }
            set hex [::jtagid::to_hex $raw]
            if {$hex ne ""} {
                dict set rec idcode $hex
                dict set rec raw $raw
            }
        }
        dict set rec usercode [::jtagid::device_prop $d USERCODE]
        lappend out $rec
    }
    return $out
}

#==============================================================================
# BSDL: index + IDCODE lookup
#==============================================================================

proc ::jtagid::device_records {} {
    # One record per TAP in the shape the report and the GUI both use:
    #   {name part idcode family array mfg fpga}
    # ::jtagid::devices returns only name/part/idcode/usercode/raw, so anything
    # rendering a device list has to come through here (a missing key used to
    # make the Tk side throw while redrawing and left the window stuck).
    set out {}
    foreach d [::jtagid::devices] {
        set idc [dict get $d idcode]
        set family ""; set array ""; set mfgn ""; set isfpga 0
        if {$idc ne ""} {
            set f [::jtagid::decode_idcode $idc]
            set family [dict get $f family]
            set array  [dict get $f array]
            set mfgn   [::jtagid::mfg_name [dict get $f mfg]]
            if {[dict get $f mfg] == 0x049} { set isfpga 1 }
        }
        lappend out [dict create name [dict get $d name] part [dict get $d part] \
            idcode $idc family $family array $array mfg $mfgn fpga $isfpga]
    }
    return $out
}

#==============================================================================
# device <-> BSDL bindings
#
# What the GUI writes when you pick a BSDL after identifying: which device (by
# IDCODE) is described by which BSDL file, so the answer is reusable later:
#   jtagid bind                       list them
#   jtagid bind -idcode 0x14710093 -bsdl <path>
#   jtagid bsdl-for                   print the BSDL bound to the FPGA on the chain
# File: <cache dir>/bindings.txt, one tab separated record per line.
#==============================================================================

proc ::jtagid::bindings_file {} {
    set cache [::jtagid::cache_file]
    return [file join [file dirname $cache] bindings.txt]
}

proc ::jtagid::binding_list {} {
    set out {}
    set f [::jtagid::bindings_file]
    if {![file exists $f]} { return $out }
    if {[catch {open $f r} fh]} { return $out }
    catch {
        fconfigure $fh -encoding utf-8
        while {[gets $fh line] >= 0} {
            set line [string trimright $line "\r\n"]
            if {$line eq "" || [string index $line 0] eq "#"} { continue }
            set p [split $line \t]
            if {[llength $p] < 6} { continue }
            lappend out [dict create idcode [lindex $p 0] device [lindex $p 1] \
                part [lindex $p 2] die [lindex $p 3] package [lindex $p 4] \
                bsdl [lindex $p 5] when [lindex $p 6]]
        }
        close $fh
    }
    return $out
}

proc ::jtagid::binding_write {rows} {
    set f [::jtagid::bindings_file]
    catch {file mkdir [file dirname $f]}
    set tmp "$f.tmp"
    set fh [open $tmp w]
    fconfigure $fh -encoding utf-8
    puts $fh "# jtagid device <-> BSDL bindings"
    puts $fh "# idcode\tdevice\tpart\tdie\tpackage\tbsdl\twhen"
    foreach b $rows {
        puts $fh "[dict get $b idcode]\t[dict get $b device]\t[dict get $b part]\t[dict get $b die]\t[dict get $b package]\t[dict get $b bsdl]\t[dict get $b when]"
    }
    close $fh
    file rename -force $tmp $f
    return
}

proc ::jtagid::binding_get {idcode} {
    set key [string tolower [string trim $idcode]]
    if {$key eq ""} { return "" }
    foreach b [::jtagid::binding_list] {
        if {[string tolower [dict get $b idcode]] eq $key} { return $b }
    }
    return ""
}

proc ::jtagid::binding_set {idcode device part die package bsdl {when ""}} {
    if {$idcode eq "" || $bsdl eq ""} { return -code error "binding needs an idcode and a BSDL path" }
    if {$when eq ""} { set when [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] }
    set key [string tolower [string trim $idcode]]
    set out {}
    foreach b [::jtagid::binding_list] {
        if {[string tolower [dict get $b idcode]] ne $key} { lappend out $b }
    }
    set rec [dict create idcode $idcode device $device part $part die $die \
                 package $package bsdl [string map {\\ /} $bsdl] when $when]
    lappend out $rec
    ::jtagid::binding_write $out
    return $rec
}

proc ::jtagid::binding_clear {idcode} {
    set key [string tolower [string trim $idcode]]
    set out {}
    foreach b [::jtagid::binding_list] {
        if {[string tolower [dict get $b idcode]] ne $key} { lappend out $b }
    }
    ::jtagid::binding_write $out
    return
}

proc ::jtagid::default_bsdl_dir {} {
    # The BSDL tree lives with the tool: ./bsdl, relative to wherever Vivado was
    # started.  Kept RELATIVE on purpose (no absolute paths, no guessing at
    # ../vivado_tools/bsdl any more).  Second choice is bsdl/ next to this
    # script, so it also works when Vivado was started somewhere else.
    # Point it anywhere with:  jtagid bsdl-dir <dir>
    foreach cand [list "bsdl" [file join [file dirname [file normalize [info script]]] bsdl]] {
        if {[file isdirectory $cand]} { return $cand }
    }
    return "bsdl"
}

proc ::jtagid::cache_file {} {
    variable state
    if {$state(cache_dir) eq ""} {
        if {[info exists ::env(LOCALAPPDATA)]} {
            set state(cache_dir) [file join $::env(LOCALAPPDATA) jtag_identify]
        } else {
            set state(cache_dir) [file join $::env(TEMP) jtag_identify]
        }
    }
    if {![file isdirectory $state(cache_dir)]} { catch {file mkdir $state(cache_dir)} }
    return [file join $state(cache_dir) bsdl_index_tcl.txt]
}

proc ::jtagid::bsdl_pattern_of_file {path} {
    # Perf note: Tcl's -nocase regexp on a large string is very slow, so the
    # attribute is located with "string first" and the regexp only runs on a
    # small window after it. IDCODE_REGISTER sits at a median offset of 39KB in
    # the Xilinx tree (max ~84KB), so read in 64KB steps and stop early.
    set fh ""
    if {[catch {open $path r} fh]} { return "" }
    fconfigure $fh -encoding utf-8 -translation auto
    set text ""
    set pos -1
    for {set step 0} {$step < 8} {incr step} {
        set more [read $fh 65536]
        if {$more eq ""} { break }
        append text $more
        set pos [string first "IDCODE_REGISTER" $text]
        if {$pos >= 0} { break }
    }
    close $fh
    if {$pos < 0} { return "" }
    set window [string range $text $pos [expr {$pos + 4096}]]
    # NOTE: Tcl's regexp uses leftmost-longest semantics, so a lazy "(.*?);"
    # still prefers the LONGEST overall match and would run past the real ";"
    # into the next attribute. A negated class stops deterministically.
    if {![regexp -nocase {IDCODE_REGISTER\s+of\s+\S+\s*:\s*entity\s+is([^;]*);} \
              $window -> body]} {
        set window [string range $text $pos [expr {$pos + 32768}]]
        if {![regexp -nocase {IDCODE_REGISTER\s+of\s+\S+\s*:\s*entity\s+is([^;]*);} \
                  $window -> body]} { return "" }
    }
    set pattern [::jtagid::quoted_concat [::jtagid::strip_comments $body]]
    regsub -all {[^01Xx]} $pattern "" pattern
    return [string toupper $pattern]
}

proc ::jtagid::bsdl_index {{rebuild 0}} {
    variable state
    variable BSDL
    set dir $state(bsdl_dir)
    if {$dir eq ""} { set dir [::jtagid::default_bsdl_dir]; set state(bsdl_dir) $dir }
    if {$dir eq "" || ![file isdirectory $dir]} {
        # say which path it looked at: the default is the RELATIVE ./bsdl, so a
        # wrong working directory is the usual reason
        return -code error "BSDL directory not found: '$dir' (looked relative to [pwd]; set it with: jtagid bsdl-dir <dir>)"
    }
    set cache [::jtagid::cache_file]

    if {!$rebuild && [file exists $cache]} {
        set fh [open $cache r]
        fconfigure $fh -encoding utf-8
        set stamp [string trim [gets $fh]]
        if {$stamp eq [file normalize $dir]} {
            set count 0
            while {[gets $fh line] >= 0} {
                set parts [split $line \t]
                if {[llength $parts] < 2} { continue }
                set BSDL([lindex $parts 1]) [lindex $parts 0]
                incr count
            }
            close $fh
            if {$count > 0} {
                # The tree may have moved since the cache was written (it did on
                # this machine): cached paths then fail with "couldn't open ..."
                # in the middle of identify.  Checking 840 paths costs ~10 ms.
                set stale 0
                foreach p [array names BSDL] {
                    if {![file exists $p]} { unset BSDL($p); incr stale }
                }
                if {$stale == 0} { return $count }
                ::jtagid::log "    $stale cached BSDL path(s) no longer exist - rebuilding the index"
            }
        } else {
            close $fh
        }
    }

    array unset BSDL      ;# never keep hits from an earlier location around
    set files {}
    ::jtagid::walk $dir *.bsd  files
    ::jtagid::walk $dir *.bsdl files
    set files [lsort -unique $files]
    set count 0
    set total [llength $files]
    set t0 [clock milliseconds]
    set fh [open $cache w]
    fconfigure $fh -encoding utf-8
    puts $fh [file normalize $dir]
    set done 0
    foreach f $files {
        incr done
        set pattern [::jtagid::bsdl_pattern_of_file $f]
        if {$pattern eq ""} { continue }
        set BSDL($f) $pattern
        puts $fh "$pattern\t$f"
        incr count
        if {($done % 100) == 0} {
            flush $fh
            set dt [expr {[clock milliseconds] - $t0}]
            ::jtagid::log "    indexing $done/$total ... (${dt} ms)"
            flush stdout
        }
    }
    close $fh
    return $count
}

proc ::jtagid::bsdl_details {path} {
    set d [dict create path $path entity "" irl 0 bsr 0 package "" cells 0 missing 0]
    # a BSDL that disappeared (moved tree, deleted file) must not abort identify
    if {[catch {set text [::jtagid::read_text $path]} err]} {
        dict set d missing 1
        return $d
    }
    if {[regexp -nocase {attribute\s+IDCODE_REGISTER\s+of\s+(\S+)\s*:} $text -> ent]} {
        dict set d entity $ent
    } elseif {[regexp -nocase {entity\s+(\S+)\s+is} $text -> ent]} {
        dict set d entity $ent
    }
    if {[regexp -nocase {attribute\s+INSTRUCTION_LENGTH\s+of\s+\S+\s*:\s*entity\s+is\s+(\d+)} \
              $text -> irl]} { dict set d irl $irl }
    if {[regexp -nocase {attribute\s+BOUNDARY_LENGTH\s+of\s+\S+\s*:\s*entity\s+is\s+(\d+)} \
              $text -> bsr]} { dict set d bsr $bsr }
    # package: ZynqMP uses generic (PHYSICAL_PIN_MAP ...) + constant PIN_MAP_STRING,
    # 7 series uses the constant name, some vendors use an attribute
    set package ""
    if {[regexp {generic\s*\(\s*PHYSICAL_PIN_MAP\s*:\s*string\s*:=\s*"([^"]+)"} $text -> pkg]} {
        set package $pkg
    }
    if {$package eq "" && \
        [regexp -nocase {attribute\s+PHYSICAL_PIN_MAP\s+of\s+\S+\s*:\s*entity\s+is\s+"([^"]+)"} \
             $text -> pkg]} { set package $pkg }
    if {$package eq "" && [regexp {constant\s+([A-Za-z_][A-Za-z_0-9]*)\s*:\s*PIN_MAP_STRING} \
             $text -> pkg]} { set package $pkg }
    if {$package eq "" && [regexp {^[^_]+_(.+)$} [dict get $d entity] -> pkg]} {
        if {[regexp {^[A-Z]{2,6}\d{3,4}[A-Z]?$} [string toupper $pkg]]} { set package $pkg }
    }
    dict set d package [string toupper $package]
    if {[regexp -nocase {attribute\s+BOUNDARY_REGISTER\s+of\s+\S+\s*:\s*entity\s+is([^;]*);} \
             $text -> body]} {
        set body [::jtagid::strip_comments $body]
        # count cell tuples "(BC_n, port, function, ...)" -- no nested parens
        dict set d cells [regexp -all {\([^()]*\)} $body]
    }
    return $d
}

proc ::jtagid::idcode_matches {pattern idcodeHex} {
    if {[string length $pattern] != 32} { return 0 }
    set bits [::jtagid::int_to_bits [::jtagid::hex_value $idcodeHex] 32]
    for {set i 0} {$i < 32} {incr i} {
        set p [string index $pattern $i]
        if {$p ne "X" && $p ne [string index $bits $i]} { return 0 }
    }
    return 1
}

proc ::jtagid::match_idcode {idcodeHex} {
    variable BSDL
    set hits {}
    foreach {path pattern} [array get BSDL] {
        if {[::jtagid::idcode_matches $pattern $idcodeHex]} { lappend hits $path }
    }
    return [lsort $hits]
}

proc ::jtagid::cmp_package {a b} {
    return [string compare [dict get $a package] [dict get $b package]]
}

#==============================================================================
# why two parts with the same IDCODE are still different - and what can tell
# them apart
#
# Measured on this machine (Vivado 2018.3), for XCZU3CG_SFVC784 vs
# XCZU3EG_SFVC784:
#   * the two BSDL files are byte identical after renaming the model
#     (same SHA-256), i.e. IDCODE, IRL, BSR, instruction opcodes, pin map and
#     boundary register all match -> boundary scan cannot tell them apart
#   * Vivado's own part database has the same numbers for both
#     (8820 slices, 70560 LUT, 360 DSP, 216 BRAM, 252 IOB, 3 MMCM) and only the
#     name/DEVICE differs -> the PL is identical too
#   * the difference is in the PS: CG has no GPU/VCU, EG has the Mali-400 GPU,
#     EV adds the VCU.  That is decided when the die is tested and sorted, and
#     nothing in the JTAG-visible space reports it.
#
# So the driver reports the die (which JTAG *can* prove) and then spells out
# the remaining SKU choice, instead of pretending a single model.
#==============================================================================

proc ::jtagid::model_of {entity} {
    # XCZU3EG_SFVC784 -> XCZU3EG
    return [lindex [split $entity _] 0]
}

proc ::jtagid::sku_traits {model} {
    # Trailing letters of a Zynq UltraScale+ MPSoC part.  Product table
    # knowledge, not something the silicon reports.
    set m [string toupper $model]
    if {[regexp {ZU\d+([A-Z]{2})} $m -> suffix]} {
        switch -- $suffix {
            CG { return [dict create desc "CG: no GPU, no VCU" ps_gpu 0 ps_vcu 0] }
            EG { return [dict create desc "EG: Mali-400 GPU (no VCU)" ps_gpu 1 ps_vcu 0] }
            EV { return [dict create desc "EV: Mali-400 GPU + VCU codec" ps_gpu 1 ps_vcu 1] }
            default { return [dict create desc "$suffix" ps_gpu ? ps_vcu ?] }
        }
    }
    return [dict create desc "" ps_gpu ? ps_vcu ?]
}

proc ::jtagid::die_of {models} {
    # A display label for the die: the common part of the sibling model names
    # with the grade letter removed (XCZU3CG + XCZU3EG -> ZU3).
    if {[llength $models] == 0} { return "" }
    if {[llength $models] == 1} { return [lindex $models 0] }
    set norm {}
    foreach m $models { lappend norm [::jtagid::grade_norm [string toupper $m]] }
    set p [lindex $norm 0]
    foreach m $norm {
        set lim [expr {[string length $p] < [string length $m] ? [string length $p] : [string length $m]}]
        set n 0
        while {$n < $lim && [string index $p $n] eq [string index $m $n]} { incr n }
        set p [string range $p 0 [expr {$n - 1}]]
    }
    # drop the normalised grade letter and any trailing model letters
    set p [string map [list ? ""] $p]
    while {[string length $p] > 0 && [string is alpha [string index $p end]]} {
        set p [string range $p 0 end-1]
    }
    # and the leading XC/XA/XQ/X of the grade
    regsub {^X[CQA]?} $p {} p
    return $p
}

proc ::jtagid::pl_resources {model package} {
    # Ask Vivado's own part database whether such a part exists and what it
    # contains.  Returns {} when the part is unknown here.
    if {[llength [info commands get_parts]] == 0} { return "" }
    set m [string tolower $model]
    if {$package ne ""} {
        set glob "$m-[string tolower $package]-*"
    } else {
        set glob "$m-*"
    }
    if {[catch {set hits [get_parts -quiet $glob]} err]} { return "" }
    if {[llength $hits] == 0} { return "" }
    set p [lindex $hits 0]
    set out [dict create part $p]
    foreach {key prop} {slices SLICES lut LUT_ELEMENTS ff FLIPFLOPS dsp DSP \
                            bram BLOCK_RAMS mmcm MMCM iob AVAILABLE_IOBS} {
        if {[catch {set v [get_property $prop $p]}]} { set v "?" }
        dict set out $key $v
    }
    return $out
}

proc ::jtagid::sku_analysis {models package} {
    # models: every BSDL model whose IDCODE pattern matched (the siblings)
    set models [lsort -unique $models]
    set out [dict create models $models decidable [expr {[llength $models] == 1}] \
                 die [::jtagid::die_of $models] package $package ps {} pl {} how {} note ""]
    foreach m $models {
        set t [::jtagid::sku_traits $m]
        dict lappend out ps "[format %-10s $m] [dict get $t desc]"
        set r [::jtagid::pl_resources $m $package]
        if {$r ne ""} {
            dict lappend out pl "[format %-10s $m] slices=[dict get $r slices] LUT=[dict get $r lut] DSP=[dict get $r dsp] BRAM=[dict get $r bram] MMCM=[dict get $r mmcm]"
        }
    }
    if {[dict get $out decidable]} {
        dict set out note "only one BSDL model matches this IDCODE"
        return $out
    }
    dict set out note "[llength $models] models share this IDCODE: [join $models {, }]"
    dict lappend out how "1) the chip itself: read the laser marking (it carries model, speed and temperature, e.g. XCZU3EG-1SFVC784I)"
    dict lappend out how "2) the board: BOM / schematic / silkscreen part number"
    dict lappend out how "3) PS side, if Linux runs: a Mali GPU is present only on EG/EV (device tree node gpu@fd4b0000, mali driver in dmesg); no GPU -> CG"
    dict lappend out how "4) pass what you know: jtagid identify -package <PKG> -part <partnumber>"
    return $out
}

proc ::jtagid::group_by_architecture {paths} {
    # group by package + IRL + BSR length + cell count: sibling models such as
    # XCZU3CG/XCZU3EG (same IDCODE, same BSR) merge, different packages stay apart
    set groups [dict create]
    foreach path $paths {
        set d [::jtagid::bsdl_details $path]
        set key "[dict get $d package]|[dict get $d irl]|[dict get $d bsr]|[dict get $d cells]"
        dict lappend groups $key $path
    }
    set out {}
    foreach {key group} $groups {
        set first [::jtagid::bsdl_details [lindex $group 0]]
        set models {}
        foreach path $group {
            set ent [dict get [::jtagid::bsdl_details $path] entity]
            set model [lindex [split $ent _] 0]
            if {[lsearch -exact $models $model] < 0} { lappend models $model }
        }
        lappend out [dict create \
            package [dict get $first package] \
            irl     [dict get $first irl] \
            bsr     [dict get $first bsr] \
            cells   [dict get $first cells] \
            models  [lsort $models] \
            paths   $group \
            primary [lindex $group 0]]
    }
    return [lsort -command ::jtagid::cmp_package $out]
}

#==============================================================================
# subcommands
#==============================================================================

proc ::jtagid::cmd_help {} {
    puts {
jtagid -- JTAG boundary-scan identification driver for Vivado (pure Tcl)

  jtagid help                       this help
  jtagid version                    Vivado/Tcl version + hardware-command probe
  jtagid status                     current connection / BSDL / own-server state

  jtagid open ?-url tcp::3121? ?-own-server 0|1?
                                    open the hardware manager and connect to hw_server
  jtagid scan ?-refresh?            list every TAP on the chain (name/PART/IDCODE)
  jtagid identify ?-package SFVC784? ?-part xazu3eg-sfvc784-1-i?
                                    identify the FPGA: IDCODE -> BSDL -> model/package
  jtagid close ?-shutdown-own?      disconnect (optionally kill the own hw_server)

  jtagid bsdl-dir ?dir?             show/set the BSDL directory
  jtagid bsdl-index ?-rebuild?      build/refresh the BSDL index (disk cached)
  jtagid bsdl-match 0x14710093      BSDL lookup by IDCODE only (no hardware)

  jtagid gui                        open the Tk window (tk_tunnel front end)
  jtagid gui-status                 is the window/backend service running?
  jtagid gui-stop                   stop the Tk front end (Vivado keeps running)

  jtagid bind                       list the device <-> BSDL bindings
  jtagid bind -idcode 0x14710093 -bsdl <path>
                                    bind a BSDL to a device
  jtagid bind -idcode 0x14710093 -clear
                                    forget a binding
  jtagid bsdl-for ?-idcode X?       print the BSDL bound to a device (scripts)

  The GUI is split: the Tk window is the front end, this Vivado session is the
  back end (it owns the cable).  Opening it does not block: the console keeps
  its prompt and the service stays resident until Vivado is closed.  Closing
  the window only hides it - run "jtagid gui" to bring it straight back.

  GUI flow: identify the FPGA, then a chooser opens with every filter, you pick
  a BSDL, and it is bound to the device (bindings.txt) so the answer is
  reusable: jtagid bsdl-for  prints the path.

Examples:
  source D:/work2026/ai/opencode/jtag_identify/jtagid.tcl
  jtagid version
  jtagid identify
  jtagid identify -package SFVC784 -part xazu3eg-sfvc784-1-i

Batch usage:
  vivado -mode batch -source jtagid.tcl -tclargs identify
  (the first tclarg is a subcommand: identify / scan / version / bsdl-index ...)
    }
}

proc ::jtagid::cmd_version {} {
    set c [::jtagid::probe_compat 1]
    puts "Vivado          : [dict get $c vivado]"
    puts "Tcl             : [dict get $c tcl]"
    puts "session mode    : [expr {[dict get $c batch] ? {batch} : {interactive/GUI}}]"
    puts "load_features   : [expr {[dict get $c load_features] ? {available} : {missing}}]"
    puts "  labtools      : [expr {[dict get $c has_labtools] ? {loaded} : {not loaded}}]"
    if {[dict exists $c labtools_error]} { puts "    reason      : [dict get $c labtools_error]" }
    puts "open_hw_manager : [expr {[dict get $c open_hw_manager] ? {available} : {missing}}]"
    puts "open_hw (legacy): [expr {[dict get $c open_hw] ? {available} : {missing}}]"
    puts "hw commands     : [expr {[dict get $c hw_commands] ? {available} : {missing}}]"
    puts "hw_server       : [expr {[dict get $c hw_server] ne {} ? [dict get $c hw_server] : {not found}}]"
    if {[::jtagid::servers_connected]} {
        foreach s [get_hw_servers] {
            set line "connected server: $s"
            catch {append line " version=[get_property VERSION $s]"}
            puts $line
        }
    } else {
        puts "connected server: none"
    }
    if {![dict get $c hw_commands]} {
        puts ""
        puts "This session has no hardware-manager commands (typical for 2018.3 batch mode)."
        puts "Source this file in the Vivado GUI Tcl Console, or use Vivado 2020.1+ in batch."
    }
    return $c
}

proc ::jtagid::cmd_status {} {
    variable state
    puts "hw_server url   : $state(url)"
    puts "own server      : [expr {$state(own_server) ne {} ? $state(own_server) : {none}}]"
    puts "BSDL directory  : [expr {$state(bsdl_dir) ne {} ? $state(bsdl_dir) : {auto}}]"
    puts "BSDL cache      : [::jtagid::cache_file]"
    variable BSDL
    puts "indexed entries : [expr {[info exists BSDL] ? [array size BSDL] : 0}]"
    return
}

proc ::jtagid::cmd_bsdl_dir {args} {
    variable state
    if {[llength $args] == 0} {
        set cur [expr {$state(bsdl_dir) ne {} ? $state(bsdl_dir) : [::jtagid::default_bsdl_dir]}]
        puts "BSDL directory  : $cur"
        return $cur
    }
    set dir [lindex $args 0]
    if {![file isdirectory $dir]} { return -code error "not a directory: $dir" }
    set state(bsdl_dir) [file normalize $dir]
    puts "BSDL directory set to: $state(bsdl_dir) (rebuilding index)"
    ::jtagid::bsdl_index 1
    return $state(bsdl_dir)
}

proc ::jtagid::cmd_bsdl_index {args} {
    ::jtagid::parse_opts opts $args {-rebuild 0}
    set t0 [clock milliseconds]
    set n [::jtagid::bsdl_index $opts(-rebuild)]
    set dt [expr {[clock milliseconds] - $t0}]
    puts "indexed $n BSDL files in ${dt} ms (cache: [::jtagid::cache_file])"
    return $n
}

proc ::jtagid::cmd_bsdl_match {idcode} {
    ::jtagid::bsdl_index
    if {![regexp -nocase {^(0x)?([0-9a-f]+)$} $idcode -> _ hex]} {
        return -code error "IDCODE must look like 0x12345678"
    }
    set value [format 0x%08X [expr "0x$hex"]]
    set hits [::jtagid::match_idcode $value]
    if {[llength $hits] == 0} {
        puts "$value: no matching device in the BSDL directory"
        return {}
    }
    puts "$value -> [llength $hits] file(s):"
    foreach group [::jtagid::group_by_architecture $hits] {
        puts "  * [join [dict get $group models] /]  package [dict get $group package]  IRL=[dict get $group irl] BSR=[dict get $group bsr] cells=[dict get $group cells]"
        foreach p [dict get $group paths] { puts "      $p" }
    }
    return $hits
}

proc ::jtagid::cmd_open {args} {
    ::jtagid::parse_opts opts $args {-url "" -own-server 1}
    ::jtagid::require_hw "jtagid open"
    catch {open_hw_manager}
    set url [::jtagid::connect -url $opts(-url) -own-server $opts(-own-server)]
    puts "connected: $url"
    if {![::jtagid::ensure_target]} {
        puts "warning: no hw_target/device enumerated (fine if the GUI already has it open)"
    }
    return $url
}

proc ::jtagid::cmd_scan {args} {
    ::jtagid::parse_opts opts $args {-refresh 0}
    ::jtagid::connect
    if {!$opts(-refresh) && [llength [get_hw_devices]] == 0} { ::jtagid::ensure_target }
    if {$opts(-refresh)} { ::jtagid::ensure_target }
    set devs [::jtagid::devices]
    if {[llength $devs] == 0} {
        puts "no devices enumerated on the chain."
        puts "  * if the Vivado GUI Hardware Manager already shows them, use that view"
        puts "  * otherwise check that the cable is not claimed by another process"
        return {}
    }
    foreach t [get_hw_targets] { puts "target: $t" }
    set rows {}
    set i 0
    foreach d $devs {
        incr i
        set idc [dict get $d idcode]
        set dec ""
        if {$idc ne ""} {
            set f [::jtagid::decode_idcode $idc]
            set dec "family=[dict get $f family] array=[dict get $f array] mfg=0x[format %03X [dict get $f mfg]] ([::jtagid::mfg_name [dict get $f mfg]])"
        }
        lappend rows [list $i [dict get $d name] [dict get $d part] $idc $dec]
    }
    ::jtagid::table {# device PART IDCODE decoded} $rows
    return $devs
}

proc ::jtagid::cmd_identify {args} {
    variable state
    ::jtagid::parse_opts opts $args {-package "" -part "" -quiet 0}
    set state(quiet) $opts(-quiet)

    puts "================ FPGA identification (boundary-scan IDCODE + BSDL) ================"
    puts "Vivado [::jtagid::probe_compat_note]"
    ::jtagid::connect
    ::jtagid::ensure_target

    set devs [::jtagid::devices]
    if {[llength $devs] == 0} {
        puts "no devices enumerated; run: jtagid scan"
        return -code error "no devices"
    }

    set fpga {}
    foreach d $devs {
        set idc [dict get $d idcode]
        if {$idc eq ""} { continue }
        if {[dict get [::jtagid::decode_idcode $idc] mfg] == 0x049} { lappend fpga $idc }
    }
    puts ""
    puts "chain devices:"
    foreach d $devs {
        set idc [dict get $d idcode]
        set extra ""
        if {$idc ne ""} {
            set f [::jtagid::decode_idcode $idc]
            set extra "[::jtagid::mfg_name [dict get $f mfg]] family=[dict get $f family] array=[dict get $f array]"
        }
        puts [format "  %-16s PART=%-12s IDCODE=%-12s %s" \
                  [dict get $d name] [dict get $d part] $idc $extra]
    }
    if {[llength $fpga] == 0} {
        puts ""
        puts "no Xilinx FPGA IDCODE (mfg=0x049) on the chain; cannot look up a model."
        return -code error "no xilinx fpga idcode"
    }

    puts ""
    puts "BSDL lookup:"
    set n [::jtagid::bsdl_index]
    puts "  directory $state(bsdl_dir) ($n files)"
    set chosen ""
    set chosen_path ""
    foreach idc $fpga {
        set hits [::jtagid::match_idcode $idc]
        if {[llength $hits] == 0} {
            puts "  $idc -> no BSDL match"
            continue
        }
        set groups [::jtagid::group_by_architecture $hits]
        set all_models {}
        set all_pkgs {}
        foreach g [::jtagid::group_by_architecture $hits] {
            foreach m [dict get $g models] {
                if {[lsearch -exact $all_models $m] < 0} { lappend all_models $m }
            }
            if {[lsearch -exact $all_pkgs [dict get $g package]] < 0} { lappend all_pkgs [dict get $g package] }
        }
        if {$opts(-package) ne ""} {
            set filtered {}
            foreach g $groups {
                if {[string equal -nocase [dict get $g package] $opts(-package)]} { lappend filtered $g }
            }
            if {[llength $filtered] > 0} {
                set groups $filtered
            } else {
                puts "    package $opts(-package): no BSDL here; this IDCODE comes in [join [lsort $all_pkgs] {, }]"
            }
        }
        puts "  $idc -> [llength $hits] file(s), [llength $groups] package group(s)"
        foreach g $groups {
            puts "    * [join [dict get $g models] /]  package [dict get $g package]  IRL=[dict get $g irl] BSR=[dict get $g bsr] cells=[dict get $g cells]"
            foreach p [dict get $g paths] { puts "        $p" }
        }

        # ---- what JTAG can and cannot decide -------------------------------
        set sku [::jtagid::sku_analysis $all_models $opts(-package)]
        puts ""
        puts "  die          : [dict get $sku die]    (from IDCODE $idc; the die is what boundary scan proves)"
        puts "  same IDCODE  : [join [dict get $sku models] { }]  ([llength [dict get $sku models]] model(s))"
        if {[dict get $sku decidable]} {
            puts "  verdict      : only one model carries this IDCODE - no ambiguity"
        } else {
            foreach line [dict get $sku ps] { puts "    PS         : [string trim $line]" }
            foreach line [dict get $sku pl] { puts "    PL         : [string trim $line]" }
            puts "  verdict      : these are the SAME die.  The BSDL files are byte identical"
            puts "                 after renaming the model, and Vivado's part database gives them"
            puts "                 the same PL resources, so IDCODE/BSDL/boundary scan cannot"
            puts "                 tell them apart - the SKU is fixed at test/sort time."
            puts "                 Settle it with:"
            foreach line [dict get $sku how] { puts "                   - $line" }
        }

        if {$opts(-part) ne ""} {
            set pl [split [string tolower $opts(-part)] -]
            set fam [string toupper [lindex $pl 0]]
            set pkg [string toupper [lindex $pl 1]]
            set norm [::jtagid::grade_norm $fam]
            set found ""
            foreach m $all_models {
                if {[::jtagid::grade_norm $m] eq $norm} { set found $m }
            }
            puts "    your PART  : $opts(-part) -> family=$fam package=$pkg"
            if {$found ne ""} {
                if {[string equal -nocase $fam $found]} {
                    puts "                 matches the BSDL model: $found"
                } else {
                    puts "                 grade letter differs: $fam corresponds to $found (same silicon/IDCODE)"
                }
                if {$pkg ne "" && [lsearch -exact $all_pkgs $pkg] < 0 && [llength $all_pkgs] > 0} {
                    puts "                 note: package $pkg is not in this BSDL tree ([join [lsort $all_pkgs] {, }])"
                }
                puts "                 -> recommended BSDL: the $found file below"
            } else {
                puts "                 no such model in this BSDL tree; trust the silicon IDCODE"
                puts "                 (automotive/defense numbers such as XAZU3EG map to XCZU3EG)"
            }
        }
        # prefer the part hint, then a single package, when picking a default
        if {$chosen eq ""} {
            set pick ""
            if {$opts(-part) ne ""} {
                set pl [split [string tolower $opts(-part)] -]
                set norm [::jtagid::grade_norm [string toupper [lindex $pl 0]]]
                set hintpkg [string toupper [lindex $pl 1]]
                foreach g $groups {
                    if {$hintpkg ne "" && [string toupper [dict get $g package]] ne $hintpkg} { continue }
                    foreach p [dict get $g paths] {
                        if {[::jtagid::grade_norm [::jtagid::model_of [dict get [::jtagid::bsdl_details $p] entity]]] eq $norm} {
                            set pick $p
                        }
                    }
                }
            }
            if {$pick ne ""} {
                foreach g $groups {
                    if {[lsearch -exact [dict get $g paths] $pick] >= 0} {
                        set chosen $g
                        set chosen_path $pick
                    }
                }
            } elseif {[llength $groups] == 1} {
                set chosen [lindex $groups 0]
            }
        }
    }

    puts ""
    puts "conclusion:"
    set parts {}
    foreach d $devs {
        if {[dict get $d part] ne ""} { lappend parts [dict get $d part] }
    }
    if {[llength $parts] > 0} {
        puts "  Vivado PART : [join $parts {, }]"
        foreach p $parts {
            if {[string first - $p] < 0 && [string equal -nocase $p xczu3]} {
                puts "                (family level only: an unconfigured device yields no full PART)"
            }
        }
    }
    if {$chosen ne ""} {
        puts "  model       : [join [dict get $chosen models] /]  package [dict get $chosen package]  (IRL=[dict get $chosen irl], BSR=[dict get $chosen bsr])"
        if {$chosen_path ne ""} {
            puts "  BSDL        : $chosen_path"
            puts "                (picked because it matches your -part hint)"
        } else {
            puts "  BSDL        : [dict get $chosen primary]"
        }
        if {[llength [dict get $chosen models]] > 1} {
            puts "                NOTE: [join [dict get $chosen models] /] are the same die, so any of these"
            puts "                BSDL files describes this chip electrically; for the exact ordering"
            puts "                code use the checklist above (chip marking or the PS GPU)."
        }
    } else {
        puts "  model       : ambiguous - narrow it with -package <PKG> or -part <partnumber>"
    }
    # a binding made in the GUI earlier is the answer to "which BSDL for me"
    set bound [::jtagid::binding_get [lindex $fpga 0]]
    if {$bound ne ""} {
        puts "  bound BSDL  : [dict get $bound bsdl]"
        puts "                (device [dict get $bound device], bound [dict get $bound when]; save it with: jtagid bsdl-for)"
    } else {
        puts "  bound BSDL  : none yet - pick one in the GUI (or: jtagid bind -idcode [lindex $fpga 0] -bsdl <path>)"
    }
    set state(quiet) 0
    return $chosen
}

proc ::jtagid::stop_spawned_server {} {
    variable state
    # 1) a server this driver started itself -> kill by captured pid
    if {[info exists state(own_server_pid)] && $state(own_server_pid) ne ""} {
        catch {exec taskkill /PID $state(own_server_pid) /T /F > NUL 2> NUL}
        puts "stopped the own hw_server (pid $state(own_server_pid))"
        set state(own_server_pid) ""
        set state(own_server) ""
        return 1
    }
    # 2) a server Vivado launched for us during this session -> kill by port,
    #    but only if we did not find a server already running when we connected
    if {[info exists state(spawned_url)] && $state(spawned_url) ne ""} {
        set port [lindex [split $state(spawned_url) :] end]
        set ps "(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue).OwningProcess | Select-Object -First 1"
        set pid ""
        if {![catch {set out [exec powershell -NoProfile -Command $ps 2> NUL]} err]} {
            regexp {\d+} $out pid
        }
        if {$pid ne ""} {
            catch {exec taskkill /PID $pid /T /F > NUL 2> NUL}
            puts "stopped the hw_server that this session launched (port $port, pid $pid)"
        }
        set state(spawned_url) ""
        return 1
    }
    return 0
}

proc ::jtagid::cmd_close {args} {
    variable state
    ::jtagid::parse_opts opts $args {-shutdown-own 0}
    catch {close_hw_target}
    catch {disconnect_hw_server}
    if {$opts(-shutdown-own)} {
        if {![::jtagid::stop_spawned_server]} {
            puts "no hw_server started by this session; nothing to stop"
        }
    } else {
        puts "note: -shutdown-own not given, a server started by this session stays up"
    }
    puts "disconnected from the hardware manager"
    return
}

proc ::jtagid::one_line {text} {
    # flatten multi-line messages for the tab separated report format
    return [string map [list "\r\n" " " "\n" " " "\r" " " "\t" " "] $text]
}

proc ::jtagid::cmd_gui {args} {
    # The GUI is the Xilinx TclStore bridge ::tclapp::xilinx::tk_tunnel: a real
    # Tk window in its own wish process (front end) driven from this Vivado
    # session (back end, which owns the cable).  Sourcing it does NOT block:
    # Vivado's IDE keeps servicing Tcl events while the console sits at its
    # prompt, so the window works and the console stays usable.
    #
    # vivado -mode tcl (the plain Tcl REPL) does not service events while it
    # waits for input, so the window cannot be answered there; jtagid_tk.cmd
    # opens the IDE instead.  The browser UI and the native dialog menu remain
    # as optional fallbacks.
    set compat [::jtagid::probe_compat 0]
    if {[dict get $compat batch]} {
        puts "note: this session looks like batch/-mode tcl; the Tk window needs the"
        puts "      Vivado IDE (only the IDE serves Tcl events while the console is idle)"
    }
    set here [file dirname [file normalize [info script]]]
    set tk [file join $here jtagid_tk_gui.tcl]
    if {[file exists $tk]} {
        uplevel #0 [list source $tk]
        return
    }
    set web [file join $here jtagid_web_gui.tcl]
    if {[file exists $web]} {
        uplevel #0 [list source $web]
        return
    }
    set gui [file join $here jtagid_gui.tcl]
    if {[file exists $gui]} {
        if {[catch {package require Tk} err]} {
            return -code error "no tk_tunnel GUI ($tk), no web GUI ($web) and no Tk ($err)"
        }
        uplevel #0 [list source $gui]
        return
    }
    return -code error "no GUI file found next to jtagid.tcl ($here)"
}

proc ::jtagid::cmd_bind {args} {
    # Remember (or show) which BSDL describes which device.
    #   jtagid bind                                              list
    #   jtagid bind -idcode 0x14710093 -bsdl <path>              bind
    #   jtagid bind -idcode 0x14710093 -clear                    forget
    # The GUI writes the same records when you pick a BSDL in the chooser.
    ::jtagid::parse_opts opts $args {-idcode "" -bsdl "" -device "" -part "" \
                                         -die "" -package "" -clear 0}
    if {$opts(-idcode) ne "" && $opts(-clear)} {
        ::jtagid::binding_clear $opts(-idcode)
        puts "cleared the binding for $opts(-idcode)"
        return
    }
    if {$opts(-idcode) ne "" && $opts(-bsdl) ne ""} {
        if {![file exists $opts(-bsdl)]} {
            return -code error "no such BSDL file: $opts(-bsdl)"
        }
        set rec [::jtagid::binding_set $opts(-idcode) $opts(-device) $opts(-part) \
                     $opts(-die) $opts(-package) $opts(-bsdl)]
        puts "bound: [dict get $rec idcode] ([dict get $rec device]) -> [dict get $rec bsdl]"
        puts "file  : [::jtagid::bindings_file]"
        return $rec
    }
    set rows [::jtagid::binding_list]
    if {[llength $rows] == 0} {
        puts "no bindings yet."
        puts "  bind one:   jtagid bind -idcode 0x14710093 -bsdl <path>"
        puts "  or pick one in the GUI (identify -> chooser -> use this BSDL)"
        return {}
    }
    puts "# device <-> BSDL bindings ([llength $rows])"
    foreach b $rows {
        puts [format "  %-12s %-12s die=%-6s pkg=%-8s %s" \
                  [dict get $b idcode] [dict get $b device] [dict get $b die] \
                  [dict get $b package] [dict get $b bsdl]]
    }
    puts "  file: [::jtagid::bindings_file]"
    return $rows
}

proc ::jtagid::cmd_bsdl_for {args} {
    # Print the BSDL bound to a device - script friendly (returns the path).
    #   jtagid bsdl-for                         the FPGA on the chain
    #   jtagid bsdl-for -idcode 0x14710093      a specific device
    ::jtagid::parse_opts opts $args {-idcode ""}
    set idc [string trim $opts(-idcode)]
    if {$idc eq ""} {
        set devs {}
        if {![catch {::jtagid::connect} e]} { catch {::jtagid::ensure_target}; set devs [::jtagid::device_records] }
        foreach d $devs {
            if {[dict get $d fpga] == 1} { set idc [dict get $d idcode]; break }
        }
        if {$idc eq ""} {
            return -code error "no FPGA IDCODE (pass -idcode, or connect the cable)"
        }
        puts "# FPGA on the chain: [lindex $devs 0]"
    }
    set rec [::jtagid::binding_get $idc]
    if {$rec eq ""} {
        return -code error "no BSDL is bound to $idc (bind one: jtagid bind -idcode $idc -bsdl <path>)"
    }
    puts "device: [dict get $rec device]  idcode: [dict get $rec idcode]  die: [dict get $rec die]  package: [dict get $rec package]"
    puts "BSDL  : [dict get $rec bsdl]"
    return [dict get $rec bsdl]
}

proc ::jtagid::cmd_gui_status {} {
    if {[llength [info commands ::jtagid::tkhost::status]] == 0} {
        puts "the tk_tunnel GUI is not loaded (start it with: jtagid gui)"
        return
    }
    puts [::jtagid::tkhost::status]
    return
}

proc ::jtagid::cmd_gui_stop {} {
    # stop the Tk front end; the Vivado session is untouched
    if {[llength [info commands ::jtagid::tkhost::stop]] == 0} {
        puts "the tk_tunnel GUI is not loaded, nothing to stop (start it with: jtagid gui)"
        return
    }
    ::jtagid::tkhost::stop
    return
}

proc ::jtagid::collect_report {args} {
    # Same work as "jtagid report" but returns a dict instead of printing:
    #   devices    list of dicts {name part idcode family array mfg fpga}
    #   candidates list of dicts {models package irl bsr cells path entity}
    #   info       dict {vivado url bsdl_dir bsdl_files idcode}
    #   part       dict {given matched message} or ""
    #   errors     list of messages
    variable state
    ::jtagid::parse_opts opts $args {-package "" -part "" -bsdl-dir "" -quiet 1}
    set prev_quiet $state(quiet)
    set state(quiet) $opts(-quiet)
    set res [dict create devices [list] candidates [list] info [dict create] part "" errors [list]]
    dict set res info vivado [::jtagid::probe_compat_note]
    if {$opts(-bsdl-dir) ne ""} {
        if {![file isdirectory $opts(-bsdl-dir)]} {
            dict lappend res errors "not a directory: $opts(-bsdl-dir)"
            set state(quiet) $prev_quiet
            return $res
        }
        set state(bsdl_dir) [file normalize $opts(-bsdl-dir)]
    }
    foreach step {connect ensure_target} {
        set err ""
        if {[catch {::jtagid::$step} out]} {
            dict lappend res errors [::jtagid::one_line $out]
        }
    }
    if {[llength [dict get $res errors]] > 0} {
        set state(quiet) $prev_quiet
        return $res
    }
    dict set res info url $state(url)
    set devs [::jtagid::devices]
    if {[llength $devs] == 0} {
        dict lappend res errors "no devices enumerated on the chain"
        set state(quiet) $prev_quiet
        return $res
    }
    set fpga {}
    foreach d [::jtagid::device_records] {
        # dict lappend, NOT lappend: res is a dict, and "lappend res devices $d"
        # appends to the dict-as-list, producing a malformed dict whose device
        # entries blow up with "missing value to go with key" when read back
        dict lappend res devices $d
        if {[dict get $d fpga] == 1} { lappend fpga [dict get $d idcode] }
    }
    if {[llength $fpga] == 0} {
        dict lappend res errors "no Xilinx FPGA IDCODE (mfg=0x049) on the chain"
        set state(quiet) $prev_quiet
        return $res
    }
    if {[catch {set count [::jtagid::bsdl_index]} err]} {
        dict lappend res errors [::jtagid::one_line $err]
        set state(quiet) $prev_quiet
        return $res
    }
    dict set res info bsdl_dir $state(bsdl_dir)
    dict set res info bsdl_files $count
    dict set res info idcode [lindex $fpga 0]
    # what the caller already knows about the part (board silkscreen / BOM)
    set want_pkg [string toupper $opts(-package)]
    set part_fam ""
    set part_pkg ""
    if {$opts(-part) ne ""} {
        set pl [split [string tolower $opts(-part)] -]
        set part_fam [string toupper [lindex $pl 0]]
        set part_pkg [string toupper [lindex $pl 1]]
        dict set res info part_hint $opts(-part)
    }
    if {$want_pkg ne ""} { dict set res info package_hint $want_pkg }
    foreach idc $fpga {
        set hits [::jtagid::match_idcode $idc]
        if {[llength $hits] == 0} {
            dict lappend res errors "$idc: no matching BSDL in $state(bsdl_dir)"
            continue
        }
        # every model and package that shares this IDCODE: JTAG can prove the
        # die, not the SKU, so the caller has to see the whole sibling set
        set all_models {}
        set all_pkgs {}
        set groups [::jtagid::group_by_architecture $hits]
        foreach g $groups {
            foreach m [dict get $g models] {
                if {[lsearch -exact $all_models $m] < 0} { lappend all_models $m }
            }
            if {[lsearch -exact $all_pkgs [dict get $g package]] < 0} { lappend all_pkgs [dict get $g package] }
        }
        set sku [::jtagid::sku_analysis $all_models $want_pkg]
        dict set res info die [dict get $sku die]
        dict set res info sku_models [join [dict get $sku models] { }]
        dict set res info sku_packages [join [lsort $all_pkgs] { }]
        dict set res info sku_decidable [dict get $sku decidable]
        dict set res info sku_note [dict get $sku note]
        dict set res info sku_ps [join [dict get $sku ps] { | }]
        dict set res info sku_pl [join [dict get $sku pl] { | }]
        dict set res info sku_how [join [dict get $sku how] { | }]

        # is a BSDL already bound to this device (from an earlier session)?
        set bound [::jtagid::binding_get $idc]
        if {$bound ne ""} {
            dict set res info bound_idcode [dict get $bound idcode]
            dict set res info bound_device [dict get $bound device]
            dict set res info bound_bsdl [dict get $bound bsdl]
            dict set res info bound_when [dict get $bound when]
        }

        set shown 0
        set want_groups $groups
        if {$want_pkg ne ""} {
            set filtered {}
            foreach g $groups {
                if {[string toupper [dict get $g package]] eq $want_pkg} { lappend filtered $g }
            }
            if {[llength $filtered] == 0} {
                # be forgiving: people type the short form ("784" for SFVC784),
                # and a stale hint must never leave an empty candidate list
                foreach g $groups {
                    set p [string toupper [dict get $g package]]
                    if {[string match "*$want_pkg" $p] || [string match "*$want_pkg*" $p]} {
                        lappend filtered $g
                    }
                }
                if {[llength $filtered] > 0} {
                    set used {}
                    foreach g $filtered {
                        if {[lsearch -exact $used [dict get $g package]] < 0} { lappend used [dict get $g package] }
                    }
                    dict set res info package_hint_note \
                        "package hint $want_pkg -> [join $used {, }]"
                    if {[llength $used] == 1} { dict set res info package_hint_used [lindex $used 0] }
                }
            }
            if {[llength $filtered] > 0} {
                set want_groups $filtered
            } else {
                dict lappend res errors \
                    "no BSDL for package $want_pkg; showing every package instead: [join [lsort $all_pkgs] {, }]"
            }
        }
        foreach group $want_groups {
            set models [join [dict get $group models] /]
            foreach path [dict get $group paths] {
                set det [::jtagid::bsdl_details $path]
                if {[dict get $det missing]} {
                    # skip it, but say so - one unreadable file must not kill the
                    # whole identification
                    dict lappend res errors "BSDL file is gone: $path"
                    continue
                }
                set entity [dict get $det entity]
                set model [::jtagid::model_of $entity]
                set sib {}
                foreach m [dict get $group models] { if {$m ne $model} { lappend sib $m } }
                set rec 0
                if {$part_fam ne "" && \
                    [::jtagid::grade_norm $model] eq [::jtagid::grade_norm $part_fam]} { set rec 1 }
                set isbound 0
                if {$bound ne "" && [dict get $bound bsdl] eq $path} { set isbound 1 }
                dict lappend res candidates [dict create \
                    models $models model $model siblings $sib \
                    bound $isbound recommended $rec \
                    package [dict get $group package] \
                    irl [dict get $group irl] bsr [dict get $group bsr] \
                    cells [dict get $group cells] path $path \
                    entity $entity]
                incr shown
            }
        }
        if {$opts(-part) ne ""} {
            set norm [::jtagid::grade_norm $part_fam]
            set found ""
            foreach m $all_models {
                if {[::jtagid::grade_norm $m] eq $norm} { set found $m }
            }
            set extra ""
            if {$part_pkg ne "" && [lsearch -exact $all_pkgs $part_pkg] < 0 && [llength $all_pkgs] > 0} {
                set extra " (package $part_pkg is not in this BSDL tree: [join [lsort $all_pkgs] {, }])"
            }
            if {$found eq ""} {
                dict set res part [dict create given $opts(-part) matched "" package $part_pkg \
                    message "no such model in this BSDL tree; trust the silicon IDCODE$extra"]
            } elseif {[string equal -nocase $part_fam $found]} {
                dict set res part [dict create given $opts(-part) matched $found package $part_pkg \
                    message "matches the BSDL model$extra"]
            } else {
                dict set res part [dict create given $opts(-part) matched $found package $part_pkg \
                    message "grade letter differs (same silicon/IDCODE)$extra"]
            }
        }
    }
    set state(quiet) $prev_quiet
    return $res
}

proc ::jtagid::cmd_report {args} {
    # Machine readable output (tab separated, ASCII) for scripts and the GUI:
    #   REPORT<TAB>BEGIN|END
    #   INFO<TAB>key<TAB>value
    #     keys now include: die, sku_models, sku_packages, sku_decidable,
    #     sku_note, sku_ps, sku_pl, sku_how, package_hint, part_hint
    #   DEV<TAB>name<TAB>part<TAB>idcode<TAB>family<TAB>array<TAB>mfg<TAB>is_fpga
    #   CAND<TAB>model<TAB>package<TAB>irl<TAB>bsr<TAB>cells<TAB>path<TAB>entity
    #        <TAB>siblings<TAB>recommended
    #     model       : this file's own model (XCZU3EG), not the merged group label
    #     siblings    : other models with the same IDCODE (XCZU3CG)
    #     recommended : 1 when -part names this model
    #   SKU<TAB>die<TAB>decidable<TAB>models
    #   SKU-PS<TAB>text        one line per model: what differs in the PS
    #   SKU-PL<TAB>text        one line per model: PL resources from Vivado's DB
    #   SKU-HOW<TAB>step       one line per step: how to settle the SKU by hand
    #   PART<TAB>given<TAB>matched<TAB>package<TAB>message
    #   ERR<TAB>message
    set res [::jtagid::collect_report {*}$args]
    puts "REPORT\tBEGIN"
    dict for {key value} [dict get $res info] { puts "INFO\t$key\t$value" }
    foreach d [dict get $res devices] {
        puts "DEV\t[dict get $d name]\t[dict get $d part]\t[dict get $d idcode]\t[dict get $d family]\t[dict get $d array]\t[dict get $d mfg]\t[dict get $d fpga]"
    }
    foreach c [dict get $res candidates] {
        puts "CAND\t[dict get $c model]\t[dict get $c package]\t[dict get $c irl]\t[dict get $c bsr]\t[dict get $c cells]\t[dict get $c path]\t[dict get $c entity]\t[join [dict get $c siblings] {,}]\t[dict get $c recommended]\t[dict get $c bound]"
    }
    set info [dict get $res info]
    if {[dict exists $info sku_models]} {
        puts "SKU\t[dict get $info die]\t[dict get $info sku_decidable]\t[dict get $info sku_models]"
        foreach key {sku_ps sku_pl} {
            if {[dict exists $info $key]} {
                # the driver joins the lines with " | " - split on that single
                # character only (splitting on a character set would cut
                # "no GPU, no VCU" into words)
                foreach line [split [dict get $info $key] |] {
                    if {[string trim $line] ne ""} { puts "SKU-[string toupper [string range $key 4 end]]\t[string trim $line]" }
                }
            }
        }
        if {[dict exists $info sku_how]} {
            foreach step [split [dict get $info sku_how] |] {
                if {[string trim $step] ne ""} { puts "SKU-HOW\t[string trim $step]" }
            }
        }
    }
    set part [dict get $res part]
    if {$part ne ""} {
        puts "PART\t[dict get $part given]\t[dict get $part matched]\t[dict get $part package]\t[dict get $part message]"
    }
    if {[dict exists $info bound_bsdl]} {
        puts "BIND\t[dict get $info bound_idcode]\t[dict get $info bound_device]\t[dict get $info die]\t[dict get $info bound_bsdl]\t[dict get $info bound_when]"
    }
    foreach e [dict get $res errors] { puts "ERR\t$e" }
    puts "REPORT\tEND"
    return
}

#==============================================================================
# dispatcher
#==============================================================================

proc ::jtagid::dispatch {sub args} {
    switch -exact -- $sub {
        help - -h - --help   { return [::jtagid::cmd_help] }
        version - ver        { return [::jtagid::cmd_version] }
        status               { return [::jtagid::cmd_status] }
        open - connect       { return [::jtagid::cmd_open {*}$args] }
        scan - chain         { return [::jtagid::cmd_scan {*}$args] }
        identify - id        { return [::jtagid::cmd_identify {*}$args] }
        report               { return [::jtagid::cmd_report {*}$args] }
        bind                 { return [::jtagid::cmd_bind {*}$args] }
        bsdl-for             { return [::jtagid::cmd_bsdl_for {*}$args] }
        gui                  { return [::jtagid::cmd_gui {*}$args] }
        gui-status           { return [::jtagid::cmd_gui_status] }
        gui-stop             { return [::jtagid::cmd_gui_stop] }
        close - disconnect   { return [::jtagid::cmd_close {*}$args] }
        bsdl-dir             { return [::jtagid::cmd_bsdl_dir {*}$args] }
        bsdl-index           { return [::jtagid::cmd_bsdl_index {*}$args] }
        bsdl-match           { return [::jtagid::cmd_bsdl_match {*}$args] }
        default {
            return -code error "unknown subcommand \"$sub\"; run: jtagid help"
        }
    }
}

proc ::jtagid {sub args} {
    return [::jtagid::dispatch $sub {*}$args]
}

proc ::jtagid_scan {}         { return [::jtagid scan] }
proc ::jtagid_identify {args} { return [::jtagid identify {*}$args] }

#==============================================================================
# banner on source + batch entry point
#==============================================================================

::jtagid::probe_compat 1
set ::jtagid::state(bsdl_dir) [::jtagid::default_bsdl_dir]
puts "jtagid loaded: Vivado $::jtagid::compat(vivado) / Tcl $::jtagid::compat(tcl), hardware commands [expr {$::jtagid::compat(hw_commands) ? {available} : {MISSING}}], BSDL dir $::jtagid::state(bsdl_dir)"
puts "usage: jtagid help   |   jtagid identify"

# Batch entry: vivado -mode batch -source jtagid.tcl -tclargs identify
# Only fires when the first tclarg is one of our subcommands (so sourcing this
# file inside the GUI never triggers anything).
set ::jtagid::KNOWN_SUBS {
    help version ver status open connect scan chain identify id close disconnect
    bsdl-dir bsdl-index bsdl-match report gui
}
if {[info exists ::argv] && [llength $::argv] > 0} {
    set sub [lindex $::argv 0]
    if {[lsearch -exact $::jtagid::KNOWN_SUBS $sub] >= 0} {
        puts "== batch subcommand: $sub =="
        set rc 0
        if {[catch {::jtagid::dispatch $sub {*}[lrange $::argv 1 end]} err]} {
            puts "ERROR: $err"
            set rc 1
        }
        # batch runs must not leave a self-started hw_server behind
        catch {::jtagid close -shutdown-own}
        catch {exit $rc}
    }
}
