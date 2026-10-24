"""Source-only build admission and native option tests, not CPU acceptance."""
import os
import itertools
from pathlib import Path
import subprocess
import tempfile
import unittest

from run_fresh_strategy import (source_inventory, stage_deadline, validate_native_synth,
    IMPL_LIMIT, task_policy, task_pressure, check_scope_limits, memory_policy,
    implementation_policy, resource_stop, validate_output, argument_parser, STRATEGIES, GIB)
from test_audit_fresh_strategy import SCRIPT, PROPS


class FreshTests(unittest.TestCase):
    def test_native_thread_hook_checks_without_changing_worker_setting(self):
        hook = Path(__file__).with_name('fresh_threads8_pre.tcl').read_text()
        for version, observed in (('2025.2', '8'), ('2025.2', '4'),
                                  ('2025.2', '8.0'), ('2025.1', '8')):
            with self.subTest(version=version, observed=observed), tempfile.TemporaryDirectory(prefix='native-threads-') as td:
                script = (f'proc version {{args}} {{return {version}}}\n'
                          f'proc get_param {{p}} {{if {{$p ne "general.maxThreads"}} {{error "wrong parameter"}}; return {observed}}}\n'
                          'proc set_param {args} {error "must not fix a mismatch silently"}\n'+hook)
                runner = Path(td)/'hook.tcl'; runner.write_text(script)
                result = subprocess.run(['tclsh', str(runner)], text=True, capture_output=True)
                valid = version == '2025.2' and observed == '8'
                self.assertEqual(result.returncode == 0, valid, result.stdout+result.stderr)
                self.assertEqual(result.stdout.count('FRESH-NATIVE-THREADS-CHECK observed=8\n'), int(valid))

    def test_new_launch_defaults_to_eight_threads_without_launching(self):
        for strategy in STRATEGIES:
            with self.subTest(strategy=strategy):
                args = argument_parser().parse_args(['--strategy', strategy, '--output', 'unused'])
                self.assertEqual(args.threads, 8)
                self.assertEqual(args.memory_profile, 'unbounded')
                impl = implementation_policy(strategy, args.threads, args.memory_profile)
                self.assertEqual(impl, 8)
                self.assertEqual(task_policy(args.threads, impl), ('parallel8', 256))
        for threads in (1, 2, 8):
            args = argument_parser().parse_args(['--strategy', 'performance-bounded',
                                                '--output', 'unused', '--threads', str(threads)])
            self.assertEqual(args.threads, threads)

    def test_route_probe_thread_profile_is_explicit(self):
        prefix = Path(__file__).with_name('test_native_route_first.tcl').read_text().split('set synth_directive')[0]
        cases = (('unused', 1, 4), ('unused routability-route-first', 1, 4),
                 ('unused routability-retime-route-first', 1, 4),
                 ('unused performance-retime-routability-route-first', 1, 4),
                 ('unused routability-retime-route-first parallel8', 8, 8),
                 ('unused performance-retime-routability-route-first parallel8', 8, 8),
                 ('unused performance-retime-muxf-route-first', 1, 4),
                 ('unused performance-retime-muxf-route-first parallel8', 8, 8),
                 ('unused performance-retime-muxf-timing-route-first', 1, 4),
                 ('unused performance-retime-muxf-timing-route-first parallel8', 8, 8),
                 ('unused routability-retime-remap-route-first', 1, 4),
                 ('unused routability-retime-remap-route-first parallel8', 8, 8),
                 ('unused routability-route-first parallel8', 8, 8),
                 ('unused performance-route-first parallel8', 8, 8),
                 ('unused unknown parallel8', None, None),
                 ('unused routability-route-first 8', None, None),
                 ('unused routability-route-first parallel8 extra', None, None))
        for args, synth, apr in cases:
            with self.subTest(args=args), tempfile.TemporaryDirectory(prefix='parallel8-probe-args-') as td:
                code = f'set argv [list {args}]\nset argc [llength $argv]\n'+prefix
                if synth is not None:
                    code += f'\nif {{$synth_threads != {synth} || $apr_threads != {apr}}} {{error "thread drift"}}\n'
                    retiming = 'on' if 'routability-retime-' in args or 'performance-retime-routability-route-first' in args or 'performance-retime-muxf-' in args else 'off'
                    code += f'if {{$synth_retiming ne "{retiming}"}} {{error "retiming drift"}}\n'
                p = Path(td)/'check.tcl'; p.write_text(code)
                result = subprocess.run(['tclsh', str(p)], text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, synth is not None, result.stdout+result.stderr)

    def test_parallel8_is_explicit_uncapped_one_job_profile(self):
        self.assertEqual(task_policy(8, 8), ('parallel8', 256))
        limits = dict(MemoryMax='infinity', MemorySwapMax='infinity', TasksMax='256')
        for strategy in ('performance-route-first', 'routability-route-first',
                         'routability-retime-route-first', 'performance-retime-routability-route-first', 'performance-retime-muxf-route-first', 'performance-retime-muxf-timing-route-first', 'performance-retime-muxf-explore-route-first', 'performance-retime-muxf-aggressive-remap-route-first', 'performance-retime-bounded', 'routability-spread'):
            self.assertEqual(implementation_policy(strategy, 8, 'unbounded'), 8)
        self.assertEqual(check_scope_limits(limits, 256, 'unbounded',
                                          threads=8, implementation_threads=8), limits)
        for profile in ('standard16', 'serial20'):
            with self.assertRaises(ValueError): memory_policy(profile, 8)
        for threads, impl in ((8, 1), (8, 4), (1, 8), (2, 8), (8.0, 8), (8, '8')):
            with self.assertRaises(ValueError): task_policy(threads, impl)
        for maximum in (48, 128, 257, True):
            with self.assertRaises(ValueError):
                check_scope_limits(limits, maximum, 'unbounded', threads=8, implementation_threads=8)
        with self.assertRaises(ValueError): check_scope_limits(limits, 256, 'unbounded')
        source = Path(__file__).with_name('run_fresh_strategy.py').read_text()
        self.assertIn("VEN_FPGA_JOBS='1'", source)
        self.assertIn("choices=(1, 2, 8), default=8", source)

    def test_migrated_scratch_accepts_same_device_but_never_a_fallback(self):
        with tempfile.TemporaryDirectory(prefix='fresh-scratch-test-') as td:
            root = Path(td).resolve()
            scratch = root/'scratch'
            scratch.mkdir()
            self.assertEqual(validate_output(scratch/'new-run', scratch), scratch/'new-run')
            for invalid in (scratch, root/'outside', scratch/'missing'/'run'):
                with self.assertRaises(ValueError): validate_output(invalid, scratch)
            existing = scratch/'existing'
            existing.mkdir()
            with self.assertRaises(ValueError): validate_output(existing, scratch)
            (scratch/'escape').symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError): validate_output(scratch/'escape'/'run', scratch)

    def test_route_probe_requires_native_route_completion(self):
        script = Path(__file__).with_name('test_native_route_first.tcl').read_text()
        prefix = script.split('# Source-only tooling probe')[0]
        for case in ('ok', 'next-step', 'running', 'missing-end', 'error-marker', 'error-log', 'missing-success'):
            with self.subTest(case=case), tempfile.TemporaryDirectory(prefix='route-first-status-') as td:
                root = Path(td)
                for name in ('.vivado.end.rst', '.route_design.end.rst'): (root/name).touch()
                status = 'Not started write_bitstream' if case == 'next-step' else 'route_design Complete!'
                log = 'route_design completed successfully\n'
                if case == 'running': status = 'route_design Running'
                if case == 'missing-end': (root/'.route_design.end.rst').unlink()
                if case == 'error-marker': (root/'.place_design.error.rst').touch()
                if case == 'error-log': log += 'ERROR: native error\n'
                if case == 'missing-success': log = 'route_design started\n'
                (root/'runme.log').write_text(log)
                check = root/'test.tcl'
                check.write_text(prefix+f'\nroute_first_check_status impl_1 {{{status}}} {{{root}}}\n')
                result = subprocess.run(['tclsh', str(check)], text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, case in ('ok', 'next-step'), result.stdout+result.stderr)

    def test_tcl_rejects_unreviewed_stage_thread_pairs_before_creating_project(self):
        prefix = Path(__file__).with_name('fresh_strategy.tcl').read_text().split('if {[version -short]')[0]
        for strategy, synth, impl in (('performance-route-first', '1', '1'),
                ('performance-route-first', '2', '4'), ('performance-route-first', 'true', '4'),
                ('performance-route-first', '1', '4.0'), ('performance-bounded', '1', '4'),
                ('performance-bounded', '2', '8'), ('routability-route-first', '2', '4'),
                ('routability-route-first', '1', '1'), ('routability-route-first', '8', '4'),
                ('routability-retime-route-first', '2', '2'), ('routability-retime-route-first', '8', '4'),
                ('performance-retime-routability-route-first', '2', '2'), ('performance-retime-routability-route-first', '8', '4'),
                ('routability-retime-route-first', '1', '1'),
                ('performance-retime-routability-route-first', '1', '1'),
                ('performance-retime-muxf-timing-route-first', '1', '1'),
                ('performance-retime-muxf-timing-route-first', '2', '4'),
                ('performance-retime-muxf-timing-route-first', '8', '4'),
                ('performance-retime-muxf-explore-route-first', '1', '1'),
                ('performance-retime-muxf-explore-route-first', '2', '4'),
                ('performance-retime-muxf-explore-route-first', '8', '4'),
                ('performance-retime-muxf-aggressive-remap-route-first', '1', '1'),
                ('performance-retime-muxf-aggressive-remap-route-first', '2', '4'),
                ('performance-retime-muxf-aggressive-remap-route-first', '8', '4'),
                ('routability-retime-remap-route-first', '2', '4'),
                ('routability-retime-remap-route-first', '1', '1'),
                ('routability-retime-remap-route-first', '8', '4'),
                ('performance-bounded', '8', '2'), ('performance-route-first', '8.0', '8')):
            with self.subTest(strategy=strategy, synth=synth, impl=impl):
                code = f'set argc 5\nset argv [list {strategy} unused unused {synth} {impl}]\n'+prefix
                # A file script is needed: tclsh stdin can continue after errors.
                with tempfile.TemporaryDirectory(prefix='route-first-args-') as td:
                    p = Path(td)/'test.tcl'; p.write_text(code)
                    result = subprocess.run(['tclsh', str(p)], text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_route_first_stage_threads_keep_fixed_memory_and_tasks(self):
        self.assertEqual(implementation_policy('performance-route-first', 1, 'serial20'), 4)
        self.assertEqual(task_policy(1, 4), ('serial_apr4', 128))
        limits = dict(MemoryMax=str(20*GIB), MemorySwapMax=str(6*GIB), TasksMax='128')
        self.assertEqual(check_scope_limits(limits, 128, 'serial20', threads=1, implementation_threads=4), limits)
        for threads, impl in ((1, True), (True, 4), (1, '4'), (1, 4.0), (2, 4), (4, 4), (1, 2), (1, 8)):
            with self.assertRaises(ValueError): task_policy(threads, impl)
        for threads, memory in ((1, 'standard16'), (2, 'standard16'), (2, 'serial20'), (True, 'serial20')):
            with self.assertRaises(ValueError): implementation_policy('performance-route-first', threads, memory)
        for cap in (48, True, 256):
            with self.assertRaises(ValueError):
                check_scope_limits(limits, cap, 'serial20', threads=1, implementation_threads=4)
        for key in limits:
            with self.assertRaises(ValueError):
                check_scope_limits({**limits, key:'max'}, 128, 'serial20', threads=1, implementation_threads=4)

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
        for name, threads in (('serial20', 2), ('unknown', 1), (None, 1), (True, 1), ('serial20', True)):
            with self.assertRaises(ValueError): memory_policy(name, threads)
        with self.assertRaises(ValueError): check_scope_limits({}, 128, 'serial20')

    def test_uncapped_memory_preserves_disk_oom_and_task_checks(self):
        self.assertEqual(memory_policy('unbounded', 1), (None, None))
        self.assertEqual(memory_policy('unbounded', 2), (None, None))
        self.assertEqual(implementation_policy('performance-route-first', 1, 'unbounded'), 4)
        self.assertEqual(implementation_policy('routability-route-first', 1, 'unbounded'), 4)
        with self.assertRaises(ValueError): implementation_policy('routability-route-first', 2, 'unbounded')
        self.assertEqual(implementation_policy('routability-retime-route-first', 1, 'unbounded'), 4)
        self.assertEqual(implementation_policy('performance-retime-routability-route-first', 1, 'unbounded'), 4)
        with self.assertRaises(ValueError): implementation_policy('routability-retime-route-first', 2, 'unbounded')
        with self.assertRaises(ValueError): implementation_policy('performance-retime-routability-route-first', 2, 'unbounded')
        limits = dict(MemoryMax='infinity', MemorySwapMax='infinity', TasksMax='128')
        self.assertEqual(check_scope_limits(limits, 128, 'unbounded', threads=1,
                                          implementation_threads=4), limits)
        for key in ('MemoryMax', 'MemorySwapMax', 'TasksMax'):
            for value in ('max', '0', str(20*GIB)):
                with self.assertRaises(ValueError):
                    check_scope_limits({**limits, key:value}, 128, 'unbounded', threads=1,
                                       implementation_threads=4)
        args = dict(ram=100*GIB, swap=200*GIB, resources=dict(MemAvailable=0, SwapFree=0),
                    free=4*GIB, events=dict(oom='0', oom_kill='0'), limit_hit=False,
                    ram_gib=None, swap_gib=None)
        self.assertIsNone(resource_stop(**args))
        for delta, reason in (({'free':4*GIB-1}, '4 GiB disk reserve'),
                              ({'events':dict(oom='1', oom_kill='0')}, 'scope OOM'),
                              ({'events':dict(oom='0', oom_kill='1')}, 'scope OOM'),
                              ({'limit_hit':True}, 'scope task limit')):
            self.assertEqual(resource_stop(**{**args, **delta}), reason)
        with self.assertRaises(ValueError): resource_stop(**{**args, 'swap_gib':6})

    def test_new_launch_cli_only_accepts_uncapped_policy(self):
        proc = subprocess.run(['python3', str(Path(__file__).with_name('run_fresh_strategy.py')),
                               '--help'], text=True, capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('--memory-profile {unbounded}', proc.stdout)
        source = Path(__file__).with_name('run_fresh_strategy.py').read_text()
        self.assertIn("default='unbounded'", source)
        self.assertNotIn("assert host()['MemAvailable']", source)

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
        cases = [(s, t, t) for s, t in itertools.product(strategies, (1, 2, 8))]
        cases.append((('performance-route-first', 'PerformanceOptimized', 'AltSpreadLogic_medium', 'NoTimingRelaxation'), 1, 4))
        cases.append((('routability-route-first', 'AlternateRoutability', 'AltSpreadLogic_high', 'AlternateCLBRouting'), 1, 4))
        cases.append((('performance-route-first', 'PerformanceOptimized', 'AltSpreadLogic_medium', 'NoTimingRelaxation'), 8, 8))
        cases.append((('routability-route-first', 'AlternateRoutability', 'AltSpreadLogic_high', 'AlternateCLBRouting'), 8, 8))
        for synth, apr in ((1, 4), (8, 8)):
            cases.append((('routability-retime-route-first', 'AlternateRoutability', 'AltSpreadLogic_high', 'AlternateCLBRouting'), synth, apr))
            cases.append((('performance-retime-routability-route-first', 'PerformanceOptimized', 'AltSpreadLogic_high', 'AlternateCLBRouting'), synth, apr))
            cases.append((('performance-retime-muxf-route-first', 'PerformanceOptimized', 'AltSpreadLogic_high', 'AlternateCLBRouting'), synth, apr))
            cases.append((('performance-retime-muxf-timing-route-first', 'PerformanceOptimized', 'ExtraTimingOpt', 'AlternateCLBRouting'), synth, apr))
            cases.append((('performance-retime-muxf-explore-route-first', 'PerformanceOptimized', 'AltSpreadLogic_high', 'Explore'), synth, apr))
            cases.append((('performance-retime-muxf-aggressive-remap-route-first', 'PerformanceOptimized', 'AltSpreadLogic_high', 'AlternateCLBRouting'), synth, apr))
            cases.append((('routability-retime-remap-route-first', 'AlternateRoutability', 'AltSpreadLogic_high', 'AlternateCLBRouting'), synth, apr))
        for (strategy, directive, place, route), threads, impl_threads in cases:
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
foreach {{run expected_threads}} {{synth_1 {threads} impl_1 {impl_threads}}} {{
 if {{$::native_threads($run) != $expected_threads}} {{error "native thread setting lost"}}
}}
if {{!$::evidence_called}} {{error "evidence procedure not called"}}
foreach {{obj prop expected}} {{
 synth_1 STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE {directive}
 synth_1 STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING {'on' if strategy in ('performance-retime-bounded', 'routability-retime-route-first', 'performance-retime-routability-route-first', 'performance-retime-muxf-route-first', 'performance-retime-muxf-timing-route-first', 'performance-retime-muxf-explore-route-first', 'performance-retime-muxf-aggressive-remap-route-first', 'routability-retime-remap-route-first') else 'off' if strategy in ('performance-bounded', 'performance-route-first', 'routability-route-first') else 'auto'}
 synth_1 AUTO_INCREMENTAL_CHECKPOINT 0
 impl_1 INCREMENTAL_CHECKPOINT {{}}
 impl_1 STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized
 impl_1 {{STEPS.OPT_DESIGN.ARGS.MORE OPTIONS}} {{}}
 impl_1 STEPS.PLACE_DESIGN.ARGS.DIRECTIVE {place}
 impl_1 STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE {route}
}} {{
 if {{[get_property $prop $obj] ne $expected}} {{error "readback mismatch $prop"}}
}}
if {{![catch {{launch_runs impl_1 -jobs 1}}]}} {{error "duplicate launch allowed"}}
if {{[get_property STEPS.SYNTH_DESIGN.TCL.POST synth_1] ne ""}} {{error "native post hook retained"}}
puts FRESH-TCL-OK
'''
                if threads == 8:
                    checks += '''
foreach {obj step} {synth_1 SYNTH_DESIGN impl_1 OPT_DESIGN} {
 if {[get_property STEPS.${step}.TCL.PRE $obj] ne [file join $::fresh_script_dir fresh_threads8_pre.tcl]} {
  error "native thread readback hook missing"
 }
}
'''
                if strategy in ('performance-retime-bounded', 'performance-bounded'):
                    checks += '''
if {[get_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE impl_1] ne "Default"} {error "directive retained"}
if {[get_property {STEPS.PHYS_OPT_DESIGN.ARGS.MORE OPTIONS} impl_1] ne "-fanout_opt -placement_opt -restruct_opt -equ_drivers_opt"} {error "pre-route operations differ"}
if {[get_property {STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.MORE OPTIONS} impl_1] ne "-placement_opt -routing_opt -restruct_opt -hold_fix"} {error "post-route operations differ"}
'''
                if strategy in ('performance-route-first', 'routability-route-first', 'routability-retime-route-first', 'performance-retime-routability-route-first', 'performance-retime-muxf-route-first', 'performance-retime-muxf-timing-route-first', 'performance-retime-muxf-explore-route-first', 'performance-retime-muxf-aggressive-remap-route-first', 'routability-retime-remap-route-first'):
                    checks += '''
foreach step {PHYS_OPT_DESIGN POST_ROUTE_PHYS_OPT_DESIGN} {
 if {[get_property STEPS.${step}.IS_ENABLED impl_1] ni {0 false}} {error "phys still enabled"}
 if {[get_property STEPS.${step}.ARGS.DIRECTIVE impl_1] ne "Default"} {error "phys directive retained"}
 if {[get_property "STEPS.${step}.ARGS.MORE OPTIONS" impl_1] ne ""} {error "phys options retained"}
}
'''
                if strategy == 'routability-retime-remap-route-first':
                    checks += '''
if {[get_property STEPS.OPT_DESIGN.TCL.POST impl_1] ne [file join $::fresh_script_dir fresh_opt_remap_post.tcl]} {
 error "remap hook absent"
}
'''
                elif strategy in ('performance-retime-muxf-route-first', 'performance-retime-muxf-timing-route-first', 'performance-retime-muxf-explore-route-first'):
                    checks += '\nif {[get_property STEPS.OPT_DESIGN.TCL.POST impl_1] ne [file join $::fresh_script_dir fresh_opt_muxf_post.tcl]} {error "muxf hook absent"}\n'
                elif strategy == 'performance-retime-muxf-aggressive-remap-route-first':
                    checks += '\nif {[get_property STEPS.OPT_DESIGN.TCL.POST impl_1] ne [file join $::fresh_script_dir fresh_opt_muxf_aggressive_post.tcl]} {error "aggressive hook absent"}\n'
                else:
                    checks += '\nif {[get_property STEPS.OPT_DESIGN.TCL.POST impl_1] ne ""} {error "unexpected opt post hook"}\n'
                runner = Path(td)/'test.tcl'
                route_first = strategy in ('performance-route-first', 'routability-route-first', 'routability-retime-route-first', 'performance-retime-routability-route-first', 'performance-retime-muxf-route-first', 'performance-retime-muxf-timing-route-first', 'performance-retime-muxf-explore-route-first', 'performance-retime-muxf-aggressive-remap-route-first', 'routability-retime-remap-route-first')
                stage_args = f'{threads} {impl_threads}' if route_first else str(threads)
                argc = 5 if route_first else 4
                runner.write_text(mock+f'\nset argc {argc}\nset argv [list {strategy} {{{td}/source}} {{{td}/build}} {stage_args}]\n'+prefix+checks)
                result = subprocess.run(['tclsh', str(runner)], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('FRESH-TCL-OK', result.stdout)


if __name__ == '__main__': unittest.main()
