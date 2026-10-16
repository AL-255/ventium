"""Transfer only qualified pair-credit enqueue into the retained-input PC.

Keep all shared processor sources, 157 definitions, full P5 caches and input
repairs bound to their verified parents. Native source/trace checks qualify
this transfer, not canonical, standard-suite, timing or hardware acceptance.
"""
import inspect
from pathlib import Path
import sys

import build_system_read_ack_soc as template

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'verif/l1'))
import audit_qualified_pair_credit_core as core_audit
import build_qualified_pair_credit_core as core_build
import prepare_qualified_pair_credit as recipe

ROOT, PARENT = template.ROOT, template.PARENT
CORE = ROOT/'qualified-pair-credit-core-r1'
PARENT_MODEL = template.PARENT_MODEL
CORE_MODEL = core_audit.run.MODEL
CHANGES = core_build.CHANGES
transfer = template.transfer
sha, load, save, stable = template.sha, template.load, template.save, template.stable
PS2, PS2_SHA = template.PS2, template.PS2_SHA


def check_delta(name, before, after):
    if name in CHANGES:
        originals = {n:(PARENT/'source/rtl/mem'/n).read_text() for n in recipe.PINS}
        assert originals[Path(name).name].encode() == before
        assert recipe.transform(originals)[Path(name).name].encode() == after
        return True
    assert before == after, 'unreviewed source delta: '+name
    return False


def evidence():
    audited = core_audit.audit(ROOT)
    assert audited['directed_passed'] and audited['models'] == dict(parent=core_build.MODEL, candidate=CORE_MODEL)
    assert audited['counts'] == dict(native_children=180, full_trace_pairs=90,
                                     candidate_records=47886, candidate_v_retirements=5349)
    assert not any(audited[k] for k in ('canonical_gate_passed', 'standard_suite', 'hardware_acceptance'))
    pins = dict(audited['pins'])
    replay = ROOT/'qualified-pair-credit-replay-r1'
    before, closed = [load(replay/n) for n in ('started.json', 'closed.json')]
    core_audit.owner('ventium-qualified-pair-replay-oct16-r1.service', before['invocation'], 0)
    assert closed['regression_check_passed'] and closed['pins_unchanged'] and not closed['errors']
    assert not closed['masks_or_record_normalization'] and not closed['canonical_gate_passed']
    assert len(closed['rows']) == 108 and sum(r['records'] for r in closed['rows']) == 80800
    pins.update(before['pins'])
    for row in closed['rows']:
        witness = row['native']
        assert row['same_records'] and witness['actual_wait'] and witness['group_closed']
        assert witness['actual_return_code'] == 0 and not witness['timed_out']
        assert not witness['cleanup_errors'] and not witness['descendant_leak']
        assert not Path('/proc', str(witness['process_group'])).exists()
        old = replay/row['name']/'parent.vtrace'
        new = CORE/'generic-work'/(row['name']+'.func_rtl.vtrace')
        assert sha(old) == row['trace_sha256']
        assert core_audit.common.tracefmt.read_trace(str(old)).records == core_audit.common.tracefmt.read_trace(str(new)).records
    for p in replay.rglob('*'):
        if p.is_file(): pins[str(p)] = sha(p)
    functional = ROOT/'qualified-pair-credit-func-r1/audit.json'
    checked = load(functional)
    assert checked['passed'] and checked['model'] == CORE_MODEL
    assert (checked['functional_passes'], checked['functional_records'], checked['v_retirements'],
            checked['unmasked_functional_passes']) == (108, 80800, 30132, 105)
    assert not checked['canonical_gate_passed'] and not checked['standard_suite']
    pins.update(checked['pins']); pins.update(checked['artifacts']); pins[str(functional)] = sha(functional)
    for folder in (ROOT/'raw-prime-storage-input-r1', PARENT/'coremark-ui-disabled-r1'):
        accepted = load(folder/'audit.json')
        assert accepted['passed'] and accepted['model'] == PARENT_MODEL and not accepted['standard_suite']
        pins.update(accepted.get('artifacts', {})); pins.update(accepted.get('artifact_pins', {}))
        pins[str(folder/'audit.json')] = sha(folder/'audit.json')
    assert stable(pins)
    return pins


def adapted_prepare():
    assert sha(template.__file__) == 'fe09e95ce38efd6f44fdb0f480ea0feffcd2c96ecca5fd6d61cfdbdc7dabf420'
    source = inspect.getsource(template.prepare)
    for old, new in (
        ("'sim_system_read_ack_'", "'sim_qualified_pair_credit_'"),
        ('Path(previous.__file__),Path(transfer.__file__)', 'Path(template.__file__),Path(previous.__file__),Path(transfer.__file__)'),
        ('System read ACK only; full parent state/clock equality.',
         'Qualified paired-store enqueue only; full parent state/clock equality. Generic producer default unchanged.'),
    ):
        assert source.count(old) == 1, old
        source = source.replace(old, new)
    return source


def namespace():
    return dict(template.__dict__, __file__=__file__, template=template, recipe=recipe,
                core_build=core_build, core_audit=core_audit, CORE=CORE, CORE_MODEL=CORE_MODEL,
                CHANGES=CHANGES, check_delta=check_delta, evidence=evidence)


def prepare(root):
    scope = namespace()
    exec(compile(adapted_prepare(), __file__, 'exec'), scope)
    return scope['prepare'](root)


def main():
    scope = namespace()
    text = inspect.getsource(template.main).replace('System-read full PC prepared;', 'Pair-credit full PC prepared;')
    exec(compile(text, __file__, 'exec'), scope)
    scope['prepare'] = prepare
    return scope['main']()


if __name__ == '__main__':
    raise SystemExit(main())
