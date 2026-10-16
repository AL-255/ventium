"""Unchanged cold input/short CRC controls for the RAW-storage PC candidate."""
import argparse
from pathlib import Path
import sys
from types import SimpleNamespace

import build_raw_prime_storage_soc as build
import boundary_ui_controls as parent_controls

TEMPLATES = parent_controls.TEMPLATES


def derive(action):
    assert build.sha(parent_controls.__file__) == 'aef9df68e8535e86cc69dfd203b1cbd830517ca942361b1200cb3bc9319b5fc0'
    text = parent_controls.derive(action)
    text = text.replace("'boundary-ui-soc-r1'", "'raw-prime-storage-soc-r1'")
    text = text.replace('ventium-boundary-ui-cm10-', 'ventium-raw-prime-storage-cm10-')
    text = text.replace('.UI_MODEL', '.parent_build.UI_MODEL').replace('.cpu.CORE_MODEL', '.CORE_MODEL')
    text = text.replace("['cycle_cost']", "['inherited_cycle_cost']")
    if action == 'audit-coremark':
        old = "build['processor_rtl_changes']==[]"
        new = "build['processor_rtl_changes']==[integration.recipe.FILE]"
        text = text.replace('ventium-fprem-sequence.iSZ9BAj4/sfetch-boundary-soc-r1',
                            'ventium-fprem-sequence.iSZ9BAj4/boundary-ui-soc-r1')
        text = text.replace("parent/'coremark-r1/", "parent/'coremark-ui-disabled-r1/")
    else:
        prefix = 'start' if action == 'input' else 'started'
        old = prefix+"['processor_rtl_changes']==[]"
        new = prefix+"['processor_rtl_changes']==[build.recipe.FILE]"
    assert text.count(old) == 1
    text = text.replace(old, new)
    old = 'Path(parent_adapter.__file__),'
    assert text.count(old) == 1
    text = text.replace(old, 'Path(parent_controls.__file__),'+old)
    compile(text, __file__, 'exec')
    return text


def selected_model(soc):
    assert soc == build.ROOT/'raw-prime-storage-soc-r1'
    start, done = (build.load(soc/name) for name in ('build-started.json','build-closed.json'))
    assert done['passed'] and done['inputs_unchanged'] and done['native_exit'] == 0
    assert start['parent_model'] == build.PARENT_MODEL and start['directed_model'] == build.CORE_MODEL
    assert start['changes'] == start['processor_rtl_changes'] == [build.recipe.FILE]
    assert start['added_defines'] == [] and start['binding_read_wire'] == 'kb_fifo_rdreq'
    assert start['inherited_cycle_cost']['diagnostic_only'] and not start['canonical_gate_passed']
    assert not start['legacy_aggregate_gate_passed']
    assert build.stable(start['pins'])
    assert build.sha(soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == done['binary_sha256']
    return done['binary_sha256']


def namespace(action, model):
    scope = parent_controls.namespace(action, model)
    runner = SimpleNamespace(MODEL=model, PARENT_MODEL=build.PARENT_MODEL,
                             CONTROLLER=build.parent_build.ui.PS2_SHA, __file__=__file__)
    scope.update(__file__=__file__, parent_controls=parent_controls, build=build,
                 integration=build, runner=runner, MODEL=model,
                 PARENT_MODEL=build.PARENT_MODEL, CONTROLLER=runner.CONTROLLER)
    return scope


def main():
    ap = argparse.ArgumentParser(description=__doc__, add_help=False)
    ap.add_argument('action', choices=TEMPLATES)
    ap.add_argument('--soc', type=Path, required=True)
    args, forwarded = ap.parse_known_args()
    soc = args.soc.resolve(strict=True)
    assert __debug__
    model = selected_model(soc)
    sys.argv = [__file__, '--soc', str(soc), *forwarded]
    scope = namespace(args.action, model)
    exec(compile(derive(args.action), __file__, 'exec'), scope)
    return scope['main']() if args.action == 'input' else 0


if __name__ == '__main__': raise SystemExit(main())
