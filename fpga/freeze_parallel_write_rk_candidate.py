"""Seal the two-file parallel-admission FPGA export; no CAD or acceptance."""
import argparse
import inspect
import json
from pathlib import Path

import build_parallel_write_soc as native
import freeze_qualified_pair_credit_rk_candidate as template
import parallel_write_parent_evidence as parent_evidence

MODEL = 'b9b2ab1921b95418a161516a945e951184b367f3d627987b0e05ba0b248d5123'
VARIANT = 'parallel_write_admission_retained_input_unqualified'
PARENT = parent_evidence.MANIFEST
CHANGES = sorted('ventium/'+n for n in native.CHANGES)
INJECTOR, CONTROLLER = template.INJECTOR, template.CONTROLLER
require = template.require


def check_delta(name, before, after):
    return native.check_delta(name.removeprefix('ventium/'), before, after)


def check_profile(old, start, closed, definitions):
    scope = dict(template.template.__dict__, native=native, MODEL=MODEL,
                 parent_evidence=parent_evidence)
    exec(compile(inspect.getsource(template.template.check_profile), __file__, 'exec'), scope)
    return scope['check_profile'](old, start, closed, definitions)


def adapted_freeze():
    assert native.sha(template.__file__) == 'c04745842b1f1e19e5ad67d2a3d7333dfff6a835c281965dc3d8494dc1faf9e0'
    source = template.adapted_freeze()
    for old, new in (
        ("'qualified-pair-credit-soc-r1'", "'parallel-write-soc-r1'"),
        ("'qualified-pair-credit-input-r1'", "'parallel-write-input-r1'"),
        ('read(Path(template.__file__).resolve());',
         'read(Path(template.__file__).resolve()); read(Path(template.template.__file__).resolve());'),
        ('Exact two-file qualified paired-store enqueue cut.', 'Exact two-file parallel write-admission cut.'),
    ):
        source = native.recipe.once(source, old, new)
    return source


def freeze(parent, sim, build_unit, out):
    scope = dict(template.template.previous.__dict__, __file__=__file__,
                 previous=template.template.previous, template=template,
                 native=native, parent_evidence=parent_evidence, MODEL=MODEL,
                 VARIANT=VARIANT, PARENT=PARENT, CHANGES=CHANGES,
                 check_delta=check_delta, check_profile=check_profile)
    exec(compile(adapted_freeze(), __file__, 'exec'), scope)
    return scope['freeze'](parent, sim, build_unit, out)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'sim', 'out'): ap.add_argument('--'+name, type=Path, required=True)
    ap.add_argument('--build-unit', required=True)
    a = ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True), a.sim.resolve(strict=True),
                            a.build_unit, a.out.resolve())))
