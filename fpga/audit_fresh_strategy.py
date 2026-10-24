"""Independent read-only audit of fresh-run native synthesis configuration.

Vivado omits default-valued arguments from generated commands. Confirm both the
native command and actual run-property report instead of inventing a mismatch.
This can inspect a live run, but does NOT establish completion or timing closure.
"""
import argparse
import json
from pathlib import Path
import re
import shlex


def property_value(text, name):
    pattern = re.compile(re.escape(name)+r'[ \t]+\S+[ \t]+(?:true|false)[ \t]*(.*)$')
    values = [m.group(1).strip() for line in text.splitlines() if (m := pattern.fullmatch(line))]
    if len(values) != 1:
        raise ValueError('missing/ambiguous native property: '+name)
    return values[0]


def native_worker_log(script):
    log = Path(script).with_name('runme.log')
    return log.read_text() if log.is_file() else None


def audit_threads(script, threads=1, native_log=None):
    if type(threads) is not int or threads not in (1, 2, 4, 8):
        raise ValueError('only one, two, four or eight internal threads supported')
    values = re.findall(r'^[ \t]*set_param[ \t]+general\.maxThreads[ \t]+(\S+)[ \t]*$', script, re.M)
    observed = re.findall(r'^FRESH-NATIVE-THREADS-CHECK observed=([^\r\n]*)$', native_log or '', re.M)
    if observed and observed != [str(threads)]:
        raise ValueError('native worker thread readback disagrees')
    if values != [str(threads)]:
        # Only the observed default omission is admitted, with native worker
        # get_param evidence. A requested eight is never sufficient by itself.
        if values or threads != 8 or observed != ['8']:
            raise ValueError('native thread bound missing/ambiguous/mismatched')
    return threads


def audit_synth(script, properties, strategy, threads=1, native_log=None):
    audit_threads(script, threads, native_log)
    if threads not in (1, 2, 8) or (strategy in ('performance-route-first', 'routability-route-first', 'routability-retime-route-first') and threads not in (1, 8)):
        raise ValueError('unsupported synthesis thread count')
    directives = {'performance-netdelay': 'PerformanceOptimized', 'routability-spread': 'AlternateRoutability',
                  'performance-retime-bounded': 'PerformanceOptimized',
                  'performance-bounded': 'PerformanceOptimized',
                  'performance-route-first': 'PerformanceOptimized',
                  'routability-route-first': 'AlternateRoutability',
                  'routability-retime-route-first': 'AlternateRoutability'}
    directive = directives[strategy]
    retiming = 'on' if strategy in ('performance-retime-bounded', 'routability-retime-route-first') else 'auto'
    if strategy in ('performance-bounded', 'performance-route-first', 'routability-route-first'): retiming = 'off'
    commands = re.findall(r'^synth_design [^\n]+', script, re.M)
    if len(commands) != 1:
        raise ValueError('missing/ambiguous native synth_design')
    args = shlex.split(commands[0])
    for flag, value in (('-directive', directive), ('-top', 'rk_ao486_bd_wrapper'),
                        ('-part', 'xczu15eg-ffvb1156-2-i')):
        if args.count(flag) != 1 or args[args.index(flag)+1:args.index(flag)+2] != [value]:
            raise ValueError('native option mismatch: '+flag)
    if any(a == '-no_timing_driven' or a.startswith('-incremental') for a in args):
        raise ValueError('timing-disabled/incremental native synthesis')
    if any(a in ('-retiming', '-no_retiming') for a in args):
        raise ValueError('legacy retiming option not admitted')
    if '-global_retiming' in args or retiming in ('on', 'off'):
        if args.count('-global_retiming') != 1 or args[args.index('-global_retiming')+1:args.index('-global_retiming')+2] != [retiming]:
            raise ValueError('native retiming option mismatch')
    if '-flatten_hierarchy' in args:
        if args.count('-flatten_hierarchy') != 1 or args[args.index('-flatten_hierarchy')+1:args.index('-flatten_hierarchy')+2] != ['rebuilt']:
            raise ValueError('explicit hierarchy option mismatch')
    # Default omission is allowed only alongside actual native property evidence.
    expected = {
        'AUTO_INCREMENTAL_CHECKPOINT': '0',
        'INCREMENTAL_CHECKPOINT': '',
        'STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY': 'rebuilt',
        'STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE': directive,
        'STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING': retiming,
        'STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS': '',
    }
    for name, value in expected.items():
        if property_value(properties, name) != value:
            raise ValueError('native property mismatch: '+name)
    if not re.search(r'^set_property ip_cache_permissions disable(?:d)? \[current_project\]\s*$', script, re.M):
        raise ValueError('native IP cache disable missing')
    if re.search(r'^\s*(?:read_checkpoint|open_checkpoint)\s', script, re.M):
        raise ValueError('checkpoint input before native synthesis')
    return dict(command=commands[0], properties=expected, hierarchy_default_omitted='-flatten_hierarchy' not in args,
                timing_driven=True, prior_checkpoint_input=False, configured_threads=threads)


