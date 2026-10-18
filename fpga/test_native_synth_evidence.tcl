# Run through run_vivado_exclusive.sh in a new external scratch directory.
# Source-only regression of the real project-level evidence hook; not a CPU,
# APR or hardware acceptance result. No old checkpoint is an input.
if {$argc != 1} {error "usage: new-output-directory"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "output directory must be new"}
file mkdir $out
set_param general.maxThreads 1
set ::fresh_script_dir [file dirname [file normalize [info script]]]
set ::env(VEN_FRESH_OUT) $out/evidence
file mkdir $::env(VEN_FRESH_OUT)
source $::fresh_script_dir/fresh_synth_evidence.tcl
create_project clock_evidence_test $out/project -part xczu15eg-ffvb1156-2-i
config_ip_cache -disable_cache
add_files [list $::fresh_script_dir/clock_evidence_tb.sv \
    $::fresh_script_dir/ven_pll_ctrl.sv $::fresh_script_dir/ven_programmable_clock.v]
add_files -fileset constrs_1 $::fresh_script_dir/clock_evidence_tb.xdc
set_property top clock_evidence_tb [current_fileset]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized [get_runs synth_1]
launch_runs synth_1 -jobs 1
wait_on_run synth_1
fresh_synth_evidence
puts CLOCK-PROJECT-VIEW-PROBE-OK
