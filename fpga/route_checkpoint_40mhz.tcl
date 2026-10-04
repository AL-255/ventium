# Fresh non-project continuation of a pinned, fully placed physical-opt DCP.
# Root must enforce the exclusive Vivado guard, resource admission, explicit
# external/tmp TMPDIR and an external 8-hour wall bound. No old run is resumed,
# reset or made complete. Native exit 0 is required in addition to the marker.
# Reports/artifacts are evidence, not timing/CDC/deployment acceptance.
if {$argc != 3} {
    error "usage: vivado -mode batch -source route_checkpoint_40mhz.tcl -tclargs <physopt.dcp> <expected_sha256> <new_output_dir>"
}
set input_arg [lindex $argv 0]
if {![file isfile $input_arg] || [file type $input_arg] ne "file" ||
    ![file readable $input_arg]} {
    error "checkpoint must be an existing readable regular file, not a symlink"
}
set checkpoint [file normalize $input_arg]
set expected_sha256 [string tolower [lindex $argv 1]]
if {![regexp {^[0-9a-f]{64}$} $expected_sha256]} {
    error "expected_sha256 must be exactly 64 hexadecimal characters"
}
set checksum_output [exec sha256sum -- $checkpoint]
if {![regexp {^([0-9a-f]{64})[ \t]} $checksum_output -> actual_sha256] ||
    $actual_sha256 ne $expected_sha256} {
    error "checkpoint SHA-256 does not match the supplied pin"
}
set output_arg [lindex $argv 2]
# lstat also rejects a dangling output symlink, which file exists misses.
if {![catch {file lstat $output_arg output_stat}]} {
    error "output directory must be new: $output_arg"
}
set external_tmp [file normalize /home/yukidama/external/tmp]
if {![file isdirectory $external_tmp] || [file type $external_tmp] ne "directory"} {
    error "external temporary root must be an existing directory"
}
set output [file normalize $output_arg]
set output_parent [file dirname $output]
if {$output eq $external_tmp || [string first "${external_tmp}/" $output] != 0 ||
    ![file isdirectory $output_parent] || [file type $output_parent] ne "directory" ||
    ![file writable $output_parent]} {
    error "output must be a new child of a resolved, writable parent beneath $external_tmp"
}
if {[version -short] ne "2025.2"} { error "this continuation requires Vivado 2025.2" }
puts "## checkpoint input=$checkpoint SHA256=$actual_sha256"
puts "## fresh non-project output=$output (routing restarts from the saved checkpoint)"

