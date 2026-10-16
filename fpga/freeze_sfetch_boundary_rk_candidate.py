"""Seal the exact boundary-only fetch experiment with the corrected wrapper.

No processor or full-wrapper acceptance is inherited. The 192-payload source
closure, all 170 common HDL files, geometry and 159 hardware definitions must
match the measured PC model; only the two tested core files may change.
"""
import argparse
import inspect
import json
from pathlib import Path
from types import SimpleNamespace

import build_sfetch_boundary_soc as builder
import freeze_backing_direction_rk_candidate as previous

MODEL = 'b32ab4b34482669c03ea57ce7be0dbd475623fa00b00c4c814fec976d75c86d2'
VARIANT = 'sfetch_boundary_posted_mouse_unqualified'
CHANGES = ['ventium/'+n for n in builder.CHANGES]
BASE_SHA = '0b49df689b0659415422c24d1db1a552e11f53c0a13d9f446246fbdbcad2f726'


def check_delta(name, before, after):
    relative = name.removeprefix('ventium/')
    if relative in builder.CHANGES:
        assert builder.recipe.transform(before.decode(),relative).encode()==after
        return True
    assert before==after, 'unreviewed source change: '+name
    return False


def namespace():
    assert builder.sha(previous.__file__)==BASE_SHA
    native = SimpleNamespace(**builder.__dict__)
    native.check_definitions = builder.previous.check_definitions
    scope = dict(previous.__dict__, __file__=__file__, predecessor=previous,
                 native=native, MODEL=MODEL, VARIANT=VARIANT, CHANGES=CHANGES,
                 check_delta=check_delta)
    exec(compile(inspect.getsource(previous.check_profile),__file__,'exec'),scope)
    return scope


def check_profile(old,start,closed,definitions,model):
    assert model==MODEL
    assert not start['canonical_gate_passed'] and start['cycle_cost']['diagnostic_only']
    namespace()['check_profile'](old,start,closed,definitions,model)


def freeze_source():
    text = inspect.getsource(previous.freeze)
    for old,new in (
        ('Path(native.recipe.__file__),Path(previous.__file__),',
         'Path(native.recipe.__file__),Path(native.recipe.base.__file__),Path(predecessor.__file__),Path(previous.__file__),'),
        ("note='Only inactive backing direction changes; all 170 common HDL sources audited. '",
         "note='Only true-boundary fetch beats acquire a preparation stage; all 170 common HDL sources audited. '"),
    ):
        text = builder.recipe.replace_once(text,old,new)
    return text


def freeze(parent,sim,build_unit,model,out):
    scope=namespace()
    scope['check_profile']=check_profile
    exec(compile(freeze_source(),__file__,'exec'),scope)
    return scope['freeze'](parent,sim,build_unit,model,out)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','sim','out'):ap.add_argument('--'+n,type=Path,required=True)
    ap.add_argument('--build-unit',required=True)
    ap.add_argument('--model-sha256',required=True)
    a=ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True),a.sim.resolve(strict=True),
        a.build_unit,a.model_sha256,a.out.resolve())))
