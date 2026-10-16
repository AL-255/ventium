"""Reapply unchanged cold input/CRC controls to the exact prime-width UI model.

Only model lineage, evidence paths and unit names differ from the closed
fetch/UI controls. No guest, grading, timing, resource or ownership relaxation.
This is not Win95 UI, duration-valid CoreMark or physical-board acceptance.
"""
import argparse
from pathlib import Path
import sys
from types import SimpleNamespace

import build_prime_width_ui_soc as build
import run_sfetch_interior_ui_input as input_template
import run_sfetch_interior_ui_coremark as crc_template
import audit_sfetch_interior_ui_coremark as audit_template

TEMPLATES = {
    'input': (input_template, 'f3fd75fc45391dd772ce59883bfbccfc0a409421f78a8b0b838c3badf698d45d'),
    'coremark': (crc_template, '9bdeb19a5f8089b53b889d92180119d21c58cc244dee0ca86aa59bf405c0e02b'),
    'audit-coremark': (audit_template, '589e18c365da2c7ae7cb57bb0ba29f9f1a354cdfb8cc04ebc5cbc784b2bfd7db'),
}


def derive(action):
    template, expected = TEMPLATES[action]
    assert build.sha(template.__file__) == expected, 'control template changed'
    text = template.derive()
    assert 'sfetch-interior-' in text
    text = text.replace('sfetch-interior-', 'prime-width-')
    # Retain the original runner/auditor pin and also pin this intermediate
    # adapter, whose source supplies the existing parent/binding assertions.
    old = 'Path(previous.__file__),'
    assert text.count(old) == 1
    text = text.replace(old, 'Path(template.__file__),Path(previous.__file__),')
    compile(text, __file__, 'exec')
    return text


def selected_model(soc):
    assert soc == build.ROOT/'prime-width-ui-soc-r1'
    done = build.load(soc/'build-closed.json')
    start = build.load(soc/'build-started.json')
    assert done['passed'] and done['inputs_unchanged'] and done['native_exit'] == 0
    assert build.load(soc/'build-wait-closed.json')['passed']
    assert start['parent_model'] == build.PARENT_MODEL
    assert start['input_parent_model'] == build.UI_MODEL
    assert start['directed_model'] == build.cpu.CORE_MODEL
    assert start['processor_rtl_changes'] == [] and start['added_defines'] == []
    assert build.stable(start['pins'])
    assert build.sha(soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == done['binary_sha256']
    return done['binary_sha256']


def namespace(action, model):
    template, _ = TEMPLATES[action]
    previous = template.previous
    runner = SimpleNamespace(MODEL=model, PARENT_MODEL=build.PARENT_MODEL,
                             CONTROLLER=build.ui.PS2_SHA, __file__=__file__)
    return dict(previous.__dict__, __file__=__file__, previous=previous,
                template=template, build=build, integration=build, runner=runner,
                MODEL=model, PARENT_MODEL=build.PARENT_MODEL)


def main():
    parser = argparse.ArgumentParser(description=__doc__, add_help=False)
    parser.add_argument('action', choices=TEMPLATES)
    parser.add_argument('--soc', type=Path, required=True)
    args, forwarded = parser.parse_known_args()
    soc = args.soc.resolve(strict=True)
    assert __debug__
    model = selected_model(soc)
    # The original parsers still validate all action-specific arguments.
    sys.argv = [__file__, '--soc', str(soc), *forwarded]
    scope = namespace(args.action, model)
    exec(compile(derive(args.action), __file__, 'exec'), scope)
    return scope['main']() if args.action == 'input' else 0


if __name__ == '__main__':
    raise SystemExit(main())
