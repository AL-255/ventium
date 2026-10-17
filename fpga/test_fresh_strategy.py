"""Source-only build admission and native option tests, not CPU acceptance."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from run_fresh_strategy import source_inventory, stage_deadline, validate_native_synth, IMPL_LIMIT


class FreshTests(unittest.TestCase):
    def test_native_timing_driven_strategy(self):
        for strategy, directive in [('performance-netdelay', 'PerformanceOptimized'),
                                    ('routability-spread', 'AlternateRoutability')]:
            text = f'synth_design -top rk_ao486_bd_wrapper -part xczu15eg-ffvb1156-2-i -flatten_hierarchy rebuilt -directive {directive}\n'
            self.assertEqual(validate_native_synth(text, strategy), text.strip())
            for bad in (text.replace('rebuilt', 'none'), text.replace(directive, 'Default'),
                        text.strip()+' -no_timing_driven\n', text.strip()+' -incremental\n',
                        text+text, ''):
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    validate_native_synth(bad, strategy)

    def test_impl_deadline_includes_place_and_route(self):
        self.assertFalse(stage_deadline('synth_1\t100\n', 99999))
        self.assertFalse(stage_deadline('synth_1\t100\nimpl_1\t200\n', 200+IMPL_LIMIT-1))
        self.assertTrue(stage_deadline('impl_1\t200\nroute_design\t300\n', 200+IMPL_LIMIT))
        with self.assertRaises(ValueError): stage_deadline('impl_1\t1\nimpl_1\t2\n', 10)

    def test_old_checkpoint_and_symlink_cannot_enter_source(self):
        with tempfile.TemporaryDirectory(prefix='fresh-freeze-test-') as td:
            root = Path(td)
            (root/'a.sv').write_text('module a; endmodule\n')
            self.assertEqual(set(source_inventory(root)), {'a.sv'})
            for suffix in ('.dcp', '.bit', '.xsa', '.xpr', '.edf', '.edn', '.ngc'):
                p = root/('prior'+suffix); p.write_bytes(b'old product')
                with self.assertRaises(ValueError): source_inventory(root)
                p.unlink()
            (root/'linked.sv').symlink_to(root/'a.sv')
            with self.assertRaises(ValueError): source_inventory(root)

    def test_tcl_interceptors_apply_real_options_after_legacy_defaults(self):
        # Exercise the actual Tcl procs, replacing only native vendor commands.
        script = Path(__file__).with_name('fresh_strategy.tcl').read_text()
        prefix = script.split('# The source-only platform wrapper owns exact defines')[0]
        for strategy, directive, place, route in (
                ('performance-netdelay', 'PerformanceOptimized', 'ExtraNetDelay_high', 'NoTimingRelaxation'),
                ('routability-spread', 'AlternateRoutability', 'AltSpreadLogic_medium', 'AlternateCLBRouting')):
            with tempfile.TemporaryDirectory(prefix='fresh-tcl-test-') as td:
                mock = '''
proc version {args} {return 2025.2}
proc set_param {args} {}
proc create_project {args} {}
proc launch_runs {args} {}
proc current_project {} {return project}
proc config_ip_cache {args} {set ::props(project,IP_CACHE_PERMISSIONS) disable}
proc get_runs {r} {return $r}
proc list_property {r} {return {AUTO_INCREMENTAL_CHECKPOINT INCREMENTAL_CHECKPOINT}}
proc report_property {args} {}
proc get_bd_cells {c} {return $c}
proc get_bd_pins {p} {return $p}
proc get_files {args} {return active}
proc set_property {args} {
 if {[lindex $args 0] eq "-name"} {
  lassign $args a prop b value c obj
 } else {lassign $args prop value obj}
 set ::props($obj,$prop) $value
}
proc get_property {prop obj} {
 if {[info exists ::props($obj,$prop)]} {return $::props($obj,$prop)}
 if {$prop eq "TYPE"} {return data}
 if {$prop eq "NAME"} {return [list $::frozen/ventium/fpga/ven_programmable_clock.v $::frozen/ventium/fpga/ven_pll_ctrl.sv]}
 error "unexpected property $obj $prop"
}
set ::props(ps8,CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE) 1
set ::props(ps8,CONFIG.PSU__GPIO_EMIO_WIDTH) 95
set ::props(ps8,CONFIG.PSU__SAXIGP2__DATA_WIDTH) 128
'''
                checks = f'''
create_project trial
set ::props(synth_1,STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE) Default
set ::props(synth_1,AUTO_INCREMENTAL_CHECKPOINT) 1
set ::props(impl_1,INCREMENTAL_CHECKPOINT) /old/bad.dcp
launch_runs synth_1 -jobs 1
launch_runs impl_1 -to_step write_bitstream -jobs 1
foreach {{obj prop expected}} {{
 synth_1 STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE {directive}
 synth_1 AUTO_INCREMENTAL_CHECKPOINT 0
 impl_1 INCREMENTAL_CHECKPOINT {{}}
 impl_1 STEPS.PLACE_DESIGN.ARGS.DIRECTIVE {place}
 impl_1 STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE {route}
}} {{
 if {{[get_property $prop $obj] ne $expected}} {{error "readback mismatch $prop"}}
}}
if {{![catch {{launch_runs impl_1 -jobs 1}}]}} {{error "duplicate launch allowed"}}
puts FRESH-TCL-OK
'''
                runner = Path(td)/'test.tcl'
                runner.write_text(mock+f'\nset argc 3\nset argv [list {strategy} {{{td}/source}} {{{td}/build}}]\n'+prefix+checks)
                result = subprocess.run(['tclsh', str(runner)], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('FRESH-TCL-OK', result.stdout)


if __name__ == '__main__': unittest.main()
