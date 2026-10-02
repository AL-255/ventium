# Pure Tcl source-contract test. Does NOT invoke Vivado or elaborate hardware.
# Usage: tclsh test_rk_wrapper.tcl wrapper flow definefile frozen-source template
if {$argc != 5} { error "expected wrapper flow definefile source template" }
lassign $argv wrapper flow definefile source_root template
set ::env(VEN_FPGA_CORE_MHZ) 40
set ::env(VEN_FPGA_BUILD_PROFILE) balanced
set ::env(VEN_FPGA_JOBS) 1
set ::env(VEN_FPGA_FLOW_ROOT) $flow
set ::env(VEN_FPGA_DEFINE_FILE) $definefile
set ::env(VEN_FPGA_SOURCE_ROOT) $source_root
set ::env(VEN_FPGA_TEMPLATE_ROOT) $template
proc set_param {name value} {
    if {$name ne "general.maxThreads" || $value != 1} { error "thread bound failed" }
}
rename uplevel native_uplevel
proc uplevel {level body} {
    if {$level ne "#0"} { error "unexpected evaluation level" }
    set ::expanded $body
}
source $wrapper
proc require_span {span} {
    if {[string first $span $::expanded] < 0} { error "missing transformed span: $span" }
}
require_span "set VEN {$source_root}"
require_span "set ROOT {$flow}"
require_span {set c3f 40000000}
require_span {lappend files "$VEN/fpga/clk_div32_40mhz.v"}
require_span {set_property CONFIG.CLK_HZ $c3f [get_bd_cells $soc]}
require_span {launch_runs synth_1 -jobs 1; wait_on_run synth_1}
require_span {launch_runs impl_1 -to_step write_bitstream -jobs 1; wait_on_run impl_1}
require_span {error "FPGA synthesis failed}
require_span {error "FPGA implementation failed}
require_span {STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE Default}
require_span {STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Default}
require_span {STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED false}
require_span {CONFIG.PSU__SAXIGP2__DATA_WIDTH {128}}
require_span {CONFIG.PSU__CRL_APB__PL0_REF_CTRL__DIVISOR0 {15}}
if {![regexp {set DEFS \{([^\}]*)\}} $::expanded -> defs]} { error "no DEFS" }
if {[llength $defs] != 110} { error "wrong define count" }
foreach forbidden {VEN_UOPCACHE VEN_CACHE_HALF VEN_IC_NARROWB VEN_DTLB_ASSOC_2WAY} {
    if {[lsearch -exact $defs $forbidden] >= 0} { error "extra define: $forbidden" }
}
if {[string first {add_files -fileset constrs_1 -norecurse "$HW/bitstream.xdc" "$HW/led.xdc" "$HW/fpatan_mcp.xdc"} $::expanded] >= 0} {
    error "legacy FPATAN multicycle constraint remains active"
}
if {![info complete $::expanded]} { error "transformed Tcl is incomplete" }
puts "RK-WRAPPER-STATIC-OK: physical40M, exact110defs, pinned roots, 1job, fatal failures"
