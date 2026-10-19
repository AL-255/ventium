# BD: ao486_MiSTer `system` (Ventium) on RK-XCZU15EG-F.  First-light: guest RAM in PS-DDR4 via
# S_AXI_HP0, single pl_clk0 domain, core @ ~3 MHz.  Usage:
#   vivado -mode batch -source hw/create_project.tcl -tclargs <mode> <outdir>
#     mode = bd (create+validate BD only) | xsa | all (impl+bitstream)
set THIS [file normalize [info script]]; set HW [file dirname $THIS]
set ROOT [file normalize [file join $HW ..]]
set TMPL "/home/yukidama/external/RK-XCZU15EG-F-Template"
set VEN  "/home/yukidama/github/ventium"
set MODE   [expr {$argc>=1 ? [lindex $argv 0] : "bd"}]
set OUTDIR [expr {$argc>=2 ? [lindex $argv 1] : "$ROOT/build"}]
# NB: BD must NOT be named "system" — the ao486 SoC top module is already `system`; a same-named
# BD makes synth bind the wrapper's instance to the 110-port ao486 module -> empty design.
set PART "xczu15eg-ffvb1156-2-i"; set PRJ "rk_ao486_system"; set BD "rk_ao486_bd"
file mkdir $OUTDIR
create_project $PRJ "$OUTDIR/$PRJ" -part $PART -force
set_property target_language Verilog [current_project]

# ---- RTL: ventium `system` + the two shims + the PL top -----------------------
# Cold-boot POST fixes (all verified against the freshly-cold-booting fpgacfg cosim, which now runs
# the VGA BIOS end-to-end):
#  VEN_FAST_RETRACE : synth the 0x3DA vertical-retrace (bit3) edge from clk_sys — the headless CRTC
#                     clk_vga never toggles real retrace, so the 0xC066D retrace poll spins forever.
#  VEN_KBD_AUTOACK  : the 8042 has NO attached PS/2 keyboard, so a host->keyboard send self-clocks
#                     but never gets the ACK that clears IBF; the BIOS then grinds a ~64k-iter
#                     software timeout per keyboard op (POST hung at code 0x60). Inject the 0xFA ACK
#                     on send completion so IBF clears at once (the cosim confirmed this advances POST
#                     0x60->0x77 and into the VGA BIOS).
#  VEN_KBC_FAST     : shrink the 8042's fallback keyboard hardware timeout (belt-and-suspenders).
# VEN_FAST_SNOW is intentionally OMITTED: it makes the 0x3DA anti-snow bit1 exit fast, but the
# VGA-BIOS monitor-detect (0x635d, cx=0x480) EXITS EARLY only when the snow poll TIMES OUT (setting
# si bit1); a fast bit1 defeats that and forces the full 1152-iteration slow scan. The cold-booting
# cosim omits it, so match. The real fix for POST is the moffs seg-base bug (decode_stages.sv, no
# define): the option-ROM scan's `mov al,[0xc0002]` was reading SS:2 (=0), so romlen=0 and the scan
# re-scanned 0xc000 forever -> POST hung at 0x77. With that fixed the cosim cold-boots to INT19.
set DEFS {SYNTHESIS VTM_NO_DPI VEN_CORE VEN_L1_AXI VEN_KV260_SOC VEN_L1_HONOR_CD \
          VEN_TRANSCENDENTAL VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE \
          VEN_BTB_PIPE VEN_CACHE_HALF VEN_IC_NARROWB VEN_ALTSYNCRAM_XPM VEN_DBG_CORE \
          VEN_FP_PC_RELAX VEN_FAST_RETRACE VEN_KBD_AUTOACK VEN_KBC_FAST VEN_FPREM}
set incdirs {}; set files {}
foreach f [list "$VEN/rtl_ven_soc.f" "$VEN/rtl_ven_core.f"] {
    set fh [open $f r]
    foreach line [split [read $fh] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#" || [string range $line 0 1] eq "//"} continue
        if {[string match "+incdir+*" $line]} { lappend incdirs "$VEN/[string range $line 8 end]" \
        } elseif {[string match "+define+*" $line]} { lappend DEFS [string range $line 8 end] \
        } else { lappend files "$VEN/$line" }
    }
    close $fh
}
foreach x [list src/ven_ddram_axi.v src/ven_mgmt_axil.v src/ven_soc_dbg.sv src/ven_ps2_kbd_inject.v src/ven_ps2_device.sv src/ven_ps2_mailbox.sv src/clk_div32.v src/rk_ao486_system_pl.v] { lappend files "$ROOT/$x" }
add_files -norecurse $files
set_property include_dirs $incdirs [current_fileset]
set_property verilog_define $DEFS [current_fileset]

