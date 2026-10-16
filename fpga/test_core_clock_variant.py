"""Real Tcl parser with fake CAD commands: no Vivado or board access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

TARGET = Path(__file__).with_name('core_clock_variant.tcl').resolve()
STUBS = r'''
set edited 0
set output_divider 25
proc set_param {args} {if {$args ne {general.maxThreads 1}} {error threading}}
proc open_checkpoint {args} {}
proc current_project {} {return project}
proc current_design {} {return design}
proc close_design {} {}
proc report_route_status {args} {
    if {[lindex $args 0] ne "-boolean_check"} {return}
    set kind [lindex $args 1]
    if {$::fault eq "unrouted" && $kind eq "ROUTED_FULLY"} {return false}
    if {$kind in {PLACED_FULLY ROUTED_FULLY}} {return true}
    return false
}
proc get_clocks {args} {return [lindex $args end]}
proc get_cells {args} {
    if {[lindex $args end] eq {REF_NAME == MMCME4_ADV}} {
        if {$::fault eq "ambiguous"} {return {mmcm mmcm2}}
        return mmcm
    }
    set result {}; for {set i 0} {$i < 1000} {incr i} {lappend result cell$i}; return $result
}
proc get_nets {args} {
    set result {}; for {set i 0} {$i < 1000} {incr i} {lappend result net$i}; return $result
}
proc get_property {property object} {
    if {$property in {REF_NAME LOC BEL ROUTE ROUTE_STATUS} && [llength $object] > 128} {
        error "unbounded native property expansion"
    }
    switch -- $property {
        PART {return xczu15eg-ffvb1156-2-i}
        TOP {return rk_ao486_bd_wrapper}
        PERIOD {
            if {$object eq "clk_pl_0"} {
                if {$::fault eq "axi_changed" && $::edited} {return 8}
                return 10
            }
            if {$::fault eq "stale_clock"} {return 25}
            return $::output_divider
        }
        CLKFBOUT_MULT_F - CLKIN1_PERIOD {return 10}
        DIVCLK_DIVIDE {return 1}
        CLKOUT0_DIVIDE_F {return $::output_divider}
        REF_NAME {return lut_names}
        LOC {return fixed_locations}
        BEL {return fixed_bels}
        ROUTE {
            if {$::fault eq "route_drift" && $::edited} {return changed_route}
            return original_route
        }
        ROUTE_STATUS {return ROUTED}
        default {error "unmocked property $property"}
    }
}
proc set_property {property value object} {
    if {$property ne "CLKOUT0_DIVIDE_F" || $object ne "mmcm"} {error "forbidden mutation"}
    set ::edited 1
    if {$::fault ne "ignored_property"} {set ::output_divider $value}
}
proc report_property {args} {}
proc report_clocks {args} {}
proc report_timing_summary {args} {}
proc report_drc {args} {}
proc write_checkpoint {path} {set f [open $path {WRONLY CREAT EXCL}]; puts $f FAKE_CHECKPOINT; close $f}
proc write_bitstream {args} {
    if {$::fault eq "bitgen_error"} {error "native bitgen error"}
    if {[lindex $args 0] ne "-bin_file" || [llength $args] != 2} {error "unsafe bitgen args"}
    set bit [lindex $args 1]
    foreach path [list $bit [file rootname $bit].bin] {
        set f [open $path {WRONLY CREAT EXCL}]; puts $f FAKE_BITSTREAM; close $f
    }
}
'''


class Variants(unittest.TestCase):
    def run_case(self, divider, fault='', expected=True):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'],prefix='clock-tcl-test-') as tmp:
            root = Path(tmp)
            checkpoint = root/'fake.dcp'
            checkpoint.touch()
            script = (f'set argc 3\nset argv [list {{{checkpoint}}} {{{root / "out"}}} {{{divider}}}]\n'
                      f'set fault {{{fault}}}\n' + STUBS +
                      f'\nif {{[catch {{source {{{TARGET}}}}} problem]}} {{puts stderr $problem; exit 1}}\n')
            run = subprocess.run(['tclsh'],input=script,text=True,capture_output=True,timeout=10)
            self.assertEqual(run.returncode == 0, expected, run.stdout+run.stderr)
            if expected:
                self.assertIn('hardware_pass=false',run.stdout)
                self.assertTrue((root/'out/clock_variant.txt').exists())
            else:
                self.assertFalse((root/'out/clock_variant.txt').exists())

    def test_clock_points(self):
        for divider in (25,22,20,18,16.5,15,14.25,13.25,12.5,10):
            with self.subTest(divider=divider): self.run_case(divider)

    def test_invalid_divider(self):
        for divider in ('NaN','Inf',0,9,26,14.2,'abc'):
            with self.subTest(divider=divider): self.run_case(divider,expected=False)

    def test_guards(self):
        for fault in ('unrouted','ambiguous','axi_changed','stale_clock',
                      'route_drift','ignored_property','bitgen_error'):
            with self.subTest(fault=fault): self.run_case(14.25,fault,False)


if __name__ == '__main__': unittest.main()
