"""Seal the exact fetch-size cofactor against the measured faster FPGA parent."""
import argparse
import inspect
import json
from pathlib import Path
from types import SimpleNamespace

import build_sfetch_interior_soc as builder
import freeze_backing_direction_rk_candidate as previous
import sfetch_boundary_evidence as parent_evidence

MODEL = 'bccf110432a3ce42085841ee7dbb9056adaf277220b571b106cf91e6364eec76'
VARIANT = 'sfetch_interior_posted_mouse_unqualified'
CHANGES = ['ventium/'+n for n in builder.CHANGES]


def check_delta(name, before, after):
    return builder.check_delta(name.removeprefix('ventium/'), before, after)


def namespace():
    assert builder.sha(previous.__file__) == '0b49df689b0659415422c24d1db1a552e11f53c0a13d9f446246fbdbcad2f726'
    mouse = SimpleNamespace(**dict(previous.mouse.__dict__, MANIFEST=parent_evidence.MANIFEST,
        VARIANT=parent_evidence.VARIANT, check=parent_evidence.check))
    scope = dict(previous.__dict__, __file__=__file__, predecessor=previous,
        parent_evidence=parent_evidence, native=builder, mouse=mouse, PARENT=parent_evidence.MANIFEST,
        VARIANT=VARIANT, CHANGES=CHANGES, check_delta=check_delta)
    exec(compile(inspect.getsource(previous.check_profile), __file__, 'exec'), scope)
    return scope


def check_profile(old, start, closed, definitions, model):
    assert model == MODEL and not start['canonical_gate_passed']
    namespace()['check_profile'](old, start, closed, definitions, model)


def freeze_source():
    text = inspect.getsource(previous.freeze)
    for old, new in (
        ('Path(native.recipe.__file__),Path(previous.__file__),',
         'Path(native.recipe.__file__),Path(predecessor.__file__),Path(parent_evidence.__file__),Path(previous.__file__),'),
        ("note='Only inactive backing direction changes; all 170 common HDL sources audited. '",
         "note='Only interior fetch-size output is cofactored; all 170 common HDL sources audited. '"),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    return text


def freeze(parent, sim, build_unit, model, out):
    scope = namespace(); scope['check_profile'] = check_profile
    exec(compile(freeze_source(), __file__, 'exec'), scope)
    return scope['freeze'](parent, sim, build_unit, model, out)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('parent','sim','out'): ap.add_argument('--'+n, type=Path, required=True)
    ap.add_argument('--build-unit', required=True); ap.add_argument('--model-sha256', required=True)
    a = ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True), a.sim.resolve(strict=True),
        a.build_unit, a.model_sha256, a.out.resolve())))
