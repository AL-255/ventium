# Read the freshly completed synthesis through its owning project. A generated
# synthesis child marks XDC files USED_IN_IMPLEMENTATION=false; timing queries
# in its TCL.POST context can consequently see zero clocks after synth_design.
# open_run restores the project's constraint set and its IP scoping. It reads
# only this run's just-built netlist, never another trial's checkpoint.
proc fresh_synth_evidence {} {
    set status [get_property STATUS [get_runs synth_1]]
    if {$status ne "synth_design Complete!"} {error "synthesis did not complete: $status"}
    open_run synth_1
    try {
        source [file join $::fresh_script_dir fresh_synth_post.tcl]
    } finally {
        close_design
    }
}
