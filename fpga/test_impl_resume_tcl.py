#!/usr/bin/env python3
"""Fast real-tclsh regression; every Vivado operation is a harmless stub.

Run directly, optionally with --receipt /fresh/scratch/result.json. No Vivado,
project, synthesis, implementation, bitstream, or board operation is performed.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

if not __debug__:
    raise RuntimeError('Run without -O/PYTHONOPTIMIZE; this gate requires assertions')

TARGET = Path(__file__).resolve().with_name('launch_impl_existing.tcl')
TCLSH = shutil.which('tclsh')
BASE = {
    'clocks': {'clk_pl_0': ['pl'], 'mmcm_clk': ['core']},
    'periods': {'pl': '10.000', 'core': '25.000'},
    'progress': {'synth_1': '100%', 'impl_1': '100%'},
    'setup': ['setup_path'], 'hold': ['hold_path'],
    'slacks': {'setup_path': '0.104', 'hold_path': '0.012'},
    'target': None,
    'opt_directive': None,
    'status': {'synth_1': 'synth_design Complete!', 'impl_1': 'Not started'},
    'refresh': {'synth_1': 'false', 'impl_1': 'false'},
    'opt_help': 'RuntimeOptimized - Runs Default without bram_power_opt',
    'wait_success': False,
    'wait_status': 'write_bitstream Complete!',
    'ignore_opt_setter': False,
    'impl_clocks': None,
    'impl_periods': None,
}
RECEIPTS = []

def quote(value):
    value = str(value)
    if any(c in value for c in '{}\\\n\r'):
        raise ValueError('unsupported test literal')
    return '{' + value + '}'

def tdict(values, list_values=False):
    return '[dict create ' + ' '.join(quote(k) + ' ' + quote(
        ' '.join(v) if list_values else v) for k, v in values.items()) + ']'

STUBS = r'''
set argc 1
set argv [list /stub-only/frozen-project.xpr]
proc record {name args} { puts "STUB-CALL $name $args" }
proc open_project {args} { record open_project {*}$args }
proc set_param {args} {
    if {$args ne {general.maxThreads 1}} { error "unexpected threading change" }
    record set_param {*}$args
}
proc get_runs {name} { return $name }
proc get_property {name object} {
    switch -- $name {
        PROGRESS { return [dict get $::progress $object] }
        STATUS { return [dict get $::status $object] }
        NEEDS_REFRESH { return [dict get $::refresh $object] }
        STEPS.OPT_DESIGN.ARGS.DIRECTIVE { return $::actual_opt_directive }
        DIRECTORY { return /stub-only/no-output-written }
        PERIOD { return [dict get $::periods $object] }
        SLACK { return [dict get $::slacks $object] }
        default { error "unexpected property $name" }
    }
}
proc help {name} {
    if {$name ne "opt_design"} { error "unexpected help query" }
    return $::opt_help
}
proc set_property {name value object} {
    if {$name ne "STEPS.OPT_DESIGN.ARGS.DIRECTIVE" || $value ne "RuntimeOptimized" || $object ne "impl_1"} {
        error "unexpected implementation setting change"
    }
    if {!$::ignore_opt_setter} { set ::actual_opt_directive $value }
    record set_property $name $value $object
}
proc launch_runs {args} {
    if {$args ne {impl_1 -to_step write_bitstream -jobs 1}} {
        error "unexpected launch or synthesis regeneration: $args"
    }
    record launch_runs {*}$args
}
proc wait_on_run {name} {
    record wait_on_run $name
    if {$::wait_success} {
        dict set ::progress impl_1 {100%}
        dict set ::status impl_1 $::wait_status
    }
}
proc open_run {name} {
    record open_run $name
    if {$name eq "impl_1"} {
        if {$::impl_clocks ne "inherit"} { set ::clocks $::impl_clocks }
        if {$::impl_periods ne "inherit"} { set ::periods $::impl_periods }
    }
}
proc close_design {} { record close_design }
proc report_utilization {args} { record report_utilization {*}$args }
proc report_timing_summary {args} { record report_timing_summary {*}$args }
proc get_clocks {args} {
    set name [lindex $args end]
    if {[dict exists $::clocks $name]} { return [dict get $::clocks $name] }
    return {}
}
proc get_timing_paths {args} {
    if {[lsearch -exact $args -setup] >= 0} { return $::setup }
    if {[lsearch -exact $args -hold] >= 0} { return $::hold }
    error "unexpected timing analysis"
}
proc close_project {} { record close_project }
'''

def run(name, data, expected_ok, core_mhz=None, no_launch=False):
    assignments = '\n'.join((
        'set ::clocks ' + tdict(data['clocks'], True),
        'set ::periods ' + tdict(data['periods']),
        'set ::progress ' + tdict(data['progress']),
        'set ::setup ' + quote(' '.join(data['setup'])),
        'set ::hold ' + quote(' '.join(data['hold'])),
        'set ::slacks ' + tdict(data['slacks']),
        'set ::status ' + tdict(data['status']),
        'set ::refresh ' + tdict(data['refresh']),
        'set ::opt_help ' + quote(data['opt_help']),
        'set ::wait_success ' + ('1' if data['wait_success'] else '0'),
        'set ::wait_status ' + quote(data['wait_status']),
        'set ::ignore_opt_setter ' + ('1' if data['ignore_opt_setter'] else '0'),
        'set ::actual_opt_directive Default',
        'set ::impl_clocks ' + (tdict(data['impl_clocks'], True)
                                if data['impl_clocks'] is not None else 'inherit'),
        'set ::impl_periods ' + (tdict(data['impl_periods'])
                                 if data['impl_periods'] is not None else 'inherit'),
    ))
    source = assignments + '\n' + STUBS + '\n' + (
        'if {[catch {source ' + quote(TARGET) + '} error_text]} {'
        ' puts stderr "EXPECTED-OR-ACTUAL-STUB-FAIL: $error_text"; exit 1 }\n')
    env = os.environ.copy()
    env.pop('VEN_FPGA_CORE_MHZ', None)
    env.pop('VEN_FPGA_OPT_DIRECTIVE', None)
    if data['target'] is not None:
        env['VEN_FPGA_CORE_MHZ'] = str(data['target'])
    if data['opt_directive'] is not None:
        env['VEN_FPGA_OPT_DIRECTIVE'] = data['opt_directive']
    result = subprocess.run([TCLSH], input=source, text=True, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
    marker = '## IMPL OK'
    if expected_ok:
        assert result.returncode == 0, (name, result.stdout, result.stderr)
        assert result.stdout.count(marker) == 1, (name, result.stdout)
        assert result.stdout.index('## WNS ') < result.stdout.index(marker)
        assert result.stdout.index('## WHS ') < result.stdout.index(marker)
        assert result.stdout.count('STUB-CALL launch_runs ') == 1
        assert result.stdout.count('STUB-CALL close_design') == 1
        assert (result.stdout.index('STUB-CALL open_run synth_1') <
                result.stdout.index('STUB-CALL close_design') <
                result.stdout.index('STUB-CALL launch_runs ') <
                result.stdout.index('STUB-CALL open_run impl_1'))
        assert 'STUB-CALL close_project' in result.stdout
        assert result.stdout.count(f'## Frequency (core): {core_mhz:.6f} MHz') == 2
        expected_settings = int(data['opt_directive'] == 'RuntimeOptimized')
        assert result.stdout.count('STUB-CALL set_property ') == expected_settings
    else:
        assert result.returncode != 0, (name, result.stdout, result.stderr)
        assert marker not in result.stdout, (name, result.stdout)
    if no_launch:
        assert 'STUB-CALL launch_runs ' not in result.stdout
    RECEIPTS.append({'case': name, 'expected_ok': expected_ok,
                     'returncode': result.returncode, 'stdout': result.stdout,
                     'stderr': result.stderr, 'explicit_target': data['target']})
    print(f'{name}: expected={"success" if expected_ok else "failure"} rc={result.returncode}')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    if not TCLSH:
        raise RuntimeError('tclsh is required; Vivado is never a substitute')
    source_sha = hashlib.sha256(TARGET.read_bytes()).hexdigest()
    count = 0
    def check(name, data, ok=False, mhz=None, no_launch=False):
        nonlocal count
        run(name, data, ok, mhz, no_launch)
        count += 1
    check('actual-mmcm-unset-40', copy.deepcopy(BASE), True, 40)
    for target, period in [('40', '25'), ('45', '22.222222222'), ('50', '20')]:
        d = copy.deepcopy(BASE); d['target'] = target; d['periods']['core'] = period
        check('explicit-mmcm-target-' + target, d, True, int(target))
    d = copy.deepcopy(BASE); d['target'] = '45'; d['periods']['core'] = '22.222'
    check('quantized-mmcm-target-45', d, True, 1000.0 / 22.222)
    d = copy.deepcopy(BASE); d['periods']['core'] = '22.222222222'
    check('actual-mmcm-unset-45', d, True, 45)
    for clock, period, mhz in [('u_clkdiv_clk_out', '320', 3.125),
                               ('wr_clk_i', '20', 50)]:
        d = copy.deepcopy(BASE)
        d['clocks'] = {'clk_pl_0': ['pl'], clock: ['core']}
        d['periods']['core'] = period
        check('legacy-' + clock, d, True, mhz)
    d = copy.deepcopy(BASE); d['slacks']['setup_path'] = '-0.1'
    check('finite-negative-slack-not-a-timing-pass', d, True, 40)
    for clock in ('clk_pl_0', 'mmcm_clk'):
        d = copy.deepcopy(BASE); del d['clocks'][clock]
        check('missing-' + clock, d, no_launch=True)
        d = copy.deepcopy(BASE); d['clocks'][clock].append('duplicate')
        check('ambiguous-' + clock, d, no_launch=True)
        for value in ('', 'bad', '0', '-1', 'NaN', 'Inf', '-Inf'):
            d = copy.deepcopy(BASE)
            d['periods']['pl' if clock == 'clk_pl_0' else 'core'] = value
            check('invalid-period-' + clock + '-' + (value or 'empty'), d, no_launch=True)
    for target, period in [('40', '22.222222222'), ('40', '320'),
                            ('45', '25'), ('50', '25'), ('45', '22.224')]:
        d = copy.deepcopy(BASE); d['target'] = target; d['periods']['core'] = period
        check('wrong-target-' + target + '-period-' + period, d, no_launch=True)
    for value in ('', '0', '-1', '39', '40.0', 'bad', 'NaN', 'Inf', ' 40', '40 '):
        d = copy.deepcopy(BASE); d['target'] = value
        check('invalid-target-' + (value or 'empty'), d, no_launch=True)
    d = copy.deepcopy(BASE); d['target'] = '40'
    d['clocks'] = {'clk_pl_0': ['pl'], 'wr_clk_i': ['core']}
    d['periods']['core'] = '320'
    check('legacy-explicit-target-mismatch', d, no_launch=True)
    for names in (['mmcm_clk', 'wr_clk_i'], ['u_clkdiv_clk_out', 'wr_clk_i']):
        d = copy.deepcopy(BASE)
        d['clocks'] = {'clk_pl_0': ['pl'], **{n: ['core'] for n in names}}
        check('multiple-core-names-' + '-'.join(names), d, no_launch=True)
    for analysis in ('setup', 'hold'):
        for paths in ([], ['one', 'two']):
            d = copy.deepcopy(BASE); d[analysis] = paths
            check('bad-path-count-' + analysis + '-' + str(len(paths)), d)
        for value in ('', 'bad', 'NaN', 'Inf', '-Inf'):
            d = copy.deepcopy(BASE); d['slacks'][analysis + '_path'] = value
            check('invalid-slack-' + analysis + '-' + (value or 'empty'), d)
    for stage in ('synth_1', 'impl_1'):
        d = copy.deepcopy(BASE); d['progress'][stage] = '99%'
        check('incomplete-' + stage, d, no_launch=stage == 'synth_1')
    for property_name, value in (('refresh', 'true'), ('refresh', 'unknown'),
                                 ('status', 'synth_design ERROR')):
        d = copy.deepcopy(BASE); d[property_name]['synth_1'] = value
        check('default-invalid-synth-' + property_name + '-' + value, d, no_launch=True)
    d = copy.deepcopy(BASE); d['opt_directive'] = 'Default'
    check('explicit-default-no-setting-change', d, True, 40)
    runtime = copy.deepcopy(BASE)
    runtime['opt_directive'] = 'RuntimeOptimized'
    runtime['progress']['impl_1'] = '0%'
    runtime['wait_success'] = True
    check('documented-runtime-fresh-completion', copy.deepcopy(runtime), True, 40)
    for value in ('', 'NoBramPowerOpt', 'Explore', 'RuntimeOptimized; reset_run impl_1'):
        d = copy.deepcopy(BASE); d['opt_directive'] = value
        check('invalid-opt-directive-' + (value or 'empty'), d, no_launch=True)
    for stage in ('synth_1', 'impl_1'):
        d = copy.deepcopy(runtime); d['status'][stage] = 'opt_design ERROR'
        check('runtime-nonfresh-status-' + stage, d, no_launch=True)
    d = copy.deepcopy(runtime); d['refresh']['synth_1'] = 'true'
    check('runtime-stale-synthesis', d, no_launch=True)
    d = copy.deepcopy(runtime); d['progress']['impl_1'] = '1%'
    check('runtime-previously-started', d, no_launch=True)
    d = copy.deepcopy(runtime); d['opt_help'] = 'RuntimeOptimized is not documented here'
    check('runtime-unsupported-installed-help', d, no_launch=True)
    d = copy.deepcopy(runtime); d['wait_success'] = False
    check('runtime-incomplete-native-run', d)
    d = copy.deepcopy(runtime); d['refresh']['impl_1'] = 'true'
    check('runtime-stale-native-completion', d)
    d = copy.deepcopy(runtime); d['ignore_opt_setter'] = True
    check('runtime-setting-readback-mismatch', d, no_launch=True)
    d = copy.deepcopy(runtime); d['wait_status'] = 'route_design Complete!'
    check('runtime-progress-without-bitstream-completion', d)
    d = copy.deepcopy(runtime); d['periods']['pl'] = '12.5'
    check('runtime-wrong-ps-axi-period', d, no_launch=True)
    for clock in ('clk_pl_0', 'mmcm_clk'):
        d = copy.deepcopy(runtime); d['target'] = '40'
        d['impl_clocks'] = copy.deepcopy(d['clocks']); del d['impl_clocks'][clock]
        check('clock-lost-after-implementation-' + clock, d)
        assert 'STUB-CALL launch_runs ' in RECEIPTS[-1]['stdout']
        d = copy.deepcopy(runtime); d['target'] = '40'
        d['impl_periods'] = copy.deepcopy(d['periods'])
        d['impl_periods']['pl' if clock == 'clk_pl_0' else 'core'] = '320'
        check('clock-drift-after-implementation-' + clock, d)
        assert 'STUB-CALL launch_runs ' in RECEIPTS[-1]['stdout']
    assert hashlib.sha256(TARGET.read_bytes()).hexdigest() == source_sha
    summary = {'marker': 'IMPL-RESUME-TCL-STUB-OK', 'cases': count,
               'source_sha256': source_sha,
               'test_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'tclsh_path': TCLSH,
               'limitations': 'No Vivado, synthesis, route, physical timing, or board proof'}
    if args.receipt:
        with args.receipt.open('x') as stream:
            json.dump({'summary': summary, 'receipts': RECEIPTS}, stream, indent=2)
            stream.write('\n')
    print(json.dumps(summary | {'receipt': str(args.receipt) if args.receipt else None}))

if __name__ == '__main__':
    main()
