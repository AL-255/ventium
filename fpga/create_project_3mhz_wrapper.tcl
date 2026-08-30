# Vivado launcher for the RK-XCZU15EG-F flow's /32 core-clock variant.
#
# The external flow's clk_div32.v correctly declares a 3 MHz output, but its
# create_project.tcl still carries the old /16 metadata (c3f=6 MHz).  Vivado
# 2025.2 rejects the resulting AXI/clock-interface mismatch during BD
# validation.  Evaluate the authoritative flow script with that stale metadata
# corrected and, by default, with the repaired conservative system fast path
# enabled.  Set VEN_FPGA_FASTPATH=0 for a source-identical diagnostic A/B image
# with that one define omitted.  The enabled profile is intentionally
# VEN_SYS_FASTPATH only: VEN_SYS_FASTPATH_ALL remains an experimental
# real-mode/segmentation expansion and is not part of either image.
# The stock Linux platform leaves pl0_ref at exactly 100 MHz even though the
# external project asks Vivado to model 96 MHz; the previous routed image used
# 95.456 MHz and constrained the /32 core to 2.983 MHz while silicon ran at
# 3.125 MHz.  The difference exceeded the final setup margin.  Merely changing
# the target to 100 MHz is insufficient because the imported preset keeps its
# 96.968727 MHz RPLL/divider realization, so also match the live clock source
# and dividers.  No RTL is changed.  The source-matched
# default synthesis missed detailed placement by only 190 CLBs while leaving
# most BRAM and DSP resources idle.  Vivado 2025.2's supported
# AreaOptimized_high directive is therefore applied to synth_1; it preserves
# logic semantics while allowing the mapper to trade those spare dedicated
# resources for LUT/CLB relief.

# The Ventium-swapped hierarchy is large enough that Vivado's default internal
# synthesis fan-out can exhaust this 32 GiB host (seven ~2 GiB task workers plus
# a ~6 GiB parent were observed on the first source-matched run).  Four threads
# are the normal cap; VEN_FPGA_JOBS permits a lower diagnostic cap after an
# abnormal worker termination without changing the synthesized design.
set synth_jobs 4
if {[info exists ::env(VEN_FPGA_JOBS)]} {
    set synth_jobs $::env(VEN_FPGA_JOBS)
}
if {![string is integer -strict $synth_jobs] || $synth_jobs < 1 || $synth_jobs > 4} {
    error "VEN_FPGA_JOBS must be an integer from 1 through 4"
}
set_param general.maxThreads $synth_jobs
puts "Vivado synthesis concurrency: $synth_jobs"

# Keep the recovered 3.125 MHz image as the default diagnostic fallback, but
# permit a meaningful timing/bring-up candidate after an area reduction.  The
# PS PL0 source is fixed at 100 MHz below, so the high-speed variant uses its
# synchronous /2 derivative (50 MHz) rather than introducing an unrelated
# clock-domain crossing.  Other rates must be expressed by a real divider and
# are rejected instead of silently constraining the wrong frequency.
set core_div_file_add_span {lappend files "$ROOT/$x"}
set core_c3f_span {set c3f 3000000}
set core_label_span {CLK3 (core) label = $c3f (actual = pl_clk0/32)}
if {[info exists ::env(VEN_FPGA_CORE_MHZ)] && $::env(VEN_FPGA_CORE_MHZ) ne ""} {
    if {$::env(VEN_FPGA_CORE_MHZ) ne "50"} {
        error "VEN_FPGA_CORE_MHZ supports only 50 (omit it for the 3.125 MHz fallback)"
    }
    set core_div_file_add_span {
if {$x eq "src/clk_div32.v"} {
    lappend files "$VEN/fpga/clk_div32_50mhz.v"
} else {
    lappend files "$ROOT/$x"
}}
    set core_c3f_span {set c3f 50000000}
    set core_label_span {CLK3 (core) label = $c3f (actual = pl_clk0/2)}
    puts "High-speed candidate: synchronous core clock = pl_clk0/2 = 50 MHz"
}