# module-ref elaboration requires every `include header to be a PROJECT file (filemgmt 56-591).
set hdrs {}
foreach d [list "$VEN/rtl/core" "$VEN/rtl/fpu"] {
    foreach h [glob -nocomplain -directory $d *.svh] { lappend hdrs $h }
}
if {[llength $hdrs]} {
    add_files -norecurse -fileset sources_1 $hdrs
    set_property file_type "Verilog Header" [get_files $hdrs]
}

# Read the 3rd-party ao486 .v files as SystemVerilog (SV-isms Vivado's Verilog-2001 mode rejects;
# also makes each a separate compile unit so `default_nettype` cannot leak). Scope to the vendored
# tree only — our src/*.v (esp. the module-ref top) must stay Verilog (filemgmt 56-195).
foreach vf [get_files -filter {FILE_TYPE == Verilog}] {
    if {[string match "*3rd-party/ao486_MiSTer*" $vf]} { set_property file_type SystemVerilog $vf }
}

# ---- BD (first-light: guest RAM in PS-DDR4 via S_AXI_HP0; single pl_clk0 domain, ~3 MHz) ----
create_bd_design $BD
set ps [create_bd_cell -type ip -vlnv [get_ipdefs -filter {NAME==zynq_ultra_ps_e}] ps8]
# RK PS preset (DDR/MIO/clock sources). For a PCAP PL-only load into an already-booted Linux the
# PS DDR/MIO are set by the FSBL, so the preset is not strictly required — if the external template
# is unavailable, fall back to PS defaults + the explicit PL-facing overrides below.
set PRESET "$TMPL/board/XCZU15EG_Base_Config.tcl"
if {[file exists $PRESET]} {
    source $PRESET; set cfg [apply_preset $ps]
    dict for {k v} $cfg { if {[catch {set_property $k $v $ps} em]} { puts "  (skip $k)" } }
} else {
    puts "## WARNING: PS preset $PRESET missing — using PS defaults + PL-facing overrides"
}
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__USE__IRQ0 {1} CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {96} ] $ps
# EMIO32..47 command / EMIO64..94 status; always-on PS GPIO control.
set_property -dict [list CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE {1} CONFIG.PSU__GPIO_EMIO_WIDTH {95}] $ps
# SINGLE PS clock pl_clk0 = 96 MHz drives HP0 (fast enough for the PS S_AXI_HP async DDR FIFO,
# which corrupts reads at ~3 MHz). The ~3 MHz core clock is pl_clk0/32 (clk_div32, cascaded
# BUFGCE_DIV) -> the core and HP0 clocks are SYNCHRONOUS (same source, integer 32:1 ratio), so
# the 3 MHz<->96 MHz SmartConnect crossing is a synchronous multi-cycle path with NO metastability
# (the async-CDC read-data-beat duplication that derailed POST is a metastable-crossing artifact).
set clkdiv [create_bd_cell -type module -reference ven_programmable_clock u_clkdiv]
connect_bd_net [get_bd_pins $ps/pl_clk0]      [get_bd_pins $clkdiv/clk_in]
set CLK3 [get_bd_pins $clkdiv/clk_out]
connect_bd_net $CLK3                           [get_bd_pins $ps/maxihpm0_fpd_aclk]
connect_bd_net [get_bd_pins $ps/pl_clk0]      [get_bd_pins $ps/saxihp0_fpd_aclk]

# the PL top as a BD module reference (AXI intf bundles from its X_INTERFACE_INFO attrs)
set soc [create_bd_cell -type module -reference rk_ao486_system_pl u_soc]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $clkdiv/resetn]
connect_bd_net [get_bd_pins $ps/emio_gpio_o] [get_bd_pins $clkdiv/ps_gpio_o]
connect_bd_net [get_bd_pins $clkdiv/ps_gpio_i] [get_bd_pins $ps/emio_gpio_i]
connect_bd_net [get_bd_pins $soc/pll_safe] [get_bd_pins $clkdiv/safe_change]

# clock/reset. CLK3 = pl_clk0/32 = 3 MHz (core/SoC + mgmt); pl_clk0 = 96 MHz (HP0). SYNCHRONOUS.
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst0]
connect_bd_net $CLK3                        [get_bd_pins $rst/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rst/ext_reset_in]
connect_bd_net $CLK3                        [get_bd_pins $soc/clk]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $soc/resetn]
# 96 MHz-domain reset for the HP0 side of sc_mem
set rst1 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst1]
connect_bd_net [get_bd_pins $ps/pl_clk0]    [get_bd_pins $rst1/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rst1/ext_reset_in]

