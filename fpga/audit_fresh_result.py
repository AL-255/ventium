"""Audit a closed fresh run's native reports, independently of launcher parsing.

Numeric timing/coverage is NOT functional acceptance or a substitute for manual
exception review. This script never opens a design or launches Vivado.
"""
import argparse
import json
import math
from pathlib import Path
import re

from audit_fresh_strategy import audit_synth, property_value
from run_apr_trial import sha, validate_timing


def timing_summary(text):
    if text.count('| Design Timing Summary') != 1:
        raise ValueError('missing/ambiguous design timing summary')
    section = text.split('| Design Timing Summary')[1].split('| Clock Summary')[0]
    rows = []
    for line in section.splitlines():
        tokens = line.split()
        if len(tokens) != 12:
            continue
        try: row = [float(t) for t in tokens]
        except ValueError: continue
        rows.append(row)
    if len(rows) != 1 or not all(math.isfinite(v) for v in rows[0]):
        raise ValueError('missing/ambiguous/nonfinite design timing values')
    values = dict(zip(('wns', 'tns', 'setup_failing', 'setup_total',
                       'whs', 'ths', 'hold_failing', 'hold_total',
                       'wpws', 'tpws', 'pulse_failing', 'pulse_total'), rows[0]))
    for kind in ('setup', 'hold', 'pulse'):
        failed, total = values[kind+'_failing'], values[kind+'_total']
        if failed != int(failed) or total != int(total) or not 0 <= failed <= total or total <= 0:
            raise ValueError('invalid timing endpoint counts')
    met = all(values[k] >= 0 for k in ('wns', 'whs', 'wpws')) and all(
        values[k] == 0 for k in ('tns', 'ths', 'tpws', 'setup_failing', 'hold_failing', 'pulse_failing'))
    phrase = 'timing constraints are met.' if met else 'timing constraints are not met.'
    if phrase not in section.lower():
        raise ValueError('summary values conflict with native timing verdict')
    return dict(values=values, all_numeric_timing_met=met)


def timing_coverage(text):
    names = ('no_clock', 'constant_clock', 'pulse_width_clock', 'unconstrained_internal_endpoints',
             'no_input_delay', 'no_output_delay', 'multiple_clock', 'generated_clocks', 'loops',
             'partial_input_delay', 'partial_output_delay', 'latch_loops')
    counts = {}
    for name in names:
        matches = re.findall(r'^\d+\. checking '+name+r' \((\d+)\)$', text, re.M)
        # Native table of contents plus full section heading; a truncated TOC
        # alone is not a complete check_timing report.
        if len(matches) != 2 or len(set(matches)) != 1:
            raise ValueError('missing/inconsistent coverage section: '+name)
        counts[name] = int(matches[0])
        if counts[name] and name != 'no_output_delay':
            raise ValueError('timing coverage failure: '+name)
    if counts['no_output_delay']:
        leds = re.findall(r'^led\[(\d+)\]$', text, re.M)
        if counts['no_output_delay'] != 4 or sorted(leds) != ['0', '1', '2', '3']:
            raise ValueError('unconstrained outputs are not precisely four status LEDs')
    return counts


def route_and_drc(route, drc):
    counts = {}
    for name in ('routable nets', 'fully routed nets', 'nets with routing errors'):
        matches = re.findall(r'# of '+re.escape(name)+r'\.+\s*:\s*(\d+)\s*:', route)
        if len(matches) != 1:
            raise ValueError('missing/ambiguous route count: '+name)
        counts[name] = int(matches[0])
    if not counts['fully routed nets'] == counts['routable nets'] > 0 or counts['nets with routing errors']:
        raise ValueError('incomplete/error routing')
    if not re.search(r'Design State\s*:\s*Fully Routed', drc):
        raise ValueError('DRC not run on fully routed result')
    if re.search(r'\|\s*(?:Error|Critical Warning)\s*\|', drc):
        raise ValueError('DRC error or critical warning')
    return counts