set upstream "/home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system/hw/create_project.tcl"
set upstream_hw [file dirname $upstream]
set upstream_root [file dirname $upstream_hw]

# The upstream project explicitly supports a preset-free fallback for a
# PCAP-only build: Linux has already configured the PS and the project itself
# supplies the PL-facing GP0/HP0/PL-clock settings.  Use it only when this
# Vivado/IP catalog rejects the template's board-level MIO/DDR preset.
set preset_span {set TMPL "/home/yukidama/external/RK-XCZU15EG-F-Template"}
if {[info exists ::env(VEN_FPGA_SKIP_PRESET)] && $::env(VEN_FPGA_SKIP_PRESET)} {
    set preset_span {set TMPL "/__ventium_no_preset__"}
    puts "PCAP-only build: skipping incompatible template PS preset"
}

# The core filelist contains both FPU implementations.  The shipped board
# profile selects the compact shared hierarchy explicitly; non-shared test
# configurations still elaborate the legacy owner as a control.
set define_span {VEN_FP_PC_RELAX VEN_FP_SHARED VEN_SYS_FASTPATH VEN_FAST_RETRACE}
if {[info exists ::env(VEN_FPGA_FASTPATH)] && !$::env(VEN_FPGA_FASTPATH)} {
    set define_span {VEN_FP_PC_RELAX VEN_FP_SHARED VEN_FAST_RETRACE}
    puts "Diagnostic build: VEN_SYS_FASTPATH disabled by VEN_FPGA_FASTPATH=0"
}
# CWSDPMI's 32-bit client maps CS/DS/SS/ES at one nonzero common base.  The
# optional relocated profile remains much narrower than FASTPATH_ALL: only
# non-real, D=1, common-base register/relative forms enter S_PIPE; memory
# forms still take the checked slow FSM unless FASTLOAD is explicitly enabled.
if {[info exists ::env(VEN_FPGA_RELOC_FASTPATH)] && $::env(VEN_FPGA_RELOC_FASTPATH)} {
    if {[lsearch -exact $define_span VEN_SYS_FASTPATH] < 0} {
        error "VEN_FPGA_RELOC_FASTPATH requires VEN_SYS_FASTPATH"
    }
    lappend define_span VEN_SYS_FASTPATH_RELOC
    puts "Experimental build: VEN_SYS_FASTPATH_RELOC enabled"
}
# Experimental but system-differentially validated extension of the conservative
# fast path: only flat 32-bit MOV r32,[r32] keeps its existing D-TLB/page-walk
# and fragment-engine handling.  Opt in per build; keeping it out of the
# default bitstream makes an A/B rollback source-identical.
if {[info exists ::env(VEN_FPGA_FASTLOAD)] && $::env(VEN_FPGA_FASTLOAD)} {
    if {[lsearch -exact $define_span VEN_SYS_FASTPATH] < 0} {
        error "VEN_FPGA_FASTLOAD requires VEN_SYS_FASTPATH"
    }
    lappend define_span VEN_SYS_FASTLOAD_FLAT
    puts "Experimental build: VEN_SYS_FASTLOAD_FLAT enabled"
}

set fh [open $upstream r]
set body [read $fh]
close $fh

set area_synth "set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AreaOptimized_high \[get_runs synth_1\]\nlaunch_runs synth_1 -jobs $synth_jobs; wait_on_run synth_1"

set body [string map [list \
    {set TMPL "/home/yukidama/external/RK-XCZU15EG-F-Template"} \
    $preset_span \
    {set THIS [file normalize [info script]]; set HW [file dirname $THIS]} \
    "set THIS {$upstream}; set HW {$upstream_hw}" \
    {set ROOT [file normalize [file join $HW ..]]} \
    "set ROOT {$upstream_root}" \
    {lappend files "$ROOT/$x"} \
    $core_div_file_add_span \
    {CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {96} ] $ps} \
    {CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} ] $ps