# control: HPM0(32b AXI-Lite @ 3 MHz) -> sc_ctrl -> soc.S_AXIL
set sc0 [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ctrl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc0
connect_bd_net      $CLK3 [get_bd_pins $sc0/aclk]
connect_bd_net      [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $sc0/aresetn]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc0/M00_AXI]       [get_bd_intf_pins $soc/S_AXIL]

# memory: soc.M_AXI(64b AXI4 @ CLK3 3 MHz) -> acc_mem (axi_clock_converter, CLK3->pl_clk0, 64b)
# -> dwc_mem (axi_dwidth_converter, 64b->128b @ pl_clk0) -> PS S_AXI_HP0_FPD @ pl_clk0, 128b.
# ROOT CAUSE of the odd-64b-word duplication: HP0 at 64b forced the PS-INTERNAL 128b-DDR->64b-AXI
# downsize, which returned the LOW 64b for BOTH halves of every 128b chunk (verified: guest 0xFCC08
# read back 0xFCC00's data). Proven NOT the PL CDC IP -- a pure axi_clock_converter duplicated
# byte-identically. Fix: present HP0 at its native 128b (no PS downsize) and do the 64<->128
# conversion on the PL side with an EXPLICIT dwidth converter whose MI is hard-set to 128b. A
# SmartConnect will NOT do this: it collapses the whole path to the 64b master width and only the
# explicit dwidth converter forces the PS HP0 to stick at 128b through save/generate propagation.
set acc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter acc_mem]
connect_bd_net      $CLK3                                   [get_bd_pins $acc/s_axi_aclk]
connect_bd_net      [get_bd_pins $rst/peripheral_aresetn]  [get_bd_pins $acc/s_axi_aresetn]
connect_bd_net      [get_bd_pins $ps/pl_clk0]              [get_bd_pins $acc/m_axi_aclk]
connect_bd_net      [get_bd_pins $rst1/peripheral_aresetn] [get_bd_pins $acc/m_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins $soc/M_AXI]  [get_bd_intf_pins $acc/S_AXI]

set dwc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dwidth_converter dwc_mem]
set_property CONFIG.MI_DATA_WIDTH {128} $dwc
connect_bd_net      [get_bd_pins $ps/pl_clk0]              [get_bd_pins $dwc/s_axi_aclk]
connect_bd_net      [get_bd_pins $rst1/peripheral_aresetn] [get_bd_pins $dwc/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins $acc/M_AXI]  [get_bd_intf_pins $dwc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $dwc/M_AXI]  [get_bd_intf_pins $ps/S_AXI_HP0_FPD]
puts "## WIDTH(after dwc connect) SAXIGP2 = [get_property CONFIG.PSU__SAXIGP2__DATA_WIDTH $ps] ; dwc MI = [get_property CONFIG.MI_DATA_WIDTH $dwc]"

# IRQ + status LEDs (the LEDs are the ONLY external PL I/O and the design's structural anchor:
# a portless BD wrapper is swept by synth).
connect_bd_net [get_bd_pins $soc/pl_ps_irq0] [get_bd_pins $ps/pl_ps_irq0]
make_bd_pins_external [get_bd_pins $soc/led]
set led_port [get_bd_ports -quiet led_0]
if {[llength $led_port]} { set_property name led $led_port }

# ---- clock freq reconciliation: SoC/mgmt on CLK3 (labeled 6 MHz, actual pl_clk0/16); HP0 on pl_clk0.
# clk_div32 annotates clk_out FREQ_HZ=6000000, so match every core-domain interface to that label
# (the real timing is the BUFGCE_DIV /16 generated clock, unaffected by this bookkeeping value).
set plf [get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk0]]
set c3f 6000000
puts "## pl_clk0 (HP0) FREQ_HZ = $plf ; CLK3 (core) label = $c3f (actual = pl_clk0/16)"
catch { set_property CONFIG.FREQ_HZ $c3f [get_bd_pins $soc/clk] }
catch { set_property CONFIG.FREQ_HZ $c3f [get_bd_intf_pins $soc/S_AXIL] }
catch { set_property CONFIG.FREQ_HZ $c3f [get_bd_intf_pins $soc/M_AXI] }
catch { set_property CONFIG.CLK_HZ  $c3f [get_bd_cells $soc] }
catch { set_property CONFIG.FREQ_HZ $c3f [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] }
catch { set_property CONFIG.FREQ_HZ $c3f [get_bd_intf_pins $sc0/S00_AXI] }
catch { set_property CONFIG.FREQ_HZ $c3f [get_bd_intf_pins $sc0/M00_AXI] }
catch { set_property CONFIG.FREQ_HZ $c3f [get_bd_intf_pins $acc/S_AXI] }
catch { set_property CONFIG.FREQ_HZ $plf [get_bd_intf_pins $acc/M_AXI] }
catch { set_property CONFIG.FREQ_HZ $plf [get_bd_intf_pins $dwc/S_AXI] }
catch { set_property CONFIG.FREQ_HZ $plf [get_bd_intf_pins $dwc/M_AXI] }

