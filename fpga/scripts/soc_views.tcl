# =====================================================================
# fpga/scripts/soc_views.tcl — one-shot extraction for the FULL-SoC device views
# + congestion map from a ROUTED checkpoint. Opens the (large) routed .dcp ONCE and
# emits both products so the render_*.py scripts can draw without re-opening Vivado:
#   * OUT/cells_loc_soc.csv     (module,sub,x,y per placed leaf — dump_cells_loc_soc logic)
#   * OUT/congestion_router.rpt (report_design_analysis -congestion, router-level)
#
# Env:  DCP = routed checkpoint ; OUT = output dir
# Run:  DCP=.../design_kv260_wrapper_routed.dcp OUT=fpga/build/kv260_soc_impl_fe \
#         /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source fpga/scripts/soc_views.tcl -notrace
# =====================================================================
proc env_or {n d} { if {[info exists ::env($n)] && $::env($n) ne ""} { return $::env($n) } else { return $d } }
set DCP [env_or DCP ""]
set OUT [env_or OUT ""]
if {$DCP eq "" || $OUT eq ""} { puts "ERROR: set DCP and OUT"; exit 1 }
file mkdir $OUT
open_checkpoint $DCP

# ---- 1. per-cell CSV (keyword-based BD-hierarchy module attribution) ----------------
set csv $OUT/cells_loc_soc.csv
set fh [open $csv w]
puts $fh "module,sub,x,y"
set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1 && LOC != ""}] {
    set loc [get_property LOC $c]
    if {![regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} continue
    set nm [get_property NAME $c]
    if {[regexp {u_l1d|ven_l1d}            $nm]} { set mod l1d \
    } elseif {[regexp {soc_axil|/u_axil/}  $nm]} { set mod soc_axil \
    } elseif {[regexp {axi_master|/u_axi/} $nm]} { set mod axi_master \
    } elseif {[regexp {u_l1axi|l1_axi}     $nm]} { set mod l1axi \
    } elseif {[regexp {sc_mem|sc_ctrl|smartconnect|_sc_} $nm]} { set mod smartconnect \
    } elseif {[regexp {u_uopcache}         $nm]} { set mod uopcache \
    } elseif {[regexp {u_icache}           $nm]} { set mod icache \
    } elseif {[regexp {u_fpu_state|u_fpu}  $nm]} { set mod fpu \
    } elseif {[regexp {u_bpred_btb|bpred}  $nm]} { set mod btb \
    } elseif {[regexp {u_bcd2fp}           $nm]} { set mod bcd2fp \
    } elseif {[regexp {u_bcd}              $nm]} { set mod bcd \
    } elseif {[regexp {u_srt_div}          $nm]} { set mod srt_div \
    } elseif {[regexp {u_sqrt_iter}        $nm]} { set mod sqrt_iter \
    } elseif {[regexp {u_idiv}             $nm]} { set mod idiv \
    } elseif {[regexp {u_dtlb}             $nm]} { set mod dtlb \
    } elseif {[regexp {u_itlb}             $nm]} { set mod itlb \
    } elseif {[regexp {u_dcache_tm}        $nm]} { set mod dcache_tm \
    } elseif {[regexp {u_decode}           $nm]} { set mod decode \
    } elseif {[regexp {u_issue}            $nm]} { set mod issue \
    } else { set mod core_spine }
    set sub [lindex [split $nm /] end]
    regsub -all {\[[^\]]*\]} $sub "" sub
    regsub {_i_[0-9].*$}     $sub "" sub
    regsub {_reg.*$}         $sub "" sub
    regsub {(_[0-9]+)+$}     $sub "" sub
    if {$sub eq ""} { set sub misc }
    puts $fh "$mod,$sub,$x,$y"; incr n
}
close $fh
puts "DUMP_SOC_DONE cells=$n out=$csv"

# ---- 2. router congestion (the deliverable congestion map source) -------------------
report_design_analysis -congestion -file $OUT/congestion_router.rpt
puts "SOC_VIEWS_DONE"