# Match the already-running board clock tree used by PL-only PCAP loads:
# IOPLL (1.5 GHz) / 15 / 1 = 100 MHz.  The imported preset instead selects
# RPLL / 11 and realizes 96.968727 MHz; changing only FREQMHZ does not override
# those user-locked source/divider properties.
set_property -dict [list \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__SRCSEL {IOPLL} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__DIVISOR0 {15} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__DIVISOR1 {1} ] $ps} \
    {set c3f 6000000} \
    $core_c3f_span \
    {VEN_FP_PC_RELAX VEN_FAST_RETRACE} \
    $define_span \
    {CLK3 (core) label = $c3f (actual = pl_clk0/16)} \
    $core_label_span \
    {launch_runs synth_1 -jobs 4; wait_on_run synth_1} \
    $area_synth \
    {add_files -fileset constrs_1 -norecurse "$HW/bitstream.xdc" "$HW/led.xdc" "$HW/fpatan_mcp.xdc"
# fpatan multicycle references synthesized cells: apply in implementation (post-synth netlist).
set_property used_in_synthesis false [get_files "$HW/fpatan_mcp.xdc"]
# ensure the timing (multicycle) xdc is processed after the clock definitions
set_property PROCESSING_ORDER LATE [get_files "$HW/fpatan_mcp.xdc"]} \
    {# The external project's MCP targets the legacy fpu_fpatan hierarchy.  The
# VEN_FP_SHARED profile selected above replaces that engine entirely, so keeping
# this XDC would create unmatched-object critical warnings and, more importantly,
# could not legitimately relax timing on the replacement engine.  Keep only the
# board constraints for this shared-FPU wrapper; shared transcendentals are timed
# at their real single-cycle register boundaries.
add_files -fileset constrs_1 -norecurse "$HW/bitstream.xdc" "$HW/led.xdc"} \
    {open_run impl_1
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "## WNS (setup worst slack) = $wns"} \
    {open_run impl_1
    # Frequency leads the completion record.  WNS/WHS only demonstrate timing
    # closure at this constraint; they do not measure a board clock.  The
    # selected divider creates these two clocks in the final routed design.
    # Only the physical divider selected above differs.
    set core_clk_role {core (/32)}
    if {[info exists ::env(VEN_FPGA_CORE_MHZ)] && $::env(VEN_FPGA_CORE_MHZ) eq "50"} {
        set core_clk_role {core (/2)}
    }
    # ``u_clkdiv_clk_out`` is the generated-clock name emitted by the
    # recovered BD.  Older checkpoints called the same interface ``wr_clk_i``;
    # accept that legacy name for reports made from those checkpoints.
    set core_clk_name wr_clk_i
    foreach candidate {u_clkdiv_clk_out wr_clk_i} {
        if {[llength [get_clocks -quiet $candidate]] == 1} {
            set core_clk_name $candidate
            break
        }
    }
    foreach {clk_name clk_role} [list clk_pl_0 {PL / HP0} $core_clk_name $core_clk_role] {
        set clk_obj [get_clocks -quiet $clk_name]
        if {[llength $clk_obj] != 1} {
            puts "## Frequency ($clk_role): unavailable (expected $clk_name)"
        } else {
            set clk_period [get_property PERIOD $clk_obj]
            if {![string is double -strict $clk_period] || $clk_period <= 0.0} {
                puts "## Frequency ($clk_role): unavailable (invalid period $clk_period)"
            } else {
                puts [format "## Frequency (%s): %.6f MHz (%.6f ns constrained period)" \
                    $clk_role [expr {1000.0 / $clk_period}] $clk_period]
            }
        }
    }
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    puts "## WNS (setup worst slack) = $wns"
    puts "## WHS (hold worst slack) = $whs"} \
] $body]

# The passive scan-out recorder lives in the Ventium worktree rather than the
# reference-platform checkout.  It is a standalone module instantiated by the
# narrowly patched PL top (fpga/patches/0001-passive-vga-frame-capture.patch).
set body [string map [list \
    {add_files -norecurse $files} \
    {lappend files "$VEN/fpga/ven_video_capture.sv"
add_files -norecurse $files} \
] $body]

uplevel #0 $body
