###############################################################################
# jtagid_test_sku.tcl -- why two models with one IDCODE are still different,
#                        and what the driver now says about it.
#
# This runs in plain Vivado (batch is fine, it needs the cable) and prints the
# same analysis the GUI shows in its details pane:
#
#   * identify with a package hint and with a part number
#   * identify with no hints at all (the ambiguous case)
#   * the machine readable report, so the CAND/SKU lines can be inspected
#
# Run:
#     vivado -mode batch -nolog -nojournal -notrace -source <this file>
#
# Measured on Vivado 2018.3 with a ZU3 board, 2026-10:
#
#   0x14710093 -> 8 file(s), 1 package group(s)      (with -package SFVC784)
#   die          : ZU3
#   same IDCODE  : XCZU3CG XCZU3EG  (2 model(s))
#     PS         : XCZU3CG    CG: no GPU, no VCU
#     PS         : XCZU3EG    EG: Mali-400 GPU (no VCU)
#     PL         : XCZU3CG    slices=8820 LUT=70560 DSP=360 BRAM=216 MMCM=3
#     PL         : XCZU3EG    slices=8820 LUT=70560 DSP=360 BRAM=216 MMCM=3
#   verdict      : these are the SAME die ... cannot tell them apart
#   BSDL         : .../xczu3eg_sfvc784.bsd          (picked by the -part hint)
#
# The two BSDL files in question are byte identical after renaming the model
# (same SHA-256), which is the reason none of this can be decided by JTAG.
#
# Temporary/diagnostic helper.  ASCII only.
###############################################################################

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ..]]
source [file join $root jtagid.tcl]

puts "########## identify -package SFVC784 -part xazu3eg-sfvc784-1-i ##########"
::jtagid identify -package SFVC784 -part xazu3eg-sfvc784-1-i

puts ""
puts "########## identify (no hints) ##########"
::jtagid identify

puts ""
puts "########## report -package SFVC784 -part xazu3eg-sfvc784-1-i ##########"
::jtagid report -package SFVC784 -part xazu3eg-sfvc784-1-i

::jtagid close -shutdown-own
exit 0
