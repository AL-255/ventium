import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from audit_fresh_result import (timing_summary, timing_coverage, route_and_drc, bus_skew,
    audit_closed, audit_input_pins, audit_task_monitoring, sha,
    CLOCK_ROLE_AMENDMENT, AMENDED_OWNER, AMENDED_SCOPE)
from test_audit_fresh_strategy import SCRIPT, PROPS

PASS = '''| Design Timing Summary
0.150 0.000 0 200000 0.004 0.000 0 200000 2.000 0.000 0 60000
All user specified timing constraints are met.
| Clock Summary
'''
NAMES = ('no_clock', 'constant_clock', 'pulse_width_clock', 'unconstrained_internal_endpoints',
         'no_input_delay', 'no_output_delay', 'multiple_clock', 'generated_clocks', 'loops',
         'partial_input_delay', 'partial_output_delay', 'latch_loops')
COVERAGE = '\n'.join(f'{i}. checking {n} ({4 if n == "no_output_delay" else 0})' for i,n in enumerate(NAMES,1))+'\n'
COVERAGE = COVERAGE+COVERAGE+'\nled[0]\nled[1]\nled[2]\nled[3]\n'
ROUTE = '# of routable nets.... : 180000 :\n# of fully routed nets.... : 180000 :\n# of nets with routing errors.... : 0 :\n'
DRC = 'Design State : Fully Routed\n| Warning |\n'


