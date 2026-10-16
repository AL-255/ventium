"""Seal only the early prime-width header on the measured boundary FPGA parent."""
import argparse
import json
from pathlib import Path

import build_prime_width_soc as builder
import freeze_sfetch_interior_rk_candidate as template

MODEL='cabf2f1198f476de7ec64fd18e179e6a1c2f57dc9ceeee6883a7f14ee3f9096d'
VARIANT='prime_width_posted_mouse_unqualified'
CHANGES=['ventium/'+n for n in builder.CHANGES]


def check_delta(name,before,after):
    return builder.check_delta(name.removeprefix('ventium/'),before,after)


def namespace():
    assert builder.sha(template.__file__)=='6d691037bff84f61939804357085965908bfa882901e3171e3253ce71bfd5b3e'
    scope=template.namespace()
    scope.update(__file__=__file__,native=builder,VARIANT=VARIANT,CHANGES=CHANGES,
                 check_delta=check_delta,template=template)
    return scope


def check_profile(old,start,closed,definitions,model):
    assert model==MODEL and not start['canonical_gate_passed']
    namespace()['check_profile'](old,start,closed,definitions,model)


def freeze_source():
    text=template.freeze_source()
    for old,new in (
        ('native.previous.AUX','native.original.AUX'),
        ('Path(predecessor.__file__),','Path(predecessor.__file__),Path(template.__file__),'),
        ('Only interior fetch-size output is cofactored; all 170 common HDL sources audited.',
         'Only early prime-width payload changes; all 170 common HDL sources audited.'),
    ):
        assert text.count(old)==(2 if old=='native.previous.AUX' else 1),old
        text=text.replace(old,new)
    return text


def freeze(parent,sim,build_unit,model,out):
    scope=namespace();scope['check_profile']=check_profile
    exec(compile(freeze_source(),__file__,'exec'),scope)
    return scope['freeze'](parent,sim,build_unit,model,out)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','sim','out'):ap.add_argument('--'+n,type=Path,required=True)
    ap.add_argument('--build-unit',required=True);ap.add_argument('--model-sha256',required=True)
    a=ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True),a.sim.resolve(strict=True),
        a.build_unit,a.model_sha256,a.out.resolve())))
