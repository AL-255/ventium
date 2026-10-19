"""Source-only build admission and native option tests, not CPU acceptance."""
import os
import itertools
from pathlib import Path
import subprocess
import tempfile
import unittest

from run_fresh_strategy import (source_inventory, stage_deadline, validate_native_synth,
    IMPL_LIMIT, task_policy, task_pressure, check_scope_limits, memory_policy, resource_stop, GIB)
from test_audit_fresh_strategy import SCRIPT, PROPS


class FreshTests(unittest.TestCase):
    def test_memory_profiles_keep_fixed_caps_and_reserves(self):
        for name, ram in (('standard16', 16), ('serial20', 20)):
            self.assertEqual(memory_policy(name, 1), (ram, 6))
            limits = dict(MemoryMax=str(ram*GIB), MemorySwapMax=str(6*GIB), TasksMax='48')
            self.assertEqual(check_scope_limits(limits, 48, name), limits)
            with self.assertRaises(ValueError):
                check_scope_limits({**limits, 'MemoryMax':str((ram+1)*GIB)}, 48, name)
            resources = dict(MemAvailable=2*GIB, SwapFree=2*GIB)
            events = dict(oom='0', oom_kill='0')
            def stop(**kw):
                args = dict(ram=ram*GIB, swap=5*GIB, resources=resources, free=4*GIB,
                    events=events, limit_hit=False, ram_gib=ram, swap_gib=6)
                args.update(kw)
                return resource_stop(**args)
            self.assertIsNone(stop())
            self.assertEqual(stop(swap=5*GIB+1), 'combined memory early stop')
            self.assertEqual(stop(free=4*GIB-1), '4 GiB disk reserve')
            for key in resources:
                self.assertEqual(stop(resources={**resources, key:2*GIB-1}), '2 GiB host RAM/swap reserve')
            self.assertEqual(stop(events={**events, 'oom':'1'}), 'scope OOM')
            self.assertEqual(stop(events={**events, 'oom_kill':'1'}), 'scope OOM')
            self.assertEqual(stop(limit_hit=True), 'scope task limit')
        for name, threads in (('serial20', 2), ('unbounded', 1), (None, 1), (True, 1), ('serial20', True)):
            with self.assertRaises(ValueError): memory_policy(name, threads)
        with self.assertRaises(ValueError): check_scope_limits({}, 128, 'serial20')

    def test_task_profiles_are_fixed_and_limits_are_rechecked(self):
        for threads, profile, limit in ((1, 'serial', 48), (2, 'parallel2', 128)):
            self.assertEqual(task_policy(threads), (profile, limit))
            actual = dict(MemoryMax=str(16*GIB), MemorySwapMax=str(6*GIB), TasksMax=str(limit))
            self.assertEqual(check_scope_limits(actual, limit), actual)
            for key in actual:
                for value in ('max', '0', str(int(actual[key])+1)):
                    with self.assertRaises(ValueError):
                        check_scope_limits({**actual, key:value}, limit)
            with self.assertRaises(ValueError): check_scope_limits({}, limit)
        for bad in (0, 3, True, '2', 2.0):
            with self.assertRaises(ValueError): task_policy(bad)

    def test_task_limit_events_are_a_failure_even_if_cpu_still_advances(self):
        full = task_pressure('128\n', 'max 0\n', 128)
        self.assertFalse(full['limit_hit'])  # Occupancy alone is not a failure.
        rejected = task_pressure('48\n', 'max 3\n', 128)
        self.assertTrue(rejected['limit_hit'])  # A past denial must not disappear.
        self.assertEqual(rejected['events'], {'max':3})
        for count, events in (('129', 'max 0'), ('-1', 'max 0'), ('nan', 'max 0'),
                              ('1', ''), ('1', 'max -1'), ('1', 'max nan'),
                              ('1', 'max 0\nmax 0'), ('1', 'max 0 unexpected')):
            with self.subTest(count=count, events=events), self.assertRaises(ValueError):
                task_pressure(count, events, 128)

    def test_partial_native_probe_needs_stage_completion_evidence(self):
        script = Path(__file__).with_name('test_native_fresh_threads.tcl').read_text()
        prefix = script.split('# Source-only tooling probe')[0]
        runs = (('synth_1', 'synth_design', 'synth_design Complete!'),
                ('impl_1', 'opt_design', 'Not started place_design'))
        cases = ('ok', 'wrong-status', 'missing-end', 'error-marker', 'missing-log', 'error-log')
        for (run, step, status), case in itertools.product(runs, cases):
            with self.subTest(run=run, case=case), tempfile.TemporaryDirectory(prefix='fresh-native-status-') as td:
                root = Path(td)
                if run == 'impl_1': (root/'.opt_design.end.rst').touch()
                (root/'.vivado.end.rst').touch()
                (root/'runme.log').write_text(f'{step} completed successfully\n')
                if case == 'wrong-status': status = 'place_design Running'
                if case == 'missing-end': (root/'.vivado.end.rst').unlink()
                if case == 'error-marker': (root/'.vivado.error.rst').touch()
                if case == 'missing-log': (root/'runme.log').write_text(f'{step} started\n')
                if case == 'error-log': (root/'runme.log').write_text(f'{step} completed successfully\nERROR: failed\n')
                test = root/'check.tcl'
                test.write_text(prefix + f'\nfresh_threads_check_status {run} {step} {{{status}}} {{{root}}}\n')
                result = subprocess.run(['tclsh', str(test)], text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, case == 'ok', result.stdout+result.stderr)

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
                ('routability-spread', 'AlternateRoutability', 'AltSpreadLogic_medium', 'AlternateCLBRouting'),
                ('performance-retime-bounded', 'PerformanceOptimized', 'AltSpreadLogic_medium', 'NoTimingRelaxation'),
                ('performance-bounded', 'PerformanceOptimized', 'AltSpreadLogic_medium', 'NoTimingRelaxation'))
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
 synth_1 STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING {'on' if strategy == 'performance-retime-bounded' else 'off' if strategy == 'performance-bounded' else 'auto'}
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
                if strategy in ('performance-retime-bounded', 'performance-bounded'):
                    checks += '''
if {[get_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE impl_1] ne "Default"} {error "directive retained"}
if {[get_property {STEPS.PHYS_OPT_DESIGN.ARGS.MORE OPTIONS} impl_1] ne "-fanout_opt -placement_opt -restruct_opt -equ_drivers_opt"} {error "pre-route operations differ"}
if {[get_property {STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.MORE OPTIONS} impl_1] ne "-placement_opt -routing_opt -restruct_opt -hold_fix"} {error "post-route operations differ"}
'''
                runner = Path(td)/'test.tcl'
                runner.write_text(mock+f'\nset argc 4\nset argv [list {strategy} {{{td}/source}} {{{td}/build}} {threads}]\n'+prefix+checks)
                result = subprocess.run(['tclsh', str(runner)], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('FRESH-TCL-OK', result.stdout)


if __name__ == '__main__': unittest.main()
