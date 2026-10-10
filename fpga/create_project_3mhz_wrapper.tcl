# Vivado launcher for the RK-XCZU15EG-F flow's /32 core-clock variant.
#
# The external flow's clk_div32.v correctly declares a 3 MHz output, but its
# create_project.tcl still carries the old /16 metadata (c3f=6 MHz).  Vivado
# 2025.2 rejects the resulting AXI/clock-interface mismatch during BD
# validation.  Evaluate the authoritative flow script with that stale metadata
# corrected and, by default, with the repaired system fast path enabled for
# literal-flat and equal-common-base 32-bit protected-mode clients, including
# the independently verified full-limit and finite-page-safe DS memory
# subset. UV + fast-pipe is mandatory for this launcher. Legacy environment
# knobs that disable the fast path are rejected, including with an explicit
# frozen define file. Slow/U-only controls require a separately labelled
# diagnostic flow and cannot qualify a processor repair. VEN_SYS_FASTPATH_ALL
# remains an experimental
# real-mode/heterogeneous-segmentation expansion and is not part of any image.
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
# a ~6 GiB parent were observed on the first source-matched run).  Runs are
# deliberately single-threaded: reproducibility and host safety outweigh build
# time, and the launcher serializes whole Vivado instances as well.
set synth_jobs 1
if {[info exists ::env(VEN_FPGA_JOBS)]} {
  set synth_jobs $::env(VEN_FPGA_JOBS)
}
if {![string is integer -strict $synth_jobs] || $synth_jobs != 1} {
    error "VEN_FPGA_JOBS must be exactly 1"
}
set_param general.maxThreads $synth_jobs
puts "Vivado synthesis concurrency: $synth_jobs"

# Keep the recovered 3.125 MHz image as the default diagnostic fallback, but
# permit a meaningful timing/bring-up candidate after an area reduction.  The
# PS PL0 source is fixed at 100 MHz below.  The 50 MHz option is its
# synchronous /2 derivative; the 40/45 MHz options use a locked UltraScale+ MMCM
# derivative of the same source.  Both keep core and HP0 frequency-related
# rather than introducing an unrelated clock-domain crossing.  Other rates
# must be expressed by a real divider and are rejected instead of silently
# constraining the wrong frequency.
set core_div_file_add_span {lappend files "$ROOT/$x"}
set core_c3f_span {set c3f 3000000}
set core_label_span {CLK3 (core) label = $c3f (actual = pl_clk0/32)}
if {[info exists ::env(VEN_FPGA_CORE_MHZ)] && $::env(VEN_FPGA_CORE_MHZ) ne ""} {
    if {$::env(VEN_FPGA_CORE_MHZ) ni {40 45 50}} {
        error "VEN_FPGA_CORE_MHZ supports 40, 45 or 50 (omit it for the 3.125 MHz fallback)"
    }
    if {$::env(VEN_FPGA_CORE_MHZ) eq "50"} {
    set core_div_file_add_span {
if {$x eq "src/clk_div32.v"} {
    lappend files "$VEN/fpga/clk_div32_50mhz.v"
} else {
    lappend files "$ROOT/$x"
}}
    set core_c3f_span {set c3f 50000000}
    set core_label_span {CLK3 (core) label = $c3f (actual = pl_clk0/2)}
    puts "High-speed candidate: synchronous core clock = pl_clk0/2 = 50 MHz"
    } elseif {$::env(VEN_FPGA_CORE_MHZ) eq "40"} {
    set core_div_file_add_span {
if {$x eq "src/clk_div32.v"} {
    lappend files "$VEN/fpga/clk_div32_40mhz.v"
} else {
    lappend files "$ROOT/$x"
}}
    set core_c3f_span {set c3f 40000000}
    set core_label_span {CLK3 (core) label = $c3f (actual = MMCM(pl_clk0) = 40 MHz)}
    puts "Core clock: locked MMCM 100 MHz * 10 / 25 = 40 MHz (1 GHz VCO)"
    } else {
    set core_div_file_add_span {
if {$x eq "src/clk_div32.v"} {
    lappend files "$VEN/fpga/clk_div32_45mhz.v"
} else {
    lappend files "$ROOT/$x"
}}
    set core_c3f_span {set c3f 45000000}
    set core_label_span {CLK3 (core) label = $c3f (actual = MMCM(pl_clk0) = 45 MHz)}
    puts "High-speed candidate: locked MMCM core clock = 45 MHz from pl_clk0"
    }
}

