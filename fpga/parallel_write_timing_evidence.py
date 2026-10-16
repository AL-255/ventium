"""Admit a matched timing measurement, never route, deployment or acceptance."""
from pathlib import Path

import parallel_write_evidence as sealed

export, native = sealed.export, sealed.native
ROOT, REPO = native.ROOT, native.REPO
SOURCE = ROOT/'parallel-write-fpga-r1'
MANIFEST, MODEL, VARIANT = sealed.MANIFEST, sealed.MODEL, sealed.VARIANT
CORE_MODEL = native.CORE_MODEL
ALIASES = native.HISTORICAL_SOURCES
sha, historical = native.sha, native.historical


def check(source=SOURCE):
    source = Path(source).resolve(strict=True)
    assert source == SOURCE
    pins = sealed.check(source)

    def merge(values):
        for name, digest in values.items():
            assert name not in pins or pins[name] == digest, ('conflicting source identity', name)
            pins[name] = digest

    def load(path):
        path = Path(path)
        merge({str(path): sha(path)})
        return native.load(path)

    # Reconstruct the real parent/candidate system and same-input comparisons,
    # rather than granting acceptance from summary flags.
    merge(native.evidence())
    receipt = load(source/'freeze-receipt.json')
    assert len(receipt['input_pins']) == 72738
    assert receipt['manifest_sha256'] == MANIFEST and receipt['compiled_common_hdl'] == 170
    audit = load(source/'source-audit.json')
    assert audit['source_seal_checked'] and audit['processor_model'] == MODEL
    assert audit['manifest_sha256'] == MANIFEST and audit['changed_payloads'] == export.CHANGES
    pc = ROOT/'parallel-write-soc-r1'
    prepared, closed = load(pc/'prepared.json'), load(pc/'build-closed.json')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert closed['binary_sha256'] == MODEL and closed['structural_debt_count'] == 98
    assert closed['structural_warnings_unchanged'] and not closed['errors']
    assert prepared['directed_model'] == CORE_MODEL and prepared['changes'] == native.CHANGES
    assert prepared['added_defines'] == [] and len(prepared['intersecting_rtl_sources']) == 102
    for name in prepared['intersecting_rtl_sources']:
        assert sha(pc/'source'/name) == sha(native.CORE/'candidate'/name)
    for binary, digest in ((pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', MODEL),
                           (native.CORE/'obj/tb_ventium', CORE_MODEL)):
        assert sha(binary) == digest
        merge({str(binary): digest})
    keyboard = load(ROOT/'parallel-write-input-r1/audit.json')
    assert keyboard['passed'] and keyboard['model'] == MODEL
    assert not keyboard['windows_ui'] and not keyboard['standard_suite']
    merge(keyboard['artifacts'])
    cmroot = pc/'coremark-ui-disabled-r1'
    cm, cm_audit = load(cmroot/'closed.json'), load(cmroot/'audit.json')
    assert cm['passed'] and cm['pins_unchanged'] and cm['all_children_reaped']
    assert cm_audit['passed'] and cm_audit['model'] == MODEL and cm_audit['no_oom']
    assert [row['ticks'] for row in cm['results']] == [4771298, 4755366]
    assert all(row['parent_ticks'] == row['candidate_ticks'] for row in cm_audit['measurements'])
    assert not cm_audit['duration_valid'] and not cm_audit['standard_suite']
    merge(cm_audit['artifact_pins'])
    for path in (Path(__file__).resolve(), Path(sealed.__file__).resolve(),
                 Path(export.__file__).resolve(), Path(native.__file__).resolve()):
        merge({str(path): sha(path)})
    assert native.stable(pins), 'source/evidence drift'
    return pins