# ---- addresses: ctrl @ 0xA000_0000 (mgmt IDENT base); mem = identity onto PS-DDR ----
assign_bd_address
if {[catch {
  set cseg [get_bd_addr_segs -of_objects [get_bd_intf_pins $soc/S_AXIL]]
  assign_bd_address -target_address_space [get_bd_addr_spaces $ps/Data] $cseg -range 64K -offset 0xA0000000 -force
} em]} { puts "  (ctrl addr pin: $em — auto-assigned instead)" }
puts "## WIDTH(before validate) SAXIGP2 = [get_property CONFIG.PSU__SAXIGP2__DATA_WIDTH $ps]"
validate_bd_design
puts "## WIDTH(after validate) SAXIGP2 = [get_property CONFIG.PSU__SAXIGP2__DATA_WIDTH $ps]"
# Parameter propagation during validate can collapse the PS HP0 slave width to match the 64b master.
# Re-assert the native 128b (user param, authoritative) so the SmartConnect does the 64->128 upsize
# and the PS presents its native DDR width (no buggy internal 128->64 downsize).
if {[get_property CONFIG.PSU__SAXIGP2__DATA_WIDTH $ps] ne {128}} {
    set_property CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} $ps
    puts "## WIDTH re-asserted -> [get_property CONFIG.PSU__SAXIGP2__DATA_WIDTH $ps]"
    validate_bd_design
    puts "## WIDTH(after re-validate) SAXIGP2 = [get_property CONFIG.PSU__SAXIGP2__DATA_WIDTH $ps]"
}
save_bd_design
# global (in-context) BD synthesis + emit the BD's HDL, else `system_wrapper` is an empty stub.
set_property synth_checkpoint_mode None [get_files [current_bd_design].bd]
generate_target all [get_files [current_bd_design].bd]
make_wrapper -files [get_files [current_bd_design].bd] -top -import
set_property top ${BD}_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "## BD created+saved. mode=$MODE"
if {$MODE eq "bd"} { puts "## DONE (bd validate)"; return }

add_files -fileset constrs_1 -norecurse "$HW/bitstream.xdc" "$HW/led.xdc" "$HW/fpatan_mcp.xdc"
# fpatan multicycle references synthesized cells: apply in implementation (post-synth netlist).
set_property used_in_synthesis false [get_files "$HW/fpatan_mcp.xdc"]
# ensure the timing (multicycle) xdc is processed after the clock definitions
set_property PROCESSING_ORDER LATE [get_files "$HW/fpatan_mcp.xdc"]
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]

# ---- timing closure (task #49) --------------------------------------------
# The design routes at ~98% CLB packing and the failing paths are congestion-
# driven, not logic-depth-driven: post-PLACE WNS was +5.231 ns and ROUTING dragged
# it to -1.745 while resolving ~3000 node overlaps. No place/route directives were
# set, so the flow was running Vivado's DEFAULT effort. These directives change
# only placement/routing effort — the synthesized netlist is IDENTICAL, so there is
# no functional risk:
#   AltSpreadLogic_high : spread logic out to relieve the congestion that is
#                         lengthening routes on the x87 regfile / fsincos / icache paths.
#   Explore (route)     : more thorough routing search.
#   post-route phys_opt : one more optimisation pass after routing.
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE AltSpreadLogic_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore             [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true      [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]

launch_runs synth_1 -jobs 4; wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "## SYNTH FAILED (PROGRESS=[get_property PROGRESS [get_runs synth_1]])"; return }
puts "## SYNTH OK"
if {$MODE eq "all"} {
    set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized [get_runs impl_1]
    launch_runs impl_1 -to_step write_bitstream -jobs 4; wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        puts "## IMPL FAILED (PROGRESS=[get_property PROGRESS [get_runs impl_1]])"; return }
    puts "## IMPL OK"
    set rundir "$OUTDIR/$PRJ/$PRJ.runs/impl_1"
    catch { file copy -force "$rundir/${BD}_wrapper.bit" "$OUTDIR/${PRJ}.bit" }
    catch { file copy -force "$rundir/${BD}_wrapper.bin" "$OUTDIR/${PRJ}.bit.bin" }
    open_run impl_1
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "## WNS (setup worst slack) = $wns"
    puts "## bitstream: $OUTDIR/${PRJ}.bit(.bin)"
}
puts "## DONE"
