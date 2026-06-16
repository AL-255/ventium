# check_hold_cone.tcl — confirm the hold/setup margins on the EIP -> L1 fetch-byte-select
# cone in the deployed proxyfprc routed design (root-cause confirmation, no respin).
set DCP [lindex $argv 0]
open_checkpoint $DCP

puts "================ WORST HOLD PATHS (overall) ================"
report_timing_summary -delay_type min -max_paths 1 -nworst 1 -path_type summary

puts "================ WORST 15 HOLD PATHS (min-delay) ================"
report_timing -delay_type min -max_paths 15 -nworst 1 -sort_by slack -path_type short

puts "================ HOLD on the EIP -> rd_window_q / dc_line FETCH cone ================"
set src [get_pins -quiet {*u_core/u_core/eip_reg*/C}]
puts "eip source pins: [llength $src]"
if {[llength $src]} {
  report_timing -delay_type min -from $src -max_paths 30 -nworst 1 -sort_by slack -path_type full_clock_expanded
}

puts "================ SETUP on the EIP -> dc_line/rd_window_q cone (the WNS path) ================"
if {[llength $src]} {
  report_timing -delay_type max -from $src -max_paths 8 -nworst 1 -sort_by slack
}

puts "================ rd_window_q endpoints (the byte-select barrel shifter) ================"
set rw [get_cells -quiet {*u_l1d/rd_window_q_reg* *u_l1d/dc_line_reg*}]
puts "rd_window_q/dc_line cells: [llength $rw]"
if {[llength $rw]} {
  report_timing -delay_type min -to [get_pins -quiet -of_objects $rw -filter {IS_CLOCK}] -max_paths 10 -nworst 1 -sort_by slack
}
puts "================ DONE ================"
