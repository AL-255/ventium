"""Transfer the two-file parallel-admission cut into the retained-input PC.

Keep every other processor/peripheral source, all 157 defines, the full P5
caches and input-device repairs. Recheck native system and identical-input
functional traces; do not promote canonical failures or hardware acceptance.
"""
import inspect
from pathlib import Path
import sys
from types import SimpleNamespace

import build_qualified_pair_credit_soc as template

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'verif/l1'))
import audit_parallel_write_core as audited_core
import build_parallel_write_core as core_build
import prepare_parallel_write_admission as recipe

REPO = Path(__file__).resolve().parents[1]
ROOT, PARENT = template.ROOT, template.PARENT
CORE = ROOT/'parallel-write-core-r1'
PARENT_MODEL, CORE_MODEL = template.PARENT_MODEL, audited_core.run.MODEL
CHANGES = core_build.CHANGES
transfer = template.transfer
sha, load, save, stable = template.sha, template.load, template.save, template.stable
PS2, PS2_SHA = template.PS2, template.PS2_SHA
core_audit = SimpleNamespace(**vars(audited_core), owner=audited_core.template.owner,
                            common=audited_core.template.common)
HISTORICAL_SOURCES = {
    str(REPO/'verif/verify.sh'): (
        '7c65a13dc91de4bf94db923b2b91053347a6a12b5133964aa748fca8cddc282a',
        ROOT/'qualified-reference-profile-r1/prior-verify.sh'),
}


def historical(pins):
    """Bind one documented old gate to its archive; never edit old receipts."""
    result = {}
    for name, digest in pins.items():
        if name in HISTORICAL_SOURCES and digest == HISTORICAL_SOURCES[name][0]:
            archive = HISTORICAL_SOURCES[name][1]
            assert sha(archive) == digest, 'historical gate archive changed'
            result[str(archive)] = digest
            result[name] = sha(name)
        else:
            result[name] = digest
    return result


def check_delta(name, before, after):
    if name in CHANGES:
        originals = {n:(PARENT/'source/rtl/mem'/n).read_text() for n in recipe.PINS}
        assert originals[Path(name).name].encode() == before
        assert recipe.transform(originals)[Path(name).name].encode() == after
        return True
    assert before == after, 'unreviewed source delta: '+name
    return False


def adapted_evidence():
    assert sha(template.__file__) == '18c3dd820f142c56b3a12c17950173aaad757ece2b4a2cd418b9e073fabf15f2'
    source = inspect.getsource(template.evidence)
    for old, new in (
        ('qualified-pair-credit-replay-r1', 'parallel-write-replay-r1'),
        ('ventium-qualified-pair-replay-oct16-r1.service', 'ventium-parallel-write-replay-oct16-r1.service'),
        ('qualified-pair-credit-func-r1/audit.json', 'parallel-write-func-r1/audit.json'),
        ('    assert stable(pins)\n', '    pins = historical(pins)\n    assert stable(pins)\n'),
    ):
        source = recipe.once(source, old, new)
    return source


def evidence():
    scope = dict(globals())
    exec(compile(adapted_evidence(), __file__, 'exec'), scope)
    return scope['evidence']()


def adapted_prepare():
    source = template.adapted_prepare()
    for old, new in (
        ("    before,done=[load(PARENT/n) for n in ('build-started.json','build-closed.json')]",
         "    before,done=[load(PARENT/n) for n in ('build-started.json','build-closed.json')]\n"
         "    before['pins'] = historical(before['pins'])"),
        ("'sim_qualified_pair_credit_'", "'sim_parallel_write_'"),
        ('Path(template.__file__),Path(previous.__file__)',
         'Path(template.__file__),Path(template.template.__file__),Path(previous.__file__)'),
        ('input_parent_model=before[\'input_parent_model\'],legacy_aggregate_gate_passed=False,',
         'input_parent_model=before[\'input_parent_model\'],\n'
         '        historical_source_aliases={n:dict(sha256=v[0],archive=str(v[1])) for n,v in HISTORICAL_SOURCES.items()},\n'
         '        legacy_aggregate_gate_passed=False,'),
        ('Qualified paired-store enqueue only; full parent state/clock equality. Generic producer default unchanged.',
         'Parallel write admission only; full parent state/clock equality. Generic credit and latency unchanged.'),
    ):
        source = recipe.once(source, old, new)
    return source


def namespace():
    return dict(template.template.__dict__, __file__=__file__, template=template,
                recipe=recipe, core_build=core_build, core_audit=core_audit,
                CORE=CORE, CORE_MODEL=CORE_MODEL, CHANGES=CHANGES,
                check_delta=check_delta, evidence=evidence, historical=historical,
                HISTORICAL_SOURCES=HISTORICAL_SOURCES)


def prepare(root):
    scope = namespace()
    exec(compile(adapted_prepare(), __file__, 'exec'), scope)
    return scope['prepare'](root)


def main():
    scope = namespace()
    source = recipe.once(inspect.getsource(template.template.main),
                         'System-read full PC prepared;', 'Parallel-admission full PC prepared;')
    exec(compile(source, __file__, 'exec'), scope)
    scope['prepare'] = prepare
    return scope['main']()


if __name__ == '__main__': raise SystemExit(main())