set upstream "/home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system/hw/create_project.tcl"
if {[info exists ::env(VEN_FPGA_FLOW_ROOT)]} {
    set upstream [file normalize [file join $::env(VEN_FPGA_FLOW_ROOT) hw create_project.tcl]]
}
set upstream_hw [file dirname $upstream]
set upstream_root [file dirname $upstream_hw]
set source_root "/home/yukidama/github/ventium"
if {[info exists ::env(VEN_FPGA_SOURCE_ROOT)]} {
    set source_root [file normalize $::env(VEN_FPGA_SOURCE_ROOT)]
}

# Reject disabling knobs even if a later explicit profile would override them:
# contradictory launch requests must not silently pass as UV/fast acceptance.
foreach knob {VEN_FPGA_FASTPATH VEN_FPGA_RELOC_FASTPATH VEN_FPGA_FASTLOAD VEN_FPGA_FASTSTORE VEN_FPGA_BOUNDED_FASTMEM} {
    if {[info exists ::env($knob)] && !$::env($knob)} {
        error "refusing FPGA build: mandatory UV+fast-pipe mode forbids $knob=0"
    }
}

# The upstream project explicitly supports a preset-free fallback for a
# PCAP-only build: Linux has already configured the PS and the project itself
# supplies the PL-facing GP0/HP0/PL-clock settings.  Use it only when this
# Vivado/IP catalog rejects the template's board-level MIO/DDR preset.
set preset_span {set TMPL "/home/yukidama/external/RK-XCZU15EG-F-Template"}
if {[info exists ::env(VEN_FPGA_TEMPLATE_ROOT)]} {
    set preset_span "set TMPL {[file normalize $::env(VEN_FPGA_TEMPLATE_ROOT)]}"
}
if {[info exists ::env(VEN_FPGA_SKIP_PRESET)] && $::env(VEN_FPGA_SKIP_PRESET)} {
    set preset_span {set TMPL "/__ventium_no_preset__"}
    puts "PCAP-only build: skipping incompatible template PS preset"
}