# The scheduling budget covers reports only, not routing or bitstream writing.
# It cannot interrupt a native report already in progress; the outer bound must.
set started ""
set wall_budget_seconds 540
proc require_budget {} {
    global started wall_budget_seconds
    if {$started ne "" && [clock seconds] - $started >= $wall_budget_seconds} {
        error "post-route report scheduling exceeded ${wall_budget_seconds}s"
    }
}
proc finite_number {value} {
    if {![string is double -strict $value]} { return 0 }
    if {[catch {expr {$value > -Inf && $value < Inf}} finite]} { return 0 }
    return $finite
}
proc require_regular_nonempty {path} {
    if {![file isfile $path] || [file type $path] ne "file" || [file size $path] <= 0} {
        error "missing, empty or non-regular native artifact: $path"
    }
}
proc inspect_clock {name expected_period} {
    set clocks [get_clocks -quiet $name]
    if {[llength $clocks] != 1} { error "expected exactly one profile clock $name" }
    set period [get_property PERIOD $clocks]
    if {![finite_number $period] || $period <= 0.0 ||
        abs($period - $expected_period) > 0.001 + 1.0e-12} {
        error "invalid/wrong profile $name PERIOD=$period; expected $expected_period ns"
    }
    puts [format "## constrained frequency %s: %.6f MHz (%.6f ns); not physically measured" \
        $name [expr {1000.0 / $period}] $period]
    return [list $clocks $period]
}
proc require_fully_routed {} {
    require_budget
    set placed [report_route_status -boolean_check PLACED_FULLY]
    require_budget
    set fully [report_route_status -boolean_check ROUTED_FULLY]
    require_budget
    set partial [report_route_status -boolean_check PARTIALLY_ROUTED]
    require_budget
    set errors [report_route_status -boolean_check ERRORS_IN_ROUTES]
    puts "## route state PLACED_FULLY=$placed ROUTED_FULLY=$fully PARTIALLY_ROUTED=$partial ERRORS_IN_ROUTES=$errors"
    if {$placed ni {1 true} || $fully ni {1 true} ||
        $partial ni {0 false} || $errors ni {0 false}} {
        error "implementation is not positively fully placed/routed with no partial routing and zero routing errors"
    }
}
proc inspect_domain {name clock period reports} {
    foreach analysis {setup hold} {
        require_budget
        # Native errors propagate; absent same-domain paths are not acceptance.
        set paths [get_timing_paths -from $clock -to $clock -$analysis \
            -max_paths 5 -nworst 1 -sort_by slack]
        if {[llength $paths] < 1 || [llength $paths] > 5} {
            error "$name $analysis returned missing/excessive bounded paths"
        }
        set worst_path ""
        set worst_slack Inf
        foreach path $paths {
            set launch [get_property NAME [get_property STARTPOINT_CLOCK $path]]
            set capture [get_property NAME [get_property ENDPOINT_CLOCK $path]]
            set slack [get_property SLACK $path]
            if {$launch ne $name || $capture ne $name || ![finite_number $slack]} {
                error "$name $analysis path has wrong clock or invalid slack: $launch -> $capture, $slack"
            }
            if {$slack < $worst_slack} { set worst_slack $slack; set worst_path $path }
        }
        puts "## same-domain $name $analysis worst_slack_ns=$worst_slack inspected_paths=[llength $paths]"
        require_budget
        # Re-query the bounded clock-to-clock search, retaining expanded clocks.
        report_timing -from $clock -to $clock -$analysis \
            -max_paths 5 -nworst 1 -sort_by slack \
            -path_type full_clock_expanded \
            -file [file join $reports "${name}_${analysis}.rpt"]
        if {$analysis eq "setup"} {
            # Only an ordinary full-cycle same-clock path supports period-slack.
            # Missing/unfamiliar exception metadata fails closed for the estimate.
            set properties [list_property $worst_path]
            set reason ""
            if {"REQUIREMENT" ni $properties || "EXCEPTION" ni $properties} {
                set reason "requirement/exception metadata unavailable"
            } else {
                set requirement [get_property REQUIREMENT $worst_path]
                set exception [string tolower [string trim [get_property EXCEPTION $worst_path]]]
                if {![finite_number $requirement] || abs($requirement - $period) > 0.001 + 1.0e-12} {
                    set reason "requirement is not one full clock period"
                } elseif {$exception ni {"" none}} {
                    set reason "path has exceptional or unfamiliar timing semantics"
                }
            }
            set estimated_period [expr {$period - $worst_slack}]
            if {$reason eq "" && (![finite_number $estimated_period] || $estimated_period <= 0.0)} {
                set reason "period-minus-slack is not finite and positive"
            }
            if {$reason ne ""} {
                puts "## same-domain $name Fmax estimate UNAVAILABLE: $reason"
            } else {
                puts [format "## same-domain %s conditional single-cycle PATH-LOCAL Fmax estimate: %.6f MHz (%.6f ns = period - setup slack)" \
                    $name [expr {1000.0 / $estimated_period}] $estimated_period]
                puts "## Estimate assumes fixed routed clock tree/uncertainty; exception coverage, other requirement classes, pulse-width, CDC and hold may limit domain/board speed. Not timing sign-off or overclock authority."
            }
        }
    }
}
set opened 0
try {
    set_param general.maxThreads 1
    # DCP constraints and placement are retained; never override part or timing.
    open_checkpoint $checkpoint
    set opened 1
    set part [get_property PART [current_project]]
    # open_checkpoint names the in-memory design checkpoint_<DCP basename>.
    # That display name is not the HDL top; TOP is the loaded module property.
    # Vivado 2025.2's shipped report_clock_buffers uses this on opened DCPs.
    set top [get_property TOP [current_design]]
    puts "## restored design display_name=[get_property NAME [current_design]] module_top=$top part=$part"
    if {$part ne "xczu15eg-ffvb1156-2-i" || $top ne "rk_ao486_bd_wrapper"} {
        error "checkpoint has wrong native part/top: $part / $top"
    }
    lassign [inspect_clock clk_pl_0 10.0] pl_clock pl_period
    lassign [inspect_clock mmcm_clk 25.0] core_clock core_period
    set placed [report_route_status -boolean_check PLACED_FULLY]
    if {$placed ni {1 true}} { error "checkpoint is not positively fully placed" }
    file mkdir $output
    route_design
    # Save returned native state before reports, including recovery evidence if a
    # later legality/report/bitstream check fails. Its filename is not acceptance.
    set routed_dcp [file join $output rk_ao486_bd_wrapper_routed.dcp]
    write_checkpoint $routed_dcp
    require_regular_nonempty $routed_dcp
    require_fully_routed
    set reports [file join $output reports]
    file mkdir $reports
    set started [clock seconds]
    require_budget
    report_utilization -file [file join $reports utilization.rpt]
    require_budget
    report_utilization -hierarchical -file [file join $reports utilization_hierarchical.rpt]
    require_budget
    report_clocks -file [file join $reports clocks.rpt]
    require_budget
    report_clock_interaction -delay_type min_max -file [file join $reports clock_interaction.rpt]
    require_budget
    # Raw visibility of every set_bus_skew; no severity/object/hierarchy filter.
    report_bus_skew -delay_type min_max -file [file join $reports bus_skew.rpt]
    require_budget
    report_exceptions -coverage -file [file join $reports exceptions_coverage.rpt]
    require_budget
    report_exceptions -ignored -file [file join $reports exceptions_ignored.rpt]
    require_budget
    check_timing -verbose -file [file join $reports check_timing.rpt]
    require_budget
    report_drc -no_waivers -file [file join $reports drc.rpt]
    require_budget
    report_timing_summary -delay_type min_max -report_unconstrained -max_paths 10 \
        -file [file join $reports timing_summary.rpt]
    require_budget
    report_route_status -file [file join $reports route_status.rpt]
    require_budget
    report_cdc -details -no_waiver -all_checks_per_endpoint -file [file join $reports cdc.rpt]
    inspect_domain clk_pl_0 $pl_clock $pl_period $reports
    inspect_domain mmcm_clk $core_clock $core_period $reports
    require_fully_routed
    require_budget
    set started ""
    inspect_clock clk_pl_0 10.0
    inspect_clock mmcm_clk 25.0
    set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
    set bitstream [file join $output rk_ao486_bd_wrapper.bit]
    # Native write_bitstream DRC remains authoritative; no force or downgrades.
    write_bitstream -bin_file $bitstream
    require_regular_nonempty $bitstream
    require_regular_nonempty [file rootname $bitstream].bin
    require_fully_routed
} finally {
    if {$opened} { close_project }
}
# Native successful closure precedes this marker; root must still require exit0.
puts "## CHECKPOINT ROUTE COMPLETE (native artifacts/reports only; no deployment/timing/CDC acceptance asserted)"
