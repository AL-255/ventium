"""Source-only build admission and native option tests, not CPU acceptance."""
import os
import itertools
from pathlib import Path
import subprocess
import tempfile
import unittest

from run_fresh_strategy import source_inventory, stage_deadline, validate_native_synth, IMPL_LIMIT
from test_audit_fresh_strategy import SCRIPT, PROPS


class FreshTests(unittest.TestCase):
    def test_native_timing_driven_strategy(self):
        for strategy, directive in [('performance-netdelay', 'PerformanceOptimized'),
                                    ('routability-spread', 'AlternateRoutability')]:
            text = SCRIPT.replace('PerformanceOptimized', directive).rstrip()+' -flatten_hierarchy rebuilt\n'
            props = PROPS.replace('PerformanceOptimized', directive)
            self.assertEqual(validate_native_synth(text, strategy, props), text.splitlines()[-1])
            omitted = text.replace(' -flatten_hierarchy rebuilt', '')
            self.assertEqual(validate_native_synth(omitted, strategy, props), omitted.splitlines()[-1])
            with self.assertRaises(ValueError):
                validate_native_synth(omitted, strategy, props.replace('rebuilt', 'none'))
            for bad in (text.replace('rebuilt', 'none'), text.replace(directive, 'Default'),
                        text.strip()+' -no_timing_driven\n', text.strip()+' -incremental\n',
                        text+text, ''):
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    validate_native_synth(bad, strategy, props)

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
        prefix = prefix.replace('set ::fresh_script_dir [file dirname [file normalize [info script]]]',
            'set ::fresh_script_dir {'+str(Path(__file__).parent.resolve())+'}')
        strategies = (
                ('performance-netdelay', 'PerformanceOptimized', 'ExtraNetDelay_high', 'NoTimingRelaxation'),
                ('routability-spread', 'AlternateRoutability', 'AltSpreadLogic_medium', 'AlternateCLBRouting'))
        for (strategy, directive, place, route), threads in itertools.product(strategies, (1, 2)):
            with tempfile.TemporaryDirectory(prefix='fresh-tcl-test-') as td:
                mock = '''
proc version {args} {return 2025.2}
proc set_param {name value} {set ::params($name) $value}
proc get_param {name} {return $::params($name)}
proc create_project {args} {}
proc launch_runs {run args} {set ::native_threads($run) [get_param general.maxThreads]}
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
set_param general.maxThreads 1
launch_runs synth_1 -jobs 1
if {{![catch {{launch_runs impl_1 -to_step write_bitstream -jobs 1}}]}} {{error "missing clock evidence allowed"}}
# No wait_on_run exists while the prefix loads, like native Vivado startup.
# The platform owns its normal wait. The actual evidence procedure's status
# checks and cleanup are exercised separately and by the native regression.
proc wait_on_run {{args}} {{set ::synth_done 1}}
proc fresh_synth_evidence {{}} {{
 if {{!$::synth_done}} {{error "synthesis not finished"}}
 set ::evidence_called 1
}}
wait_on_run synth_1
set_param general.maxThreads 1
launch_runs impl_1 -to_step write_bitstream -jobs 1
foreach run {{synth_1 impl_1}} {{
 if {{$::native_threads($run) != {threads}}} {{error "native thread setting lost"}}
}}
if {{!$::evidence_called}} {{error "evidence procedure not called"}}
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
if {{[get_property STEPS.SYNTH_DESIGN.TCL.POST synth_1] ne ""}} {{error "native post hook retained"}}
puts FRESH-TCL-OK
'''
                runner = Path(td)/'test.tcl'
                runner.write_text(mock+f'\nset argc 4\nset argv [list {strategy} {{{td}/source}} {{{td}/build}} {threads}]\n'+prefix+checks)
                result = subprocess.run(['tclsh', str(runner)], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('FRESH-TCL-OK', result.stdout)


if __name__ == '__main__': unittest.main()
