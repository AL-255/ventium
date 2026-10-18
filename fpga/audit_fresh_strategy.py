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


def audit_threads(script, threads=1):
    if type(threads) is not int or threads not in (1, 2):
        raise ValueError('only one or two internal threads supported')
    values = re.findall(r'^[ \t]*set_param[ \t]+general\.maxThreads[ \t]+(\S+)[ \t]*$', script, re.M)
    if values != [str(threads)]:
        raise ValueError('native thread bound missing/ambiguous/mismatched')
    return threads


def audit_synth(script, properties, strategy, threads=1):
    audit_threads(script, threads)
    directives = {'performance-netdelay': 'PerformanceOptimized', 'routability-spread': 'AlternateRoutability'}
    directive = directives[strategy]
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
    if '-flatten_hierarchy' in args:
        if args.count('-flatten_hierarchy') != 1 or args[args.index('-flatten_hierarchy')+1:args.index('-flatten_hierarchy')+2] != ['rebuilt']:
            raise ValueError('explicit hierarchy option mismatch')
    # Default omission is allowed only alongside actual native property evidence.
    expected = {
        'AUTO_INCREMENTAL_CHECKPOINT': '0',
        'INCREMENTAL_CHECKPOINT': '',
        'STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY': 'rebuilt',
        'STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE': directive,
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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run', type=Path)
    args = ap.parse_args()
    started = json.loads((args.run/'started.json').read_text())
    build = args.run/'build'
    script = build/'rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.tcl'
    result = audit_synth(script.read_text(), (build/'synth_1-properties.rpt').read_text(),
                         started['strategy'], started.get('tool_threads', 1))
    print(json.dumps(dict(native_synthesis_configuration=result,
                         completion_verified=False, timing_signoff=False, gameplay_ipc=None), indent=2))


if __name__ == '__main__': main()
