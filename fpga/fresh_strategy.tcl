# Fresh full-project synthesis/APR. Never import a previous run's checkpoints.
if {$argc ni {4 5}} {error "usage: strategy frozen-source new-output-directory synth-threads ?apr-threads?"}
lassign $argv strategy frozen out tool_threads implementation_threads
if {$argc == 4} {set implementation_threads $tool_threads}
if {$tool_threads ni {1 2 8}} {error "only one, two or eight internal threads supported"}
if {$strategy ni {performance-netdelay routability-spread performance-retime-bounded performance-bounded performance-route-first routability-route-first routability-retime-route-first routability-retime-remap-route-first}} {error "unknown strategy"}
if {$tool_threads eq "8"} {
    if {$implementation_threads ne "8"} {error "parallel8 requires synth=8 APR=8"}
} elseif {$strategy in {performance-route-first routability-route-first routability-retime-route-first routability-retime-remap-route-first}} {
    if {$tool_threads ne "1" || $implementation_threads ne "4"} {error "route-first requires synth=1 APR=4"}
} elseif {$implementation_threads ne $tool_threads} {error "unequal stage threads only supported for route-first"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
set out [file normalize $out]
set frozen [file normalize $frozen]
if {[file exists $out]} {error "fresh output must not exist"}
file mkdir $out
set ::fresh_script_dir [file dirname [file normalize [info script]]]
source [file join $::fresh_script_dir fresh_synth_evidence.tcl]
source [file join $::fresh_script_dir fresh_bounded_phys.tcl]
source [file join $::fresh_script_dir fresh_route_first.tcl]
set ::env(VEN_FRESH_OUT) $out
set_param general.maxThreads $tool_threads
set ::fresh_launches {}

proc fresh_event {name} {
    set f [open [file join $::out stages.tsv] a]
    puts $f "$name\t[clock seconds]"
    close $f
    puts "FRESH-STAGE $name"
}

# Intercept immediately after project creation, before BD output generation.
# No cache clearing: disabling use is sufficient and doesn't delete other runs.
rename create_project __fresh_create_project
proc create_project {args} {
    set result [uplevel 1 [list __fresh_create_project {*}$args]]
    config_ip_cache -disable_cache
    set cache [get_property IP_CACHE_PERMISSIONS [current_project]]
    # Vivado 2025.2 serializes/returns "disable"; its command manual describes
    # the value as "disabled". Neither spelling grants read or write access.
    if {$cache ni {disable disabled}} {
        error "IP checkpoint cache must be disabled; native property=$cache"
    }
    return $result
}

proc fresh_run {run} {
    set obj [get_runs $run]
    set properties [list_property $obj]
    foreach prop {AUTO_INCREMENTAL_CHECKPOINT INCREMENTAL_CHECKPOINT} value {0 {}} {
        if {$prop in $properties} {
            set_property $prop $value $obj
            set actual [get_property $prop $obj]
            if {$prop eq "AUTO_INCREMENTAL_CHECKPOINT"} {
                if {$actual ni {0 false}} {error "$run enables automatic incremental reuse"}
            } elseif {$actual ne ""} {error "$run has an incremental checkpoint"}
        }
    }
    # Read back every incremental property for the native evidence trail.
    report_property $obj -file [file join $::out ${run}-properties.rpt]
}

rename launch_runs __fresh_launch_runs
proc launch_runs {run args} {
    set expected [expr {[llength $::fresh_launches] == 0 ? "synth_1" : "impl_1"}]
    if {$run ne $expected || [llength $::fresh_launches] >= 2} {error "unexpected/duplicate run"}
    if {[lrange $args end-1 end] ne {-jobs 1}} {error "one worker required"}
    if {[get_property IP_CACHE_PERMISSIONS [current_project]] ni {disable disabled}} {error "IP cache enabled"}
    set obj [get_runs $run]
    if {$run eq "synth_1"} {
        foreach {name expected} {PSU__GPIO_EMIO__PERIPHERAL__ENABLE 1 PSU__GPIO_EMIO_WIDTH 95 PSU__SAXIGP2__DATA_WIDTH 128} {
            if {[get_property CONFIG.$name [get_bd_cells ps8]] ne $expected} {error "PS parameter $name differs"}
        }
        if {[get_property TYPE [get_bd_pins u_soc/pll_safe]] eq "clk"} {error "drain interlock is data"}
        set active [get_property NAME [get_files -compile_order sources -used_in synthesis]]
        foreach name {ven_programmable_clock.v ven_pll_ctrl.sv} {
            if {[llength [lsearch -all -glob $active */$name]] != 1} {error "clock source missing/duplicated"}
        }
        if {[llength [lsearch -all -glob $active */clk_div32_40mhz.v]]} {error "fixed clock still active"}
        set f [open [file join $::out active-sources.txt] {WRONLY CREAT EXCL}]
        foreach file $active {
            set path [file normalize $file]
            if {![string match "$::frozen/*" $path] && ![string match "$::out/*" $path] &&
                ![string match "/tools/Xilinx/2025.2/Vivado/*" $path]} {error "source escaped freeze: $path"}
            if {[file extension $path] eq ".dcp"} {error "pre-synthesis checkpoint input: $path"}
            puts $f $path
        }
        close $f
        set directive [expr {$::strategy in {routability-spread routability-route-first routability-retime-route-first routability-retime-remap-route-first} ? "AlternateRoutability" : "PerformanceOptimized"}]
        set retiming [expr {$::strategy in {performance-retime-bounded routability-retime-route-first routability-retime-remap-route-first} ? "on" : "auto"}]
        if {$::strategy in {performance-bounded performance-route-first routability-route-first}} {set retiming off}
        set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $directive $obj
        set_property STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING $retiming $obj
        set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt $obj
        set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {} -objects $obj
        # Report via the owning project after wait_on_run, not the native
        # child where implementation-disabled XDCs disappear after synthesis.
        set_property STEPS.SYNTH_DESIGN.TCL.POST {} $obj
        if {[get_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $obj] ne $directive ||
            [get_property STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING $obj] ne $retiming ||
            [get_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} $obj] ne ""} {error "synthesis policy drift"}
    } else {
        # The platform flow already waits for synth_1 before this launch.
        # Validate the just-built design here; wait_on_run is lazily registered
        # by Vivado and cannot be renamed during initial script loading.
        fresh_synth_evidence
        # RuntimeOptimized opt_design avoids the observed optimizer crash. It
        # does NOT request incremental RuntimeOptimized or a negative WNS target.
        set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized $obj
        set_property -name {STEPS.OPT_DESIGN.ARGS.MORE OPTIONS} -value {} -objects $obj
        set_property STEPS.OPT_DESIGN.TCL.POST {} $obj
        if {$::strategy eq "routability-retime-remap-route-first"} {
            set_property STEPS.OPT_DESIGN.TCL.POST [file join $::fresh_script_dir fresh_opt_remap_post.tcl] $obj
        }
        if {$::strategy eq "performance-netdelay"} {
            set place ExtraNetDelay_high; set phys AggressiveExplore; set route NoTimingRelaxation
        } elseif {$::strategy eq "routability-spread"} {
            set place AltSpreadLogic_medium; set phys Explore; set route AlternateCLBRouting
        } elseif {$::strategy in {routability-route-first routability-retime-route-first routability-retime-remap-route-first}} {
            set place AltSpreadLogic_high; set phys Default; set route AlternateCLBRouting
        } else {
            set place AltSpreadLogic_medium; set phys Default; set route NoTimingRelaxation
        }
        set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $place $obj
        set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $obj
        set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE $phys $obj
        set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $route $obj
        set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $obj
        set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore $obj
        if {$::strategy in {performance-retime-bounded performance-bounded}} {fresh_bounded_phys $obj}
        if {$::strategy in {performance-route-first routability-route-first routability-retime-route-first routability-retime-remap-route-first}} {fresh_route_first $obj}
        set_property STEPS.ROUTE_DESIGN.TCL.PRE [file join $::fresh_script_dir fresh_route_pre.tcl] $obj
    }
    # The source-only platform sets its own legacy thread default. Override
    # immediately before each native launch without changing its -jobs 1.
    set threads [expr {$run eq "synth_1" ? $::tool_threads : $::implementation_threads}]
    if {$threads == 8} {
        set step [expr {$run eq "synth_1" ? "SYNTH_DESIGN" : "OPT_DESIGN"}]
        set_property STEPS.${step}.TCL.PRE [file join $::fresh_script_dir fresh_threads8_pre.tcl] $obj
    }
    fresh_run $run
    set_param general.maxThreads $threads
    if {[get_param general.maxThreads] != $threads} {error "tool thread policy drift"}
    fresh_event $run
    lappend ::fresh_launches $run
    return [uplevel 1 [list __fresh_launch_runs $run {*}$args]]
}

# The source-only platform wrapper owns exact defines, full P5 caches, port
# wiring and cycle_mode=1. Our interceptors apply the strategy after its defaults.
set argv [list all $out]
set argc 2
source [file join $frozen ventium fpga create_project_3mhz_wrapper.tcl]
if {$::fresh_launches ne {synth_1 impl_1}} {error "incomplete fresh synthesis/implementation sequence"}
source [file join $::fresh_script_dir fresh_reports.tcl]
fresh_event complete
puts "FRESH-STRATEGY-COMPLETE $strategy (timing and hardware acceptance require separate audit)"
