#!/usr/bin/env python3
"""Host-only real-tclsh regression for route_checkpoint_40mhz.tcl.

Every Vivado operation is a mock. Synthetic DCP/bit/bin/report fixtures are
written only beneath an explicitly selected external TMPDIR and then removed.
This tests guards and error propagation, not native routing, timing, CDC,
functional correctness, board deployment, or gameplay performance.

Example:
  TMPDIR=/home/yukidama/external/tmp python3 fpga/test_route_checkpoint_40mhz.py
"""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import tempfile
import time


TARGET = Path(__file__).resolve().with_name('route_checkpoint_40mhz.tcl')
EXTERNAL_TMP = Path('/home/yukidama/external/tmp')
MEMORY_LIMIT = 512 * 1024 * 1024
WALL_LIMIT = 115
COMPLETE = '## CHECKPOINT ROUTE COMPLETE'
REPORTS = (
    'utilization', 'utilization_hierarchical', 'clocks', 'clock_interaction',
    'bus_skew', 'exceptions_coverage', 'exceptions_ignored', 'check_timing',
    'drc', 'timing_summary', 'route_status', 'cdc', 'clk_pl_0_setup',
    'clk_pl_0_hold', 'mmcm_clk_setup', 'mmcm_clk_hold',
)
FORBIDDEN = (
    'open_project', 'create_project', 'reset_project', 'reset_run', 'reset_runs',
    'create_run', 'create_runs', 'launch_runs', 'wait_on_run', 'open_run',
    'synth_design', 'opt_design', 'place_design', 'phys_opt_design',
    'read_verilog', 'read_vhdl', 'read_ip', 'read_xdc', 'add_files',
    'generate_target', 'generate_synth_checkpoint', 'update_compile_order',
    'create_bd_design', 'write_hw_platform',
)
BASE = {
    'version': '2025.2', 'part': 'xczu15eg-ffvb1156-2-i',
    'top': 'rk_ao486_bd_wrapper', 'pl_clocks': 'pl', 'core_clocks': 'core',
    'pl_period': '10.000', 'core_period': '25.000', 'initial_placed': '1',
    'placed': '1', 'routed': '1', 'partial': '0', 'route_errors': '0',
    'fail_report': '', 'skip_report': '', 'empty_report': '',
    'route_error': '0', 'close_error': '0', 'checkpoint_error': '0',
    'bitstream_error': '0', 'missing_dcp': '0', 'missing_bit': '0',
    'missing_bin': '0', 'empty_dcp': '0', 'empty_bit': '0', 'empty_bin': '0',
    'after_bit_partial': '0', 'after_reports_bad_clock': '0',
    'setup_slack': '0.104', 'hold_slack': '0.012',
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quote(value):
    """A Tcl list element for fixture literals, not an arbitrary-code encoder."""
    value = str(value)
    if any(character in value for character in '{}\\\n\r'):
        raise ValueError('unsupported fixture literal')
    return '{' + value + '}'


STUBS = r'''
set ::phase before_route
set ::report_count 0
proc record {name args} { puts "STUB-CALL $name $args" }
proc forbidden {name args} {
    record FORBIDDEN $name {*}$args
    error "forbidden project/source/run operation: $name"
}
foreach name $::forbidden_names {
    proc $name {args} [format {forbidden %s {*}$args} $name]
}
# Do not let an unexpected exec spawn a compiler, simulator, or Vivado.
rename exec native_exec
proc exec {args} {
    if {$args ne [list sha256sum -- $::fixture]} {
        error "unexpected external command: $args"
    }
    record exec {*}$args
    return [native_exec {*}$args]
}
proc version {args} {
    if {$args ne {-short}} { error "unexpected version arguments" }
    record version {*}$args
    return [dict get $::scenario version]
}
proc set_param {args} {
    if {$args ne {general.maxThreads 1}} { error "unexpected thread setting" }
    record set_param {*}$args
}
proc open_checkpoint {args} {
    if {$args ne [list $::fixture]} { error "unexpected checkpoint" }
    record open_checkpoint {*}$args
}
proc current_project {} { return project }
proc current_design {} { return design }
proc get_clocks {args} {
    set name [lindex $args end]
    if {$args ni [list [list -quiet $name] [list $name]]} {
        error "unexpected clock query: $args"
    }
    record get_clocks {*}$args
    switch -- $name {
        clk_pl_0 { return [dict get $::scenario pl_clocks] }
        mmcm_clk { return [dict get $::scenario core_clocks] }
        default { error "unexpected clock name: $name" }
    }
}
proc get_property {name object} {
    record get_property $name $object
    switch -- $name {
        PART {
            if {$object ne "project"} { error "wrong part query object" }
            return [dict get $::scenario part]
        }
        TOP {
            if {$object ne "design"} { error "wrong top query object" }
            return [dict get $::scenario top]
        }
        NAME {
            # A non-project DCP design name is not its HDL module top.
            switch -- $object {
                design { return checkpoint_rk_ao486_bd_wrapper_physopt }
                pl { return clk_pl_0 }
                core { return mmcm_clk }
                default { error "unexpected name query: $object" }
            }
        }
        PERIOD {
            if {$::report_count == 16 && [dict get $::scenario after_reports_bad_clock]} {
                return 99.0
            }
            switch -- $object {
                pl { return [dict get $::scenario pl_period] }
                core { return [dict get $::scenario core_period] }
                default { error "unexpected period query: $object" }
            }
        }
        STARTPOINT_CLOCK - ENDPOINT_CLOCK {
            return [lindex [split $object :] 0]
        }
        SLACK {
            return [dict get $::scenario [lindex [split $object :] 1]_slack]
        }
        REQUIREMENT {
            set clock [lindex [split $object :] 0]
            return [dict get $::scenario [expr {$clock eq "pl" ? "pl_period" : "core_period"}]]
        }
        EXCEPTION { return none }
        default { error "unexpected property: $name $object" }
    }
}
proc list_property {object} { return {REQUIREMENT EXCEPTION} }
proc get_timing_paths {args} {
    record get_timing_paths {*}$args
    set clock [lindex $args [expr {[lsearch -exact $args -from] + 1}]]
    set capture [lindex $args [expr {[lsearch -exact $args -to] + 1}]]
    if {$clock ni {pl core} || $capture ne $clock ||
        [lsearch -exact $args -max_paths] < 0 ||
        [lindex $args [expr {[lsearch -exact $args -max_paths] + 1}]] ne "5" ||
        [lsearch -exact $args -nworst] < 0 ||
        [lindex $args [expr {[lsearch -exact $args -nworst] + 1}]] ne "1" ||
        [lsearch -exact $args -sort_by] < 0 ||
        [lindex $args [expr {[lsearch -exact $args -sort_by] + 1}]] ne "slack"} {
        error "unexpected bounded same-domain query: $args"
    }
    if {[lsearch -exact $args -setup] >= 0} { return [list "$clock:setup"] }
    if {[lsearch -exact $args -hold] >= 0} { return [list "$clock:hold"] }
    error "missing setup/hold query"
}
proc route_design {args} {
    if {$args ne {}} { error "route must use the unchanged native default" }
    record route_design {*}$args
    if {[dict get $::scenario route_error]} { error "injected route error" }
    set ::phase routed
}
proc fixture_write {path data} {
    set normalized [file normalize $path]
    if {[string first "${::output}/" $normalized] != 0 || [file exists $normalized]} {
        error "writer attempted nonfresh/outside-fixture output: $path"
    }
    set handle [open $normalized {WRONLY CREAT EXCL}]
    puts -nonewline $handle $data
    close $handle
}
proc report_fixture {name args} {
    record $name {*}$args
    set index [lsearch -exact $args -file]
    if {$index < 0} { error "report missing explicit file output: $name" }
    set path [lindex $args [expr {$index + 1}]]
    set stem [file rootname [file tail $path]]
    if {[file dirname [file normalize $path]] ne [file join $::output reports] ||
        $stem ni $::expected_reports || [file extension $path] ne ".rpt"} {
        error "unexpected report output: $path"
    }
    if {$stem eq [dict get $::scenario fail_report]} { error "injected report error: $stem" }
    incr ::report_count
    if {$stem eq [dict get $::scenario skip_report]} { return }
    set data "MOCK ONLY: $stem\n"
    if {$stem eq [dict get $::scenario empty_report]} { set data "" }
    fixture_write $path $data
}
foreach name {report_utilization report_clocks report_clock_interaction
              report_bus_skew report_exceptions check_timing report_drc
              report_timing_summary report_cdc report_timing} {
    proc $name {args} [format {report_fixture %s {*}$args} $name]
}
proc report_route_status {args} {
    if {[lindex $args 0] ne "-boolean_check"} {
        return [report_fixture report_route_status {*}$args]
    }
    if {[llength $args] != 2} { error "unexpected route query" }
    set name [lindex $args 1]
    record report_route_status {*}$args
    if {$::phase eq "before_route"} {
        if {$name ne "PLACED_FULLY"} { error "unexpected initial route query" }
        return [dict get $::scenario initial_placed]
    }
    if {$::phase eq "bit_written" && $name eq "PARTIALLY_ROUTED" &&
        [dict get $::scenario after_bit_partial]} { return 1 }
    switch -- $name {
        PLACED_FULLY { return [dict get $::scenario placed] }
        ROUTED_FULLY { return [dict get $::scenario routed] }
        PARTIALLY_ROUTED { return [dict get $::scenario partial] }
        ERRORS_IN_ROUTES { return [dict get $::scenario route_errors] }
        default { error "unexpected route state: $name" }
    }
}
proc write_checkpoint {args} {
    if {$args ne [list [file join $::output rk_ao486_bd_wrapper_routed.dcp]]} {
        error "unexpected checkpoint output/options"
    }
    record write_checkpoint {*}$args
    if {[dict get $::scenario checkpoint_error]} { error "injected checkpoint write error" }
    if {[dict get $::scenario missing_dcp]} { return }
    set data "SYNTHETIC MOCK DCP, NOT A NATIVE CHECKPOINT\n"
    if {[dict get $::scenario empty_dcp]} { set data "" }
    fixture_write [lindex $args 0] $data
}
proc set_property {args} {
    if {$args ne {XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} project}} {
        error "unexpected design/constraint setting change: $args"
    }
    record set_property {*}$args
}
proc write_bitstream {args} {
    if {$args ne [list -bin_file [file join $::output rk_ao486_bd_wrapper.bit]]} {
        error "unexpected bitstream output/options"
    }
    record write_bitstream {*}$args
    if {[dict get $::scenario bitstream_error]} { error "injected bitstream write error" }
    foreach extension {bit bin} {
        if {[dict get $::scenario missing_$extension]} { continue }
        set data "SYNTHETIC MOCK $extension, NOT A NATIVE BITSTREAM\n"
        if {[dict get $::scenario empty_$extension]} { set data "" }
        fixture_write [file join $::output rk_ao486_bd_wrapper.$extension] $data
    }
    set ::phase bit_written
}
proc close_project {} {
    record close_project
    if {[dict get $::scenario close_error]} { error "injected close error" }
}
'''


def prepare_tmp():
    selected = os.environ.get('TMPDIR')
    if not selected:
        raise RuntimeError('set TMPDIR explicitly beneath ' + str(EXTERNAL_TMP))
    parent = Path(selected).resolve(strict=True)
    external = EXTERNAL_TMP.resolve(strict=True)
    if not parent.is_relative_to(external) or not parent.is_dir():
        raise RuntimeError('TMPDIR must be an existing directory beneath external/tmp')
    if parent.stat().st_dev == Path('/').stat().st_dev:
        raise RuntimeError('external TMPDIR is on the root filesystem; refusing fallback')
    if not os.access(parent, os.W_OK | os.X_OK):
        raise RuntimeError('external TMPDIR is not writable/searchable')
    if shutil.disk_usage(parent).free < 1024 * 1024:
        raise RuntimeError('external TMPDIR has less than 1 MiB available')
    return parent


def limits():
    soft, hard = resource.getrlimit(resource.RLIMIT_AS)
    bound = MEMORY_LIMIT if hard == resource.RLIM_INFINITY else min(MEMORY_LIMIT, hard)
    resource.setrlimit(resource.RLIMIT_AS, (bound, hard))
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(
        TimeoutError('host-only regression exceeded its wall-clock budget')))
    signal.alarm(WALL_LIMIT)


