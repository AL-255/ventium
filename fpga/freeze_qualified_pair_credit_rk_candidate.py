"""Seal the exact two-file pair-credit export; no CAD or board actions.

Keep all 192 payloads, 170 shared HDL sources, 159 hardware defines, retained
input-device fixes and posted transport bound to the independently tested PC.
No timing, standard-suite, full-wrapper or physical acceptance is inherited.
"""
import argparse
import inspect
import json
from pathlib import Path
from types import SimpleNamespace

import build_qualified_pair_credit_soc as native_module
import freeze_system_read_ack_rk_candidate as template

# The new builder exposes only its build API. Supply the repository location
# needed by the existing seal without editing a source pinned by live probes.
native = SimpleNamespace(**vars(native_module), REPO=template.native.REPO)
parent_evidence = template.parent_evidence
MODEL = '03e347c7055cf24255b4527f446b7b9f293452da3e36b205fc910f413a81f961'
VARIANT = 'qualified_pair_credit_retained_input_unqualified'
PARENT = parent_evidence.MANIFEST
CHANGES = sorted('ventium/'+n for n in native.CHANGES)
INJECTOR, CONTROLLER = template.INJECTOR, template.CONTROLLER
require = template.require


def check_delta(name, before, after):
    return native.check_delta(name.removeprefix('ventium/'), before, after)


def check_profile(old, start, closed, definitions):
    scope = dict(template.__dict__, native=native, MODEL=MODEL)
    exec(compile(inspect.getsource(template.check_profile), __file__, 'exec'), scope)
    return scope['check_profile'](old, start, closed, definitions)


def adapted_freeze():
    assert native.sha(template.__file__) == 'e1794e6e79b3bf89c6d94a6ddf7c9b540b7eaef45197f1c65357ba3bb68cc187'
    source = template.adapted_freeze()
    for old, new in (
        ("'system-read-ack-soc-r1'", "'qualified-pair-credit-soc-r1'"),
        ("'system-read-ack-input-r1'", "'qualified-pair-credit-input-r1'"),
        ('read(Path(previous.__file__).resolve());', 'read(Path(previous.__file__).resolve()); read(Path(template.__file__).resolve());'),
        ('Exact nine-file system read ACK cut.', 'Exact two-file qualified paired-store enqueue cut.'),
    ):
        assert source.count(old) == 1, old
        source = source.replace(old, new)
    return source


def freeze(parent, sim, build_unit, out):
    scope = dict(template.previous.__dict__, __file__=__file__, previous=template.previous,
                 template=template, native=native, parent_evidence=parent_evidence,
                 MODEL=MODEL, VARIANT=VARIANT, PARENT=PARENT, CHANGES=CHANGES,
                 check_delta=check_delta, check_profile=check_profile)
    exec(compile(adapted_freeze(), __file__, 'exec'), scope)
    return scope['freeze'](parent, sim, build_unit, out)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'sim', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    ap.add_argument('--build-unit', required=True)
    a = ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True), a.sim.resolve(strict=True),
                            a.build_unit, a.out.resolve())))
