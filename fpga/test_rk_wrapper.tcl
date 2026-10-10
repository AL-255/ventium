# Pure Tcl source-contract test. Does NOT invoke Vivado or elaborate hardware.
# Usage: tclsh test_rk_wrapper.tcl wrapper flow definefile frozen-source template ?profile?
if {$argc ni {5 6}} { error "expected wrapper flow definefile source template ?profile?" }
lassign $argv wrapper flow definefile source_root template profile
if {$argc == 5} { set profile balanced }
set ::env(VEN_FPGA_CORE_MHZ) 40
set ::env(VEN_FPGA_BUILD_PROFILE) $profile
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
if {$profile eq "legacy"} {
    require_span {STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AreaOptimized_high}
} else {
    require_span {STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE Default}
    require_span {STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Default}
    require_span {STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED false}
}
set logic_only_option {set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-no_timing_driven} -objects [get_runs synth_1]}
if {$profile eq "logic_only"} {
    require_span $logic_only_option
} elseif {[string first {-no_timing_driven} $::expanded] >= 0} {
    error "diagnostic optimization option leaked into timing-driven profile"
}
require_span {CONFIG.PSU__SAXIGP2__DATA_WIDTH {128}}
require_span {CONFIG.PSU__CRL_APB__PL0_REF_CTRL__DIVISOR0 {15}}
if {![regexp {set DEFS \{([^\}]*)\}} $::expanded -> defs]} { error "no DEFS" }
set profile_handle [open $definefile r]
set requested_defs [split [string trim [read $profile_handle]] "\n"]
close $profile_handle
if {$defs ne [join $requested_defs { }]} { error "expanded defines differ from pinned profile" }
set fe_defs {VEN_FE_PIPE VEN_FE_DTLB_MULTI VEN_FE_DTLB_PERM}
set define_count [llength $defs]
set actual_define_count $define_count
# Explicit October 9 performance bundle. Strip only this complete, ordered
# addition before applying the unchanged posted/banked-parent checks below.
# This is source admission, never simulation, timing or silicon acceptance.
set perf_defs {VEN_AXI2AVL_READ_THROUGH VEN_FP_ARITH_MEM_FWD VEN_FP_MEM_QUEUE64 VEN_FP_POP_DRAIN VEN_FP_RESIDENT_PRIME VEN_FP_SCALAR_DISPATCH VEN_FP_SCALAR_LOAD_CMD VEN_FP_SHORT_WINDOW VEN_IFETCH_AUTH_MULTI VEN_L1D_CODE_WORD_REUSE VEN_L1D_DATA_UNDER_IFILL VEN_L1D_PRIME_UNDER_FILL VEN_L1D_TAG_LUTRAM VEN_P54_CTRL_TARGET_SYSTEM VEN_PIPE_MEM_CHAIN VEN_PIPE_REG_LOAD_PRIME VEN_RAW_AGI_PRIME VEN_RAW_HELD_READ_PRIME VEN_RAW_V_READ_PRIME VEN_REF_OPERAND_PRIME VEN_REP_CONT_NO_UOP}
if {$define_count == 135} {
    if {[lrange $defs 111 131] ne $perf_defs ||
        [lrange $defs 132 end] ne {SYNTHESIS VTM_NO_DPI VEN_ALTSYNCRAM_XPM}} {
        error "wrong performance extension bundle/order"
    }
    set defs [lreplace $defs 111 131]
    set define_count [llength $defs]
}
if {$define_count == 114 && [lindex $defs 110] eq "VEN_DDR_POSTED"} {
    require_span {lappend files "$VEN/fpga/ven_ddram_axi_posted.sv"}
    set defs [lreplace $defs 110 110]
    set define_count [llength $defs]
}
if {$define_count == 113} {
    if {[lrange $defs 107 109] ne $fe_defs ||
        [lrange $defs 110 end] ne {SYNTHESIS VTM_NO_DPI VEN_ALTSYNCRAM_XPM}} {
        error "wrong FE-DTLB extension bundle/order"
    }
    if {[lsearch -exact $defs VEN_PIPE_MEM_CHAIN] >= 0} { error "unverified FE-DTLB memory-chain profile" }
} elseif {$define_count == 110} {
    foreach d $fe_defs {
        if {[lsearch -exact $defs $d] >= 0} { error "partial FE-DTLB profile" }
    }
} else {
    error "wrong define count"
}
foreach forbidden {VEN_UOPCACHE VEN_CACHE_HALF VEN_IC_NARROWB VEN_DTLB_ASSOC_2WAY} {
    if {[lsearch -exact $defs $forbidden] >= 0} { error "extra define: $forbidden" }
}
if {[string first {add_files -fileset constrs_1 -norecurse "$HW/bitstream.xdc" "$HW/led.xdc" "$HW/fpatan_mcp.xdc"} $::expanded] >= 0} {
    error "legacy FPATAN multicycle constraint remains active"
}
if {![info complete $::expanded]} { error "transformed Tcl is incomplete" }
puts "RK-WRAPPER-STATIC-OK: physical40M, exact${actual_define_count}defs, pinned roots, 1job, fatal failures, profile=$profile"
