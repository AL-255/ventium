"""Unchanged cold input/CRC controls for the boundary-stage input composition.

The exact boundary diagnostic cost policy remains required; no dependency on
a cancelled CAD waiter's receipt, no full-suite or physical acceptance claim.
"""
import argparse
from pathlib import Path
import sys
from types import SimpleNamespace

import build_boundary_ui_soc as build
import prime_width_ui_controls as parent_adapter

TEMPLATES = parent_adapter.TEMPLATES


def derive(action):
    assert build.sha(parent_adapter.__file__) == 'c0a96a0c621058df37c6e3b1f9a1c858d36784d0f87c301c80f22c8fa52b854f'
    text = parent_adapter.derive(action).replace('prime-width-', 'boundary-')
    # Parent CPU folder is sfetch-boundary-soc-r1; only this composition is
    # boundary-ui-soc-r1. Never compare against a fabricated parent directory.
    text = text.replace('ventium-fprem-sequence.iSZ9BAj4/boundary-soc-r1',
                        'ventium-fprem-sequence.iSZ9BAj4/sfetch-boundary-soc-r1')
    old = 'Path(template.__file__),Path(previous.__file__),'
    assert text.count(old) == 1
    text = text.replace(old, 'Path(parent_adapter.__file__),'+old)
    if action == 'input':
        old = "assert load(soc/'build-wait-closed.json')['passed']"
        new = "assert start['cycle_cost']['diagnostic_only'] and not start['canonical_gate_passed']"
    elif action == 'coremark':
        old = "assert json.loads((soc/'build-wait-closed.json').read_text())['passed']"
        new = "assert started['cycle_cost']['diagnostic_only'] and not started['canonical_gate_passed']"
    else:
        old = new = None
    if old is not None:
        assert text.count(old) == 1
        text = text.replace(old, new)
    compile(text, __file__, 'exec')
    return text


def selected_model(soc):
    assert soc == build.ROOT/'boundary-ui-soc-r1'
    done, start = (build.load(soc/name) for name in ('build-closed.json', 'build-started.json'))
    assert done['passed'] and done['inputs_unchanged'] and done['native_exit'] == 0
    assert start['parent_model'] == build.PARENT_MODEL and start['input_parent_model'] == build.UI_MODEL
    assert start['directed_model'] == build.cpu.CORE_MODEL
    assert start['processor_rtl_changes'] == [] and start['added_defines'] == []
    assert start['changes'] == [build.ui.PS2] and not start['canonical_gate_passed']
    assert start['cycle_cost'] == build.cpu.cycle_cost_diagnostic(Path(start['directed_core']))[1]
    assert build.stable(start['pins'])
    assert build.sha(soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == done['binary_sha256']
    return done['binary_sha256']


def namespace(action, model):
    template, _ = TEMPLATES[action]
    previous = template.previous
    runner = SimpleNamespace(MODEL=model, PARENT_MODEL=build.PARENT_MODEL,
                             CONTROLLER=build.ui.PS2_SHA, __file__=__file__)
    return dict(previous.__dict__, __file__=__file__, previous=previous,
                parent_adapter=parent_adapter, template=template, build=build,
                integration=build, runner=runner, MODEL=model, PARENT_MODEL=build.PARENT_MODEL)


def main():
    parser = argparse.ArgumentParser(description=__doc__, add_help=False)
    parser.add_argument('action', choices=TEMPLATES)
    parser.add_argument('--soc', type=Path, required=True)
    args, forwarded = parser.parse_known_args()
    soc = args.soc.resolve(strict=True)
    assert __debug__
    model = selected_model(soc)
    sys.argv = [__file__, '--soc', str(soc), *forwarded]
    scope = namespace(args.action, model)
    exec(compile(derive(args.action), __file__, 'exec'), scope)
    return scope['main']() if args.action == 'input' else 0


if __name__ == '__main__':
    raise SystemExit(main())