# The core filelist contains both FPU implementations.  The shipped board
# profile selects the compact shared hierarchy, the P5's full 8 KiB L1 caches,
# and the BRAM/uop-cache front end explicitly.  The upstream recovery script
# still names the retired half-cache/narrow I-cache experiment, so it is
# rewritten below before Vivado sees its definition list.
set define_span {VEN_FP_PC_RELAX VEN_FP_SHARED VEN_FP_SHARED_DIRECT VEN_SYS_FASTPATH VEN_SYS_FASTPATH_RELOC VEN_SYS_FASTLOAD_FLAT VEN_SYS_FASTLOAD_BOUNDED VEN_SYS_FASTSTORE_FLAT VEN_FAST_MEM_ADD VEN_FAST_MOFFS_STORE VEN_FAST_RETRACE}
if {[info exists ::env(VEN_FPGA_FASTPATH)] && !$::env(VEN_FPGA_FASTPATH)} {
    set define_span {VEN_FP_PC_RELAX VEN_FP_SHARED VEN_FP_SHARED_DIRECT VEN_FAST_RETRACE}
    puts "Diagnostic build: all VEN_SYS_FASTPATH defines disabled by VEN_FPGA_FASTPATH=0"
}
# CWSDPMI's 32-bit client maps CS/DS/SS/ES at one nonzero common base.  The
# default relocated profile remains much narrower than FASTPATH_ALL: only
# non-real, D=1, common-base register/relative forms plus the independently
# gated full-limit and finite-limit/page-safe DS packet forms enter S_PIPE.
# Every other memory form takes the checked slow FSM. A base-zero-only control remains available
# without accidentally re-enabling the system path after VEN_FPGA_FASTPATH=0
# has removed it.
if {[info exists ::env(VEN_FPGA_RELOC_FASTPATH)] && !$::env(VEN_FPGA_RELOC_FASTPATH)} {
    if {[lsearch -exact $define_span VEN_SYS_FASTPATH] >= 0} {
        set define_span {VEN_FP_PC_RELAX VEN_FP_SHARED VEN_FP_SHARED_DIRECT VEN_SYS_FASTPATH VEN_SYS_FASTLOAD_FLAT VEN_SYS_FASTLOAD_BOUNDED VEN_SYS_FASTSTORE_FLAT VEN_FAST_MEM_ADD VEN_FAST_MOFFS_STORE VEN_FAST_RETRACE}
        puts "Diagnostic build: VEN_SYS_FASTPATH_RELOC disabled by VEN_FPGA_RELOC_FASTPATH=0"
    } else {
        puts "Diagnostic build: VEN_SYS_FASTPATH_RELOC already absent because VEN_FPGA_FASTPATH=0"
    }
}
# The default fast-memory subset is the compact 32-bit full-limit DS/SS MOV
# r32,[...] / MOV [...],r32 family plus audited ADD r32,r/m32 and moffs forms.
# The bounded addition accepts a DS dword only wholly below its final limit
# page and within its starting offset page. Final-page/page-cross/faulting
# cases stay on the mature FSM/fragment path. `psysfpload`, `pfaststore`, and
# `psysfpbounded` differentially cover nonzero-base/nonidentity mapping,
# fault/restart, and finite-limit boundaries. The rollback controls below are
# source-identical A/B controls, not path-expansion knobs.
if {[info exists ::env(VEN_FPGA_FASTLOAD)] && $::env(VEN_FPGA_FASTLOAD)} {
    if {[lsearch -exact $define_span VEN_SYS_FASTPATH] < 0} {
        error "VEN_FPGA_FASTLOAD requires VEN_SYS_FASTPATH"
    }
}
if {[info exists ::env(VEN_FPGA_FASTLOAD)] && !$::env(VEN_FPGA_FASTLOAD)} {
    foreach d {VEN_SYS_FASTLOAD_FLAT VEN_SYS_FASTLOAD_BOUNDED VEN_FAST_MEM_ADD VEN_FAST_MOFFS_STORE VEN_SYS_FASTSTORE_FLAT} {
        set at [lsearch -exact $define_span $d]
        if {$at >= 0} { set define_span [lreplace $define_span $at $at] }
    }
    puts "Diagnostic build: fast load/store and finite-limit packet forms disabled by VEN_FPGA_FASTLOAD=0"
}
if {[info exists ::env(VEN_FPGA_FASTSTORE)] && $::env(VEN_FPGA_FASTSTORE)} {
    if {[lsearch -exact $define_span VEN_SYS_FASTPATH] < 0} {
        error "VEN_FPGA_FASTSTORE requires VEN_SYS_FASTPATH"
    }
    if {[lsearch -exact $define_span VEN_SYS_FASTLOAD_FLAT] < 0} {
        error "VEN_FPGA_FASTSTORE requires VEN_SYS_FASTLOAD_FLAT"
    }
}
if {[info exists ::env(VEN_FPGA_FASTSTORE)] && !$::env(VEN_FPGA_FASTSTORE)} {
    foreach d {VEN_SYS_FASTSTORE_FLAT VEN_FAST_MOFFS_STORE} {
        set at [lsearch -exact $define_span $d]
        if {$at >= 0} { set define_span [lreplace $define_span $at $at] }
    }
    puts "Diagnostic build: fast-store packet forms disabled by VEN_FPGA_FASTSTORE=0"
}
# The finite-limit extension is independently removable for a true source-level
# board A/B. Its decoder additions and bounded segment admission must move as a
# unit: otherwise the forms decode yet only manufacture avoidable slow-FSM
# traffic, the rejected experiment recorded in CPI_PROGRESS_Sep05.md.
if {[info exists ::env(VEN_FPGA_BOUNDED_FASTMEM)] && $::env(VEN_FPGA_BOUNDED_FASTMEM)} {
    foreach d {VEN_SYS_FASTLOAD_BOUNDED VEN_FAST_MEM_ADD VEN_FAST_MOFFS_STORE} {
        if {[lsearch -exact $define_span $d] < 0} {
            error "VEN_FPGA_BOUNDED_FASTMEM requires active system fast load/store support"
        }
    }
}
if {[info exists ::env(VEN_FPGA_BOUNDED_FASTMEM)] && !$::env(VEN_FPGA_BOUNDED_FASTMEM)} {
    foreach d {VEN_SYS_FASTLOAD_BOUNDED VEN_FAST_MEM_ADD VEN_FAST_MOFFS_STORE} {
        set at [lsearch -exact $define_span $d]
        if {$at >= 0} { set define_span [lreplace $define_span $at $at] }
    }
    puts "Diagnostic build: finite-limit packet forms disabled by VEN_FPGA_BOUNDED_FASTMEM=0"
}

