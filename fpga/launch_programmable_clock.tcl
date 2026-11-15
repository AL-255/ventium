# Exactly one fresh 40 MHz synthesis and implementation. Runtime changes use DRP.
# Never import pre-existing checkpoints or cached IP products.
if {$argc != 2 || [lindex $argv 0] ne "all"} {error "usage: all output-directory"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
if {$::env(VEN_FPGA_CORE_MHZ) ne "40"} {error "one 40 MHz image required"}

rename create_project __clock_native_create_project
proc create_project {args} {
    set result [uplevel 1 [list __clock_native_create_project {*}$args]]
    config_ip_cache -disable_cache
    if {[get_property IP_CACHE_PERMISSIONS [current_project]] ni {disable disabled}} {
        error "IP checkpoint cache must be disabled"
    }
    return $result
}

proc enforce_fresh_run {run} {
    set obj [get_runs $run]
    set props [list_property $obj]
    foreach prop {AUTO_INCREMENTAL_CHECKPOINT INCREMENTAL_CHECKPOINT} val {0 {}} {
        if {$prop in $props} {
            set_property $prop $val $obj
        }
    }
}

rename launch_runs __clock_native_launch_runs
set ::clock_launches {}
proc launch_runs {run args} {
    set expected [expr {[llength $::clock_launches] == 0 ? "synth_1" : "impl_1"}]
    if {$run ne $expected || [llength $::clock_launches] >= 2} {error "duplicate/unexpected run $run"}
    if {[lindex $args end-1] ne "-jobs" || [lindex $args end] ne "1"} {error "one native worker required"}
    if {[get_property IP_CACHE_PERMISSIONS [current_project]] ni {disable disabled}} {error "IP cache enabled"}
    enforce_fresh_run $run
    if {$run eq "synth_1"} {
        foreach {name expected} {
            PSU__GPIO_EMIO__PERIPHERAL__ENABLE 1
            PSU__GPIO_EMIO_WIDTH 95
            PSU__SAXIGP2__DATA_WIDTH 128
        } {
            if {[get_property CONFIG.$name [get_bd_cells ps8]] ne $expected} {error "PS parameter $name differs"}
        }
        set active [get_property NAME [get_files -compile_order sources -used_in synthesis]]
        foreach name {ven_programmable_clock.v ven_pll_ctrl.sv} {
            if {[llength [lsearch -all -glob $active */$name]] != 1} {error "clock source missing/duplicated: $name"}
        }
        if {[llength [lsearch -all -glob $active */clk_div32_40mhz.v]]} {error "fixed clock still active"}
        if {[get_property TYPE [get_bd_pins u_soc/pll_safe]] eq "clk"} {
            error "the drain interlock is data, not a clock interface"
        }
        puts "PROGRAMMABLE-CLOCK-PREFLIGHT-OK 40MHz GPIO95 fresh-source-c0e3fe43"
    } else {
        if {[get_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] ne "RuntimeOptimized"} {error "opt directive changed"}
        if {[info exists ::env(VEN_FPGA_BUILD_PROFILE)] && $::env(VEN_FPGA_BUILD_PROFILE) eq "retime_muxf_route_first"} {
            if {[get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] ne "AltSpreadLogic_high"} {error "place directive changed"}
            if {[get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] ne "AlternateCLBRouting"} {error "route directive changed"}
            if {![string match */fresh_opt_muxf_post.tcl [get_property STEPS.OPT_DESIGN.TCL.POST [get_runs impl_1]]]} {error "missing muxf post-opt hook"}
        }
    }
    lappend ::clock_launches $run
    return [uplevel 1 [list __clock_native_launch_runs $run {*}$args]]
}
source [file join $::env(VEN_FPGA_SOURCE_ROOT) fpga create_project_3mhz_wrapper.tcl]
if {$::clock_launches ne {synth_1 impl_1}} {error "expected exactly one synth/impl sequence"}
set out [file normalize [lindex $argv 1]]
write_checkpoint -force [file join $out fresh-routed.dcp]
report_clocks -file [file join $out clocks.rpt]
report_route_status -file [file join $out route_status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing_summary.rpt]
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out utilization_hierarchy.rpt]
report_design_analysis -congestion -file [file join $out congestion.rpt]
report_cdc -file [file join $out cdc.rpt]
report_drc -file [file join $out drc.rpt]
set mmcm [get_cells -hier -filter {REF_NAME == MMCME4_ADV}]
if {[llength $mmcm] != 1} {error "expected one DRP-capable MMCM"}
report_property $mmcm -file [file join $out mmcm.rpt]
foreach {property expected} {CLKFBOUT_MULT_F 10 CLKOUT0_DIVIDE_F 25 DIVCLK_DIVIDE 1} {
    if {[get_property $property $mmcm] != $expected} {error "incorrect boot clock $property"}
}
puts "PROGRAMMABLE-CLOCK-BUILD-COMPLETE (inspect timing_summary.rpt and validate on board)"
