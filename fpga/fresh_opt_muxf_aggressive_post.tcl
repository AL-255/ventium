# Isolated experiment: normal RuntimeOptimized -> MUXF -> aggressive LUT remap.
# Keep the BRAM-power crash workaround; no bundled Explore directive, timing
# exceptions, preservation changes, checkpoint imports, or clock edits.
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
if {[get_property PART [current_design]] ne "xczu15eg-ffvb1156-2-i"} {
    error "remap target part mismatch"
}
set aggressive_threads [get_param general.maxThreads]
if {$aggressive_threads ni {4 8}} {error "unsupported remap thread count"}
if {[info exists ::fresh_muxf_started] || [info exists ::fresh_muxf_aggressive_started]} {
    error "duplicate remap pass"
}
foreach kind {core-paths utilization} {
    if {[file exists "fresh-muxf-post_aggressive-$kind.rpt"]} {
        error "pre-existing remap evidence"
    }
}
set ::fresh_muxf_aggressive_started 1
source [file join [file dirname [file normalize [info script]]] fresh_opt_muxf_post.tcl]
puts "FRESH-MUXF-AGGRESSIVE-BEGIN threads=$aggressive_threads command=opt_design-aggressive_remap"
opt_design -aggressive_remap
fresh_muxf_report post_aggressive
puts "FRESH-MUXF-AGGRESSIVE-END"