# The measured performance candidate is intentionally opt-in.  It combines
# only general mechanisms: a two-way D-TLB, the audited seven-byte SIB+disp32
# ADD form, and lower-half L2 critical-word-first delivery.  Do not silently
# select it for a recovery or diagnostic build: its full-PC/Win95/PPA evidence
# must be attributable to this exact source-level profile.
if {[info exists ::env(VEN_FPGA_PERF_CANDIDATE)] && $::env(VEN_FPGA_PERF_CANDIDATE)} {
    foreach d {VEN_SYS_FASTPATH VEN_SYS_FASTLOAD_FLAT VEN_SYS_FASTLOAD_BOUNDED VEN_FAST_MEM_ADD} {
        if {[lsearch -exact $define_span $d] < 0} {
            error "VEN_FPGA_PERF_CANDIDATE requires the complete audited system fast-memory profile (missing $d)"
        }
    }
    foreach d {VEN_DTLB_ASSOC_2WAY VEN_FAST_MEM_ADD7 VEN_L2_STREAM_CWF} {
        if {[lsearch -exact $define_span $d] < 0} { lappend define_span $d }
    }
    puts "Performance candidate: DTLB2 + ADD7 + L2 critical-word-first enabled"
}

set fh [open $upstream r]
set body [read $fh]
close $fh
if {![regsub {set VEN[ \t]+"/home/yukidama/github/ventium"} $body \
    "set VEN {$source_root}" body]} {
    error "refusing FPGA build: could not pin upstream Ventium source root"
}

# Keep the historical settings reproducible. The balanced profile is an
# explicit candidate, not a claim of measured timing or area improvement.
set build_profile legacy
if {[info exists ::env(VEN_FPGA_BUILD_PROFILE)]} {
    set build_profile $::env(VEN_FPGA_BUILD_PROFILE)
}
if {$build_profile ni {legacy balanced logic_only}} {
    error "VEN_FPGA_BUILD_PROFILE must be legacy, balanced or logic_only"
}
set synth_directive AreaOptimized_high
if {$build_profile in {balanced logic_only}} { set synth_directive Default }
puts "FPGA build profile: $build_profile (synthesis $synth_directive)"
set area_synth "set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $synth_directive \[get_runs synth_1\]\nlaunch_runs synth_1 -jobs $synth_jobs; wait_on_run synth_1"

# Explicit diagnostic for the measured timing-optimization memory explosion.
# This changes synthesis's optimization objective, NOT the clock constraints,
# RTL, implementation timing analysis, or acceptance criteria. Keep the normal
# timing-driven defaults untouched. A completed logic_only synthesis is not a
# timing sign-off; implementation must still meet the real clock constraints.
if {$build_profile eq "logic_only"} {
    set logic_only_synth {
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-no_timing_driven} -objects [get_runs synth_1]
}
    set area_synth "$logic_only_synth\n$area_synth"
    puts "Diagnostic synthesis: -no_timing_driven; clock constraints and timing qualification unchanged"
}

