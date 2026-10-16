"""Build the exact RAW-parent parallel-admission derivative, not acceptance.

Retain the established full source/harness closure and guarded native builder.
The admission floor is 10 GiB; a low-disk invocation must stop before preparing
or compiling a model. No re-use of another model's C++ harness object is allowed.
"""
from pathlib import Path

import audit_parallel_write_admission as audit
import prepare_parallel_write_admission as recipe
import build_qualified_pair_credit_core as template

native = template.native
MODEL = template.MODEL
CHANGES = template.CHANGES


def check_leaf(leaf):
    assert leaf.name == 'parallel-write-wrapper-r1'
    receipt = leaf.parent/'parallel-write-native-audit-r1.json'
    checked = native.load(receipt)
    assert checked['passed'] and checked['native_runs'] == 32
    assert checked['positive_native_runs'] == 26 and checked['required_failing_mutants'] == 6
    assert not checked['whole_core'] and not checked['hardware_acceptance']
    assert native.stable(checked['pins'])
    # Recheck terminal service/scope identities and reconstruct fixtures,
    # rather than trusting a caller-provided PASS bit.
    actual = audit.audit(leaf.parent)
    assert actual == checked
    pins = dict(checked['pins'])
    for path in (receipt,Path(audit.__file__),Path(template.__file__),Path(template.previous.__file__)):
        pins[str(path.resolve())] = native.sha(path)
    return pins


def adapted_main():
    source = template.adapted_main()
    for old,new in (
        ('shutil.disk_usage(scratch).free > 5*1024**3',
         'shutil.disk_usage(scratch).free > 10*1024**3'),
        ("'tb_qualified_pair_credit_'", "'tb_parallel_write_'"),
        ('Qualified same-clock no-L2 paired-store enqueue only; generic admission, allocation, faults and latency unchanged',
         'Parallel payload-only single/pair write admission; generic credit, faults, ordering and latency unchanged'),
    ):
        source = recipe.once(source,old,new)
    return source


def main():
    namespace = dict(template.previous.__dict__,__file__=__file__,recipe=recipe,
                     MODEL=MODEL,CHANGES=CHANGES,check_leaf=check_leaf)
    exec(compile(adapted_main(),__file__,'exec'),namespace)
    return namespace['main']()


if __name__ == '__main__': raise SystemExit(main())