class ResultTests(unittest.TestCase):
    def test_named_memory_profiles_require_admission_and_runtime_evidence(self):
        gib = 1024**3
        for name, ram in (('standard16', 16), ('serial20', 20)):
            with self.subTest(profile=name), tempfile.TemporaryDirectory(prefix='fresh-memory-audit-') as td:
                run = Path(td)
                with self.assertRaises(ValueError):
                    audit_task_monitoring(run, {}, {'memory_profile':name})
                limits = dict(MemoryMax=str(ram*gib), MemorySwapMax=str(6*gib), TasksMax='48')
                started = dict(memory_profile=name, memory_max=ram*gib, swap_max=6*gib,
                    combined_limit=(ram+5)*gib, tool_threads=1, task_monitoring=True,
                    task_profile='serial', tasks_max=48,
                    host=dict(MemAvailable=(ram+3)*gib, SwapFree=11*gib),
                    env=dict(VENTIUM_VIVADO_TASK_PROFILE='serial',
                        VENTIUM_VIVADO_MEMORY_MAX=f'{ram}G', VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'))
                closed = dict(memory_profile=name, task_profile='serial', tasks_max=48,
                    owner=limits, peak_tasks_sampled=27, task_limit_events=0)
                sample = dict(memory=ram*gib, swap=5*gib, disk_free=4*gib,
                    host=dict(MemAvailable=2*gib, SwapFree=2*gib), events=dict(oom='0', oom_kill='0'),
                    reason=None, tasks=27, task_events={'max':0}, limits=limits)
                def write(row): (run/'watch.jsonl').write_text(json.dumps(row)+'\n')
                write(sample)
                self.assertEqual(audit_task_monitoring(run, started, closed)['memory_profile'], name)
                for key, value in (('memory_profile', 'unlimited'), ('memory_max', 21*gib),
                                   ('swap_max', 8*gib), ('combined_limit', (ram+6)*gib),
                                   ('memory_max', True), ('tool_threads', 2),
                                   ('host', {**started['host'], 'MemAvailable':(ram+2)*gib}),
                                   ('host', {**started['host'], 'SwapFree':10*gib}),
                                   ('env', {**started['env'], 'VENTIUM_VIVADO_MEMORY_MAX':'max'})):
                    with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                        audit_task_monitoring(run, {**started, key:value}, closed)
                for bad_closed in ({**closed, 'memory_profile':'unlimited'},
                                   {k:v for k,v in closed.items() if k != 'memory_profile'},
                                   {**closed, 'owner':{**limits, 'MemoryMax':'max'}}):
                    with self.assertRaises(ValueError): audit_task_monitoring(run, started, bad_closed)
                for key, value in (('memory', True), ('swap', 5*gib+1), ('disk_free', 4*gib-1),
                                   ('host', {'MemAvailable':2*gib-1, 'SwapFree':2*gib}),
                                   ('host', {'MemAvailable':2*gib, 'SwapFree':2*gib-1}),
                                   ('events', {'oom':'1', 'oom_kill':'0'}),
                                   ('events', {'oom':'0', 'oom_kill':'1'}),
                                   ('reason', 'combined memory early stop')):
                    write({**sample, key:value})
                    with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                        audit_task_monitoring(run, started, closed)
                for absent in ('memory', 'swap', 'reason', 'events', 'host', 'disk_free'):
                    write({k:v for k,v in sample.items() if k != absent})
                    with self.assertRaises(ValueError): audit_task_monitoring(run, started, closed)

    def test_task_monitoring_requires_consistent_independent_evidence(self):
        with tempfile.TemporaryDirectory(prefix='fresh-task-audit-') as td:
            run = Path(td)
            self.assertIsNone(audit_task_monitoring(run, {}, {}))
            for threads, profile, maximum in ((1, 'serial', 48), (2, 'parallel2', 128)):
                limits = dict(MemoryMax=str(16*1024**3), MemorySwapMax=str(6*1024**3), TasksMax=str(maximum))
                started = dict(tool_threads=threads, task_monitoring=True, task_profile=profile,
                    tasks_max=maximum, env={'VENTIUM_VIVADO_TASK_PROFILE':profile})
                closed = dict(task_profile=profile, tasks_max=maximum, owner=limits,
                    peak_tasks_sampled=maximum, task_limit_events=0)
                # A final empty-scope sample can race normal process exit.
                rows = [dict(tasks=n, task_events={'max':0}, limits=limits) for n in (20, maximum, 0)]
                watch = run/'watch.jsonl'
                watch.write_text('\n'.join(json.dumps(r) for r in rows)+'\n')
                self.assertEqual(audit_task_monitoring(run, started, closed)['sampled_peak'], maximum)
                for key, value in (('task_monitoring', False), ('tasks_max', True),
                                   ('task_profile', 'unlimited'), ('tool_threads', True)):
                    with self.assertRaises(ValueError):
                        audit_task_monitoring(run, {**started, key:value}, closed)
                for key, value in (('peak_tasks_sampled', maximum-1), ('task_limit_events', 1),
                                   ('task_limit_events', False), ('owner', {**limits, 'TasksMax':'max'})):
                    with self.assertRaises(ValueError):
                        audit_task_monitoring(run, started, {**closed, key:value})
                for bad in ([], [dict(tasks=maximum+1, task_events={'max':0}, limits=limits)],
                            [dict(tasks=0, task_events={'max':0}, limits=limits)],
                            [dict(tasks=20, task_events={'max':3}, limits=limits)],
                            [dict(tasks=True, task_events={'max':0}, limits=limits)],
                            [dict(tasks=20, task_events={}, limits=limits)],
                            [dict(tasks=20, task_events={'max':False}, limits=limits)],
                            [dict(tasks=20, task_events={'max':0}, limits={**limits, 'MemoryMax':'max'})]):
                    watch.write_text('\n'.join(json.dumps(r) for r in bad))
                    with self.assertRaises(ValueError): audit_task_monitoring(run, started, closed)

    def test_all_three_timing_checks_required(self):
        self.assertTrue(timing_summary(PASS)['all_numeric_timing_met'])
        for old, new in [('0.150', '-0.150'), ('0.004', '-0.004'), ('2.000', '-2.000')]:
            text = PASS.replace(old, new).replace('All user specified timing constraints are met.', 'Timing constraints are not met.')
            self.assertFalse(timing_summary(text)['all_numeric_timing_met'])
            with self.assertRaises(ValueError): timing_summary(PASS.replace(old, new))

    def test_nonfinite_truncated_and_empty_timing_rejected(self):
        for text in ('', PASS+PASS, PASS.replace('0.150', 'nan'), PASS.replace('200000', '0'),
                     PASS.replace('0 60000', '0')):
            with self.assertRaises(ValueError): timing_summary(text)

    def test_unconstrained_core_not_allowed(self):
        self.assertEqual(timing_coverage(COVERAGE)['no_output_delay'], 4)
        for text in (COVERAGE.replace('no_clock (0)', 'no_clock (1)'),
                     COVERAGE.replace('unconstrained_internal_endpoints (0)', 'unconstrained_internal_endpoints (1)'),
                     COVERAGE.replace('led[3]', 'cpu_data[0]'),
                     '\n'.join(COVERAGE.splitlines()[:12]),
                     COVERAGE.replace('latch_loops (0)', 'latch_loops (1)', 1)):
            with self.assertRaises(ValueError): timing_coverage(text)

    def test_routes_not_required_to_match_prior_net_count(self):
        # Different synthesis strategies may compact the netlist below 200k.
        self.assertEqual(route_and_drc(ROUTE, DRC)['fully routed nets'], 180000)
        for route, drc in ((ROUTE.replace('fully routed nets.... : 180000', 'fully routed nets.... : 179999'), DRC),
                           (ROUTE.replace('errors.... : 0', 'errors.... : 1'), DRC),
                           (ROUTE, DRC+'| Critical Warning |\n')):
            with self.assertRaises(ValueError): route_and_drc(route, drc)

    def test_bus_skew_constraints_must_all_remain(self):
        text = 'Slack (MET) : 9.000ns (requirement - actual skew)\n'*10
        self.assertTrue(bus_skew(text)['met'])
        negative = text.replace('Slack (MET) : 9.000ns', 'Slack (VIOLATED) : -0.001ns', 1)
        self.assertFalse(bus_skew(negative)['met'])
        for bad in (text.splitlines()[0], text.replace('9.000', 'nan'), text.replace('9.000', '-0.001')):
            with self.assertRaises(ValueError): bus_skew(bad)

    def test_known_parser_exception_does_not_hide_native_or_input_failures(self):
        with tempfile.TemporaryDirectory(prefix='fresh-result-test-') as td:
            run = Path(td); build = run/'build'; build.mkdir()
            source = run/'source.sv'; source.write_text('module a; endmodule\n')
            (run/'prepared.json').write_text('{}')
            started = dict(fresh_synthesis=True, prior_checkpoint_inputs=[], pins={str(source):sha(source)},
                           strategy='performance-netdelay', implementation_limit_seconds=13800)
            (run/'started.json').write_text(json.dumps(started))
            (run/'native.log').write_text('FRESH-STRATEGY-COMPLETE performance-netdelay\n')
            (build/'stages.tsv').write_text('synth_1\t100\nimpl_1\t200\nroute_design\t300\ncomplete\t400\n')
            script = build/'rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.tcl'
            script.parent.mkdir(parents=True); script.write_text(SCRIPT)
            (build/'synth_1-properties.rpt').write_text(PROPS)
            (build/'impl_1-properties.rpt').write_text('AUTO_INCREMENTAL_CHECKPOINT bool false 0\nINCREMENTAL_CHECKPOINT file false\n')
            required = ('fresh-routed.dcp', 'rk_ao486_system.bit.bin', 'timing-summary.rpt',
                        'timing.tsv', 'check-timing.rpt', 'route-status.rpt', 'drc.rpt',
                        'bus-skew.rpt', 'cdc.rpt', 'exceptions.rpt')
            for name in required: (build/name).write_text('fixture only, never a native result\n')
            closed = dict(native_exit=0, reason=None, inputs_unchanged=True,
                          failure="audit: ValueError('flatten policy drift')", elapsed=350,
                          products={name:sha(build/name) for name in required})
            (run/'closed.json').write_text(json.dumps(closed))
            # Only parser/receipt control flow is under test. Numeric reports
            # are tested independently above; do not treat these as FPGA data.
            with patch('audit_fresh_result.final_reports', return_value={}):
                self.assertTrue(audit_closed(run)['native_completion_verified'])
                # New explicit-thread receipts must agree with BOTH native
                # worker scripts; missing or mismatched implementation fails.
                impl_script = build/'rk_ao486_system/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper.tcl'
                impl_script.parent.mkdir(parents=True)
                for threads in (1, 2):
                    (run/'started.json').write_text(json.dumps({**started, 'tool_threads':threads}))
                    script.write_text(SCRIPT.replace('maxThreads 1', f'maxThreads {threads}'))
                    impl_script.write_text(f'set_param general.maxThreads {threads}\n')
                    self.assertEqual(audit_closed(run)['native_synthesis_configuration']['configured_threads'], threads)
                    impl_script.write_text('set_param general.maxThreads 8\n')
                    with self.assertRaises(ValueError): audit_closed(run)
                    impl_script.unlink()
                    with self.assertRaises(FileNotFoundError): audit_closed(run)
                script.write_text(SCRIPT)
                (run/'started.json').write_text(json.dumps(started))
                # The new bounded strategy also requires the exact native
                # operation set; a successful receipt alone cannot qualify it.
                bounded = {**started, 'strategy':'performance-retime-bounded', 'tool_threads':1}
                (run/'started.json').write_text(json.dumps(bounded))
                (run/'native.log').write_text('FRESH-STRATEGY-COMPLETE performance-retime-bounded\n')
                script.write_text(SCRIPT.rstrip()+' -global_retiming on\n')
                (build/'synth_1-properties.rpt').write_text(PROPS.replace('enum false auto', 'enum false on'))
                impl_script.write_text('set_param general.maxThreads 1\n')
                with self.assertRaisesRegex(ValueError, 'implementation command mismatch'):
                    audit_closed(run)
                script.write_text(SCRIPT)
                (build/'synth_1-properties.rpt').write_text(PROPS)
                (run/'started.json').write_text(json.dumps(started))
                (run/'native.log').write_text('FRESH-STRATEGY-COMPLETE performance-netdelay\n')
                for key, value in (('native_exit', 1), ('reason', 'scope OOM'),
                                   ('inputs_unchanged', False), ('failure', 'audit: other failure')):
                    (run/'closed.json').write_text(json.dumps({**closed, key:value}))
                    with self.subTest(key=key), self.assertRaises(ValueError): audit_closed(run)
                (run/'closed.json').write_text(json.dumps(closed))
                (build/'stages.tsv').write_text('synth_1\t100\nimpl_1\t200\nroute_design\t300\ncomplete\t14000\n')
                with self.assertRaises(ValueError): audit_closed(run)
                (build/'stages.tsv').write_text('synth_1\t100\nimpl_1\t200\nroute_design\t300\ncomplete\t400\n')
                source.write_text('changed source\n')
                with self.assertRaises(ValueError): audit_closed(run)

    def test_only_exact_reviewed_clock_reporting_delta_is_allowed(self):
        with tempfile.TemporaryDirectory(prefix='report-amendment-test-') as td:
            run = Path(td)
            started = dict(invocation=AMENDED_OWNER,
                           pins={p:v['before'] for p,v in CLOCK_ROLE_AMENDMENT.items()})
            receipt = dict(files=CLOCK_ROLE_AMENDMENT, owner_invocation=AMENDED_OWNER,
                           scope_invocation=AMENDED_SCOPE, rtl_changed=False, constraints_changed=False,
                           synthesis_or_apr_options_changed=False, checkpoint_input_added=False, restart=False)
            (run/'report-hook-amendment.json').write_text(json.dumps(receipt))
            hashes = {p:v['after'] for p,v in CLOCK_ROLE_AMENDMENT.items()}
            def fake_sha(path):
                return hashes.get(str(path), 'receipt-digest')
            with patch('audit_fresh_result.sha', side_effect=fake_sha):
                result = audit_input_pins(run, started)
                self.assertFalse(result['all_launch_inputs_unchanged'])
                self.assertTrue(result['all_nonreport_inputs_unchanged'])
                with self.assertRaises(ValueError): audit_input_pins(run, {**started, 'invocation':'other-run'})
                started['pins']['/unexpected/core.sv'] = 'old-source'
                hashes['/unexpected/core.sv'] = 'modified-source'
                with self.assertRaises(ValueError): audit_input_pins(run, started)
                del started['pins']['/unexpected/core.sv']
                key = next(iter(CLOCK_ROLE_AMENDMENT))
                hashes[key] = 'unreviewed-report-change'
                with self.assertRaises(ValueError): audit_input_pins(run, started)
                hashes[key] = CLOCK_ROLE_AMENDMENT[key]['after']
                receipt['constraints_changed'] = True
                (run/'report-hook-amendment.json').write_text(json.dumps(receipt))
                with self.assertRaises(ValueError): audit_input_pins(run, started)


if __name__ == '__main__': unittest.main()