def audit_impl(script, properties, strategy, threads=1, native_log=None):
    """Check the emitted operations, not merely the strategy label."""
    audit_threads(script, threads, native_log)
    route_first = strategy in ('performance-route-first', 'routability-route-first', 'routability-retime-route-first')
    if (route_first and threads not in (4, 8)) or (not route_first and threads == 4):
        raise ValueError('unsupported implementation thread count')
    configs = {
        'performance-netdelay': ('ExtraNetDelay_high', 'NoTimingRelaxation',
            ['-directive AggressiveExplore', '-directive Explore']),
        'routability-spread': ('AltSpreadLogic_medium', 'AlternateCLBRouting',
            ['-directive Explore', '-directive Explore']),
        'performance-retime-bounded': ('AltSpreadLogic_medium', 'NoTimingRelaxation',
            ['-fanout_opt -placement_opt -restruct_opt -equ_drivers_opt',
             '-placement_opt -routing_opt -restruct_opt -hold_fix']),
        'performance-bounded': ('AltSpreadLogic_medium', 'NoTimingRelaxation',
            ['-fanout_opt -placement_opt -restruct_opt -equ_drivers_opt',
             '-placement_opt -routing_opt -restruct_opt -hold_fix']),
        'performance-route-first': ('AltSpreadLogic_medium', 'NoTimingRelaxation', []),
        'routability-route-first': ('AltSpreadLogic_high', 'AlternateCLBRouting', []),
        'routability-retime-route-first': ('AltSpreadLogic_high', 'AlternateCLBRouting', []),
    }
    place, route, phys = configs[strategy]
    for command, expected in (('opt_design', ['-directive RuntimeOptimized']),
                              ('place_design', ['-directive '+place]),
                              ('route_design', ['-directive '+route]), ('phys_opt_design', phys)):
        # Also capture a bare command: route-first must reject default phys_opt.
        actual = re.findall(r'^[ \t]*'+command+r'(?=[ \t\r\n]|$)([^\r\n]*)', script, re.M)
        if [shlex.split(a) for a in actual] != [shlex.split(a) for a in expected]:
            raise ValueError('native implementation command mismatch: '+command)
    for step, options in zip(('PHYS_OPT_DESIGN', 'POST_ROUTE_PHYS_OPT_DESIGN'), phys):
        if property_value(properties, f'STEPS.{step}.IS_ENABLED') not in ('1', 'true'):
            raise ValueError('physical optimization disabled: '+step)
        if strategy in ('performance-retime-bounded', 'performance-bounded'):
            if property_value(properties, f'STEPS.{step}.ARGS.DIRECTIVE') != 'Default' or \
               property_value(properties, f'STEPS.{step}.ARGS.MORE OPTIONS') != options:
                raise ValueError('bounded physical optimization property mismatch: '+step)
    if route_first:
        for step in ('PHYS_OPT_DESIGN', 'POST_ROUTE_PHYS_OPT_DESIGN'):
            if (property_value(properties, f'STEPS.{step}.IS_ENABLED') not in ('0', 'false') or
                property_value(properties, f'STEPS.{step}.ARGS.DIRECTIVE') != 'Default' or
                property_value(properties, f'STEPS.{step}.ARGS.MORE OPTIONS') != ''):
                raise ValueError('route-first physical stage property mismatch: '+step)
    return dict(strategy=strategy, physical_operations=phys, completion_verified=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run', type=Path)
    args = ap.parse_args()
    started = json.loads((args.run/'started.json').read_text())
    build = args.run/'build'
    script = build/'rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.tcl'
    result = audit_synth(script.read_text(), (build/'synth_1-properties.rpt').read_text(),
                         started['strategy'], started.get('tool_threads', 1), native_worker_log(script))
    print(json.dumps(dict(native_synthesis_configuration=result,
                         completion_verified=False, timing_signoff=False, gameplay_ipc=None), indent=2))


if __name__ == '__main__': main()