def bus_skew(text):
    rows = re.findall(r'^Slack \((MET|VIOLATED)\)\s*:\s*(\S+)ns\s', text, re.M)
    # This fixed AXI clock-converter profile creates ten Gray-pointer buses.
    # A changed constraint count requires review, not an automatic waiver.
    if len(rows) != 10:
        raise ValueError('missing/changed bus-skew constraints')
    slacks = [float(v) for _, v in rows]
    if not all(math.isfinite(v) for v in slacks):
        raise ValueError('nonfinite bus-skew slack')
    if any((s >= 0) != (label == 'MET') for (label, _), s in zip(rows, slacks)):
        raise ValueError('inconsistent bus-skew verdict')
    return dict(constraints=len(rows), worst_slack_ns=min(slacks), met=min(slacks) >= 0)


def final_reports(build):
    summary = timing_summary((build/'timing-summary.rpt').read_text())
    pairs = validate_timing((build/'timing.tsv').read_text())
    coverage = timing_coverage((build/'check-timing.rpt').read_text())
    routes = route_and_drc((build/'route-status.rpt').read_text(), (build/'drc.rpt').read_text())
    skew = bus_skew((build/'bus-skew.rpt').read_text())
    cdc_safe = 'All paths are Safely Timed.' in (build/'cdc.rpt').read_text()
    numeric = summary['all_numeric_timing_met'] and skew['met'] and all(
        r['setup_ns'] >= 0 and r['hold_ns'] >= 0 for r in pairs)
    return dict(summary=summary, clock_pairs=pairs, coverage=coverage,
                routed_nets=routes, bus_skew=skew, native_cdc_all_safely_timed=cdc_safe,
                numeric_40mhz_timing_met=numeric,
                timing_signoff=False, exceptions_reviewed=False, hardware_acceptance=False,
                note='Manual exception/source/CDC review and physical standard-suite acceptance remain separate.')


def audit_closed(run):
    started = json.loads((run/'started.json').read_text())
    closed = json.loads((run/'closed.json').read_text())
    if (closed['native_exit'] != 0 or closed['reason'] is not None or not closed['inputs_unchanged'] or
        closed['failure'] not in (None, "audit: ValueError('flatten policy drift')")):
        raise ValueError('native/resource/input failure is not the known default-omission parser issue')
    if not started['fresh_synthesis'] or started['prior_checkpoint_inputs']:
        raise ValueError('not a fresh source-only run')
    if not all(sha(p) == digest for p, digest in started['pins'].items()):
        raise ValueError('pinned inputs changed')
    build = run/'build'
    for name, digest in closed['products'].items():
        if sha(build/name) != digest:
            raise ValueError('product changed: '+name)
    for required in ('fresh-routed.dcp', 'rk_ao486_system.bit.bin', 'timing-summary.rpt',
                     'timing.tsv', 'check-timing.rpt', 'route-status.rpt', 'drc.rpt',
                     'bus-skew.rpt', 'cdc.rpt', 'exceptions.rpt'):
        if required not in closed['products']:
            raise ValueError('missing completed product: '+required)
    if 'FRESH-STRATEGY-COMPLETE '+started['strategy'] not in (run/'native.log').read_text():
        raise ValueError('native completion marker missing')
    stages = [r.split('\t') for r in (build/'stages.tsv').read_text().splitlines()]
    if [name for name, _ in stages] != ['synth_1', 'impl_1', 'route_design', 'complete']:
        raise ValueError('missing/duplicate native stages')
    times = [int(t) for _, t in stages]
    if times != sorted(times) or times[-1]-times[1] >= started['implementation_limit_seconds']:
        raise ValueError('implementation deadline exceeded')
    script = build/'rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.tcl'
    synth = audit_synth(script.read_text(), (build/'synth_1-properties.rpt').read_text(), started['strategy'])
    impl = (build/'impl_1-properties.rpt').read_text()
    if property_value(impl, 'AUTO_INCREMENTAL_CHECKPOINT') != '0' or property_value(impl, 'INCREMENTAL_CHECKPOINT'):
        raise ValueError('incremental implementation')
    result = final_reports(build)
    result.update(native_completion_verified=True, native_synthesis_configuration=synth,
                  controller_parser_failure=closed['failure'], elapsed_seconds=closed['elapsed'],
                  implementation_seconds=times[-1]-times[1], gameplay_ipc=None,
                  source_manifest_sha256=sha(run/'prepared.json'))
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run', type=Path)
    ap.add_argument('--output', type=Path, help='new audit receipt; never overwrite')
    args = ap.parse_args()
    result = audit_closed(args.run)
    if args.output:
        with args.output.open('x') as f:
            json.dump(result, f, indent=2)
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