# Apply the implementation profile after upstream's historical overrides, but
# before either run is launched. Keep spread placement for the known congestion
# problem; defer expensive route exploration until a routed baseline exists.
if {$build_profile in {balanced logic_only}} {
    set impl_profile {
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE AltSpreadLogic_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Default [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED false [get_runs impl_1]
}
    set area_synth "$impl_profile\n$area_synth"
}

# Bound implementation run fan-out too; this is separate from maxThreads.
set impl_launch {launch_runs impl_1 -to_step write_bitstream -jobs 4; wait_on_run impl_1}
if {[string first $impl_launch $body] < 0} {
    error "refusing FPGA build: could not locate the upstream impl_1 launch"
}
set body [string map [list $impl_launch \
    {launch_runs impl_1 -to_step write_bitstream -jobs 1; wait_on_run impl_1}] $body]

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
    {VEN_CACHE_HALF VEN_IC_NARROWB} \
    {VEN_IC_BRAM VEN_UOPCACHE VEN_UOP_SFETCH VEN_SFETCH_RESIDENT VEN_UOP_TAIL_LOCAL VEN_FP_PIPE2} \
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
    } elseif {[info exists ::env(VEN_FPGA_CORE_MHZ)] && $::env(VEN_FPGA_CORE_MHZ) in {40 45}} {
        set core_clk_role {core (MMCM)}
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

# The recovered upstream flow currently launches synth_1 with ``-jobs 4``.
# Treat that exact launch form as part of this wrapper's contract: if upstream
# changes it again, fail before Vivado can silently exceed the one-worker
# resource budget.  ``general.maxThreads`` alone does not constrain the run
# launcher, and the old ``-jobs 1`` string-map key had therefore become dead.
if {[string first {launch_runs synth_1 -jobs 4; wait_on_run synth_1} $body] >= 0} {
    error "refusing FPGA build: upstream synth_1 -jobs 4 launch escaped the one-worker wrapper"
}
if {[string first "launch_runs synth_1 -jobs $synth_jobs; wait_on_run synth_1" $body] < 0} {
    error "refusing FPGA build: could not install the one-worker synth_1 launch"
}

# A full P5 cache geometry is a release invariant, not merely a preferred
# implementation option.  Inspect the actual `set DEFS {...}` payload (rather
# than comments in the recovered upstream script) so an upstream-script change
# cannot silently revive the retired experiment.
# A frozen simulation profile may replace the legacy recovery defaults in its
# entirety. Do not append them: doing so would silently re-enable the uop cache
# and incompatible D-TLB experiments. One define per line, no Tcl evaluation.
set explicit_profile 0
if {[info exists ::env(VEN_FPGA_DEFINE_FILE)]} {
    set df [open $::env(VEN_FPGA_DEFINE_FILE) r]
    set explicit_defs [split [string trim [read $df]] "\n"]
    close $df
    foreach d $explicit_defs {
        if {![regexp {^[A-Z][A-Z0-9_]*$} $d]} {
            error "invalid FPGA define in frozen profile: $d"
        }
    }
    if {[llength [lsort -unique $explicit_defs]] != [llength $explicit_defs]} {
        error "duplicate FPGA defines in frozen profile"
    }
    if {![regsub {set DEFS \{[^\}]*\}} $body "set DEFS {[join $explicit_defs { }]}" body]} {
        error "could not replace the legacy FPGA define list"
    }
    set explicit_profile 1
    puts "Frozen FPGA profile: [llength $explicit_defs] exact defines"
}
if {![regexp {set DEFS \{([^\}]*)\}} $body -> fpga_defs_text]} {
    error "refusing FPGA build: could not locate the upstream set DEFS payload"
}
set fpga_defs [split $fpga_defs_text]
if {[lsearch -exact $fpga_defs VEN_CACHE_HALF] >= 0} {
    error "refusing FPGA build: VEN_CACHE_HALF is retired; use the full P5 L1 configuration"
}
if {[lsearch -exact $fpga_defs VEN_IC_NARROWB] >= 0} {
    error "refusing FPGA build: VEN_IC_NARROWB is retired; use the full P5 I-cache"
}
set required_defs {SYNTHESIS VTM_NO_DPI VEN_ALTSYNCRAM_XPM VEN_IC_BRAM VEN_SFETCH_RESIDENT VEN_FP_PIPE VEN_FP_PIPE2 VEN_FP_SHARED VEN_FP_SHARED_DIRECT VEN_SYS_FASTPATH VEN_SYS_FASTPATH_RELOC VEN_SYS_FASTLOAD_FLAT VEN_SYS_FASTLOAD_BOUNDED VEN_SYS_FASTSTORE_FLAT}
if {!$explicit_profile} {
    lappend required_defs VEN_UOPCACHE VEN_UOP_SFETCH VEN_UOP_TAIL_LOCAL
}
foreach required_def $required_defs {
    if {[lsearch -exact $fpga_defs $required_def] < 0} {
        error "refusing FPGA build: full-P5 profile is missing $required_def"
    }
}

