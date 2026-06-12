# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# fpga/sd/gen_boot_artifacts.tcl — from a Ventium KV260 .xsa, generate the three
# standalone software pieces a baremetal SD boot needs:
#   * FSBL   (zynqmp_fsbl on psu_cortexa53_0) — configures the PS + loads the PL bitstream
#   * PMUFW  (zynqmp_pmufw on psu_pmu_0)      — platform management firmware
#   * app BSP scaffold (empty_application on psu_cortexa53_0) — libxil.a + lscript.ld +
#                                               crt0 that fpga/sd/ven_boot/ven_boot.c links against
#
# The FSBL/PMUFW depend only on the PS config (psu_init), which is fixed across Ventium PL
# revisions, so they are stable; only the .bit changes build-to-build. The empty_application
# final link intentionally fails ("undefined reference to main") — the BSP is what we want;
# build_sd_image.sh drops ven_boot.c in and re-links.
#
# Run (via the Vitis-bundled xsct, NOT /usr/bin/xsct which is a broken stub):
#   /tools/Xilinx/2025.2/Vitis/bin/xsct gen_boot_artifacts.tcl <abs .xsa> <abs outdir>

set xsa [lindex $argv 0]
set out [lindex $argv 1]
if {$xsa eq "" || $out eq ""} { puts "FATAL: usage: gen_boot_artifacts.tcl <xsa> <outdir>"; exit 2 }
file mkdir $out

puts "OPEN $xsa"
set d [hsi::open_hw_design $xsa]
puts "DESIGN=$d"

puts "=== FSBL (psu_cortexa53_0) ==="
hsi::generate_app -hw $d -os standalone -proc psu_cortexa53_0 -app zynqmp_fsbl -compile -dir $out/fsbl
puts "FSBL_ELF=[glob -nocomplain $out/fsbl/executable.elf]"

puts "=== PMUFW (psu_pmu_0) ==="
hsi::generate_app -hw $d -os standalone -proc psu_pmu_0 -app zynqmp_pmufw -compile -dir $out/pmufw
puts "PMUFW_ELF=[glob -nocomplain $out/pmufw/executable.elf]"

puts "=== app BSP scaffold (empty_application; final link 'no main' is EXPECTED) ==="
if {[catch { hsi::generate_app -hw $d -os standalone -proc psu_cortexa53_0 \
        -app empty_application -compile -dir $out/app } emsg]} {
    puts "APP_SCAFFOLD_LINK_SKIPPED (expected): $emsg"
}
set lib [glob -nocomplain $out/app/*_bsp/psu_cortexa53_0/lib/libxil.a]
puts "APP_BSP_LIB=$lib"
if {$lib eq ""} { puts "FATAL: BSP libxil.a not built"; exit 3 }
puts "GEN_BOOT_ARTIFACTS_DONE"