def run_case(name, data, root, tclsh, target, started, expected_ok=False,
             expected_hash=None, no_open=False, no_route=False, no_bit=False,
             existing_output=False):
    case = root / name
    case.mkdir()
    fixture = case / 'physopt.dcp'
    fixture.write_bytes(b'SYNTHETIC MOCK INPUT; NOT A NATIVE DCP\n')
    before = digest(fixture)
    old = case / 'old-project-and-run-sentinel'
    old.write_bytes(b'old source/project/run content must remain unchanged\n')
    old_before = digest(old)
    output = case / 'new-output'
    if existing_output:
        output.mkdir()
        (output / 'preserve-me').write_bytes(b'existing output must not be overwritten\n')
    assignments = '\n'.join((
        'set ::scenario [dict create ' + ' '.join(
            quote(key) + ' ' + quote(value) for key, value in data.items()) + ']',
        'set ::fixture ' + quote(fixture),
        'set ::output ' + quote(output),
        'set ::expected_reports ' + quote(' '.join(REPORTS)),
        'set ::forbidden_names ' + quote(' '.join(FORBIDDEN)),
        'set argc 3',
        'set argv [list ' + ' '.join(quote(value) for value in (
            fixture, expected_hash if expected_hash is not None else before, output)) + ']',
    ))
    source = assignments + '\n' + STUBS + '\n' + (
        'if {[catch {source ' + quote(target) + '} error_text]} {'
        ' puts stderr "STUB-FAIL: $error_text"; exit 1 }\n')
    remaining = WALL_LIMIT - 5 - (time.monotonic() - started)
    if remaining <= 0:
        raise TimeoutError('host-only regression wall-clock budget exhausted')
    env = os.environ.copy()
    env['TMPDIR'] = str(root.parent)
    result = subprocess.run([tclsh], input=source, cwd=case, text=True, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=min(3, remaining))
    context = (name, result.returncode, result.stdout, result.stderr)
    calls = [line for line in result.stdout.splitlines() if line.startswith('STUB-CALL ')]
    assert not any(line.startswith('STUB-CALL FORBIDDEN ') for line in calls), context
    assert digest(fixture) == before, context
    assert digest(old) == old_before, context
    if existing_output:
        assert (output / 'preserve-me').read_bytes() == b'existing output must not be overwritten\n'
    if expected_ok:
        assert result.returncode == 0, context
        assert result.stdout.count(COMPLETE) == 1, context
        assert '(native artifacts/reports only; no deployment/timing/CDC acceptance asserted)' in result.stdout, context
        for filename in ('rk_ao486_bd_wrapper_routed.dcp', 'rk_ao486_bd_wrapper.bit',
                         'rk_ao486_bd_wrapper.bin'):
            assert (output / filename).is_file() and (output / filename).stat().st_size > 0, context
        found = {path.name for path in (output / 'reports').iterdir()}
        assert found == {name + '.rpt' for name in REPORTS}, (context, found)
        assert all((output / 'reports' / (name + '.rpt')).stat().st_size > 0
                   for name in REPORTS), context
        for operation in ('open_checkpoint', 'route_design', 'write_checkpoint',
                          'write_bitstream', 'close_project'):
            assert sum(line.startswith('STUB-CALL ' + operation + ' ') for line in calls) == 1, context
        ordered = [result.stdout.index('STUB-CALL ' + name + ' ') for name in
                   ('open_checkpoint', 'route_design', 'write_checkpoint', 'report_utilization',
                    'write_bitstream', 'close_project')]
        assert ordered == sorted(ordered), context
        assert result.stdout.index('STUB-CALL close_project ') < result.stdout.index(COMPLETE), context
        for state in ('PLACED_FULLY', 'ROUTED_FULLY', 'PARTIALLY_ROUTED', 'ERRORS_IN_ROUTES'):
            assert result.stdout.count('STUB-CALL report_route_status -boolean_check ' + state) >= 3, context
        for clock_name in ('clk_pl_0', 'mmcm_clk'):
            assert result.stdout.count('STUB-CALL get_clocks -quiet ' + clock_name) >= 2, context
    else:
        assert result.returncode != 0, context
        assert COMPLETE not in result.stdout, context
    for check, operation in ((no_open, 'open_checkpoint'), (no_route, 'route_design'),
                             (no_bit, 'write_bitstream')):
        if check:
            assert not any(line.startswith('STUB-CALL ' + operation + ' ') for line in calls), context
    print(f'{name}: expected={"success" if expected_ok else "failure"} rc={result.returncode}')
    return {'case': name, 'expected_ok': expected_ok, 'returncode': result.returncode,
            'stdout': result.stdout, 'stderr': result.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tcl', type=Path, default=TARGET)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    if not __debug__:
        raise RuntimeError('run without -O/PYTHONOPTIMIZE; this gate requires assertions')
    parent = prepare_tmp()
    tclsh = shutil.which('tclsh')
    if not tclsh:
        raise RuntimeError('tclsh is required; do not substitute Vivado')
    target = args.tcl.resolve(strict=True)
    source_sha = digest(target)
    receipt = args.receipt.absolute() if args.receipt else None
    if receipt and (not receipt.parent.resolve(strict=True).is_relative_to(EXTERNAL_TMP.resolve())
                    or receipt.exists()):
        raise RuntimeError('receipt must be a new file beneath external/tmp')
    limits()
    started = time.monotonic()
    receipts = []
    with tempfile.TemporaryDirectory(prefix='ventium-route-checkpoint-stubs-', dir=parent) as temp:
        root = Path(temp)

        def check(name, changes=None, ok=False, **kwargs):
            data = copy.deepcopy(BASE)
            data.update(changes or {})
            receipts.append(run_case(name, data, root, tclsh, target, started,
                                     expected_ok=ok, **kwargs))

        check('native-profile-all-sixteen-reports', ok=True)
        check('finite-negative-slack-is-not-timing-acceptance',
              {'setup_slack': '-0.25', 'hold_slack': '-0.01'}, ok=True)
        check('wrong-checkpoint-hash', expected_hash='0' * 64, no_open=True, no_route=True, no_bit=True)
        check('malformed-checkpoint-hash', expected_hash='not-a-sha256', no_open=True, no_route=True, no_bit=True)
        check('existing-output-refused', existing_output=True, no_open=True, no_route=True, no_bit=True)
        for key, value in (('version', '2025.1'), ('part', 'xck26-sfvc784-2LV-c'),
                           ('top', 'wrong_wrapper')):
            check('wrong-' + key, {key: value}, no_route=True, no_bit=True)
        for clock in ('pl', 'core'):
            for value in ('', 'pl core'):
                check('ambiguous-or-missing-' + clock + '-' + ('empty' if not value else 'two'),
                      {clock + '_clocks': value}, no_route=True, no_bit=True)
            for index, value in enumerate(('0', '-1', 'bad', 'NaN', 'Inf', '-Inf', '99')):
                check('invalid-' + clock + '-period-' + str(index),
                      {clock + '_period': value}, no_route=True, no_bit=True)
        check('unplaced-input', {'initial_placed': '0'}, no_route=True, no_bit=True)
        for key in ('placed', 'routed', 'partial', 'route_errors'):
            check('invalid-native-route-state-' + key,
                  {key: '0' if key in ('placed', 'routed') else '1'}, no_bit=True)
        check('native-route-command-error', {'route_error': '1'}, no_bit=True)
        check('checkpoint-writer-error', {'checkpoint_error': '1'}, no_bit=True)
        for name in REPORTS:
            check('report-command-error-' + name, {'fail_report': name}, no_bit=True)
        check('clock-changed-after-reporting', {'after_reports_bad_clock': '1'}, no_bit=True)
        check('bitstream-writer-error', {'bitstream_error': '1'})
        for artifact in ('dcp', 'bit', 'bin'):
            check('missing-' + artifact, {'missing_' + artifact: '1'})
            check('empty-' + artifact, {'empty_' + artifact: '1'})
        check('partial-routing-after-bitstream', {'after_bit_partial': '1'})
        check('native-close-error', {'close_error': '1'})
    assert digest(target) == source_sha, 'Tcl implementation changed during regression'
    summary = {
        'marker': 'ROUTE-CHECKPOINT-40MHZ-TCL-STUB-OK', 'cases': len(receipts),
        'source_sha256': source_sha, 'test_sha256': digest(Path(__file__)),
        'tclsh_path': tclsh, 'wall_seconds': time.monotonic() - started,
        'memory_limit_bytes': MEMORY_LIMIT, 'temporary_parent': str(parent),
        'limitations': 'Host mocks only; no Vivado/native route/STA/CDC/functional/board/gameplay proof',
    }
    if receipt:
        with receipt.open('x') as stream:
            json.dump({'summary': summary, 'receipts': receipts}, stream, indent=2)
            stream.write('\n')
    signal.alarm(0)
    print(json.dumps(summary | {'receipt': str(receipt) if receipt else None}))


if __name__ == '__main__':
    main()
