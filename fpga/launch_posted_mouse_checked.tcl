# Native Vivado admission immediately before expensive synthesis. The old
# textual source-list test missed devices removed by preprocessing.
rename launch_runs __ventium_native_launch_runs
set ::ventium_mouse_launches 0
proc launch_runs {run args} {
    if {$run ne "synth_1" || $::ventium_mouse_launches != 0} {
        error "only one synthesis launch is authorized; no implementation"
    }
    update_compile_order -fileset sources_1
    set names {}
    foreach object [get_files -compile_order sources -used_in synthesis] {
        lappend names [file normalize [get_property NAME $object]]
    }
    foreach name {rk_ao486_system_pl.v ven_ps2_device.sv ven_ps2_mailbox.sv} {
        set path [file normalize [file join $::env(VEN_FPGA_FLOW_ROOT) src $name]]
        if {[llength [lsearch -all -exact $names $path]] != 1} {
            error "mouse source absent/duplicated in active synthesis compile order: $path"
        }
        puts "MOUSE_POSTED_PREFLIGHT_SOURCE $path"
    }
    incr ::ventium_mouse_launches
    puts "MOUSE_POSTED_PREFLIGHT_OK exact_sources=3 implementation_authorized=false"
    return [uplevel 1 [list __ventium_native_launch_runs $run {*}$args]]
}
source [file join $::env(VEN_FPGA_SOURCE_ROOT) fpga create_project_3mhz_wrapper.tcl]
if {$::ventium_mouse_launches != 1} {error "expected one guarded synthesis launch"}
