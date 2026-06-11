# =====================================================================
# Per-placed-cell CSV (module,sub,x,y) for the FULL-SoC routed checkpoint, for the
# colored device view. The BD wraps the core deep (design_kv260_i/u_kv260/inst/...
# u_core/u_core/<mod>), so attribute by KEYWORD match on the hierarchical name rather
# than the first path component. Shows the L1/AXI memory subsystem + ven_soc_axil
# alongside the core blocks (icache/uopcache/fpu/btb/tlb/engines/spine).
#
# Env:  DCP = routed checkpoint ; OUT = csv path
# Run:  DCP=.../design_kv260_wrapper_routed.dcp OUT=.../cells_loc.csv \
#         vivado -mode batch -source fpga/scripts/dump_cells_loc_soc.tcl -notrace
# =====================================================================
proc env_or {n d} { if {[info exists ::env($n)] && $::env($n) ne ""} { return $::env($n) } else { return $d } }
set DCP [env_or DCP ""]
set OUT [env_or OUT ""]
if {$DCP eq "" || $OUT eq ""} { puts "ERROR: set DCP and OUT"; exit 1 }
open_checkpoint $DCP
set fh [open $OUT w]
puts $fh "module,sub,x,y"
set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1 && LOC != ""}] {
    set loc [get_property LOC $c]
    if {![regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} continue
    set nm [get_property NAME $c]
    # keyword-based module attribution (most specific first: l1d before l1axi)
    if {[regexp {u_l1d|ven_l1d}            $nm]} { set mod l1d \
    } elseif {[regexp {axi_master}         $nm]} { set mod axi_master \
    } elseif {[regexp {u_l1axi|l1_axi}     $nm]} { set mod l1axi \
    } elseif {[regexp {soc_axil}           $nm]} { set mod soc_axil \
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
    # sub = leaf signal group (bit-indices + synth suffixes stripped) for luminance
    set sub [lindex [split $nm /] end]
    regsub -all {\[[^\]]*\]} $sub "" sub
    regsub {_i_[0-9].*$}     $sub "" sub
    regsub {_reg.*$}         $sub "" sub
    regsub {(_[0-9]+)+$}     $sub "" sub
    if {$sub eq ""} { set sub misc }
    puts $fh "$mod,$sub,$x,$y"; incr n
}
close $fh
puts "DUMP_SOC_DONE cells=$n out=$OUT"