# Source-contract guard, not a claim of dynamic pairing. The shim must have
# exactly one actual cycle_mode port connection, hardwired to dual issue.
# Hardware acceptance additionally requires paired fast-path execution evidence.
set uv_shim_path [file join $source_root ao486-sim ven ven_ao486_shim.sv]
set uv_shim_file [open $uv_shim_path r]
set uv_shim_body [read $uv_shim_file]
close $uv_shim_file
regsub -all {(?s)/\*.*?\*/} $uv_shim_body {} uv_shim_body
regsub -all {//[^\n]*} $uv_shim_body {} uv_shim_body
if {[regexp -all {\.cycle_mode\s*\(} $uv_shim_body] != 1 ||
    ![regexp {\.cycle_mode\s*\(\s*1'b1\s*\)} $uv_shim_body]} {
    error "refusing FPGA build: mandatory UV+fast-pipe mode requires cycle_mode=1'b1"
}
puts "UV-FAST-SOURCE-CONTRACT-OK: dual issue hardwired; system fast load/store and pipelined FP enabled"

# Opt-in posted transport is inseparable from its external-completion barrier.
# Never silently select a queue behind a shim that acknowledges I/O/debug at
# inner Avalon acceptance. This is source admission, not functional acceptance.
if {[lsearch -exact $fpga_defs VEN_DDR_POSTED] >= 0} {
    if {!$explicit_profile || [lsearch -exact $fpga_defs VEN_DBG_CORE] < 0} {
        error "posted DDR requires an explicit profile and VEN_DBG_CORE"
    }
    set posted_top_file [open [file join $upstream_root src rk_ao486_system_pl.v] r]
    set posted_top [read $posted_top_file]
    close $posted_top_file
    foreach span {{ven_ddram_axi_posted #(.MEM_BASE(MEM_BASE), .WRITE_SLOTS(16)) u_ddr}
                  {.fault(ddr_posted_fault), .drained(ddr_posted_drained)}
                  {18'd0, ddr_posted_fault, 1'b1, ddr_posted_drained}} {
        if {[string first $span $posted_top] < 0} {
            error "posted DDR platform drain wiring missing: $span"
        }
    }
    foreach span {{dbg_cmp[108] && dbg_cmp[107] && v_m_idle}
                  {d_halted && platform_memory_drained}
                  {.dbg_step(dbg_cmp[65] & platform_memory_drained)}} {
        if {[string first $span $uv_shim_body] < 0} {
            error "posted DDR shim drain wiring missing: $span"
        }
    }
    foreach signal {io_read_do io_write_do} {
        set predicate [format {assign\s+%s\s*=[^;]*&\s*platform_memory_drained\s*;} $signal]
        if {![regexp $predicate $uv_shim_body]} {
            error "posted DDR shim drain wiring missing: $signal"
        }
    }
    if {![file isfile [file join $source_root fpga ven_ddram_axi_posted.sv]]} {
        error "posted DDR bridge source missing"
    }
    puts "POSTED-DDR-SOURCE-CONTRACT-OK: sixteen slots, real completion barrier; runtime acceptance pending"
}

# The passive scan-out recorder lives in the Ventium worktree rather than the
# reference-platform checkout.  It is a standalone module instantiated by the
# narrowly patched PL top (fpga/patches/0001-passive-vga-frame-capture.patch).
set body [string map [list \
    {add_files -norecurse $files} \
    {lappend files "$VEN/fpga/ven_video_capture.sv" "$VEN/fpga/ven_axi_read_profiler.sv" "$VEN/fpga/ven_axi_write_profiler.sv"
if {[lsearch -exact $DEFS VEN_DDR_POSTED] >= 0} { lappend files "$VEN/fpga/ven_ddram_axi_posted.sv" }
add_files -norecurse $files} \
] $body]

# Upstream historically prints a failure and returns successfully. Make both
# run failures fatal; callers must still verify routed reports and bit hashes.
set body [string map [list \
    {puts "## SYNTH FAILED (PROGRESS=[get_property PROGRESS [get_runs synth_1]])"; return} \
    {error "FPGA synthesis failed (PROGRESS=[get_property PROGRESS [get_runs synth_1]])"} \
    {puts "## IMPL FAILED (PROGRESS=[get_property PROGRESS [get_runs impl_1]])"; return} \
    {error "FPGA implementation failed (PROGRESS=[get_property PROGRESS [get_runs impl_1]])"} \
    {catch { set_property CONFIG.CLK_HZ  $c3f [get_bd_cells $soc] }} \
    {set_property CONFIG.CLK_HZ $c3f [get_bd_cells $soc]} \
] $body]

uplevel #0 $body
