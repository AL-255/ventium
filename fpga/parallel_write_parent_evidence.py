"""Recheck the RAW FPGA parent with its one archived historical gate source.

The parent manifest and original independent source audit have fixed hashes.
Recheck every payload, exact three-file delta and the complete ancestry pin
closure. Only the documented old verify.sh identity resolves to an archive;
the current script is separately pinned. No old receipt is edited or promoted.
"""
from pathlib import Path

import build_parallel_write_soc as build
import raw_prime_storage_evidence as original

MANIFEST, MODEL, VARIANT = original.MANIFEST, original.MODEL, original.VARIANT


def check(source):
    source = Path(source).resolve(strict=True)
    assert source == build.ROOT/'raw-prime-storage-fpga-r1'
    parent = build.ROOT/'sfetch-boundary-fpga-r1'
    assert build.sha(source/'input-manifest.json') == MANIFEST
    assert build.sha(source/'source-audit.json') == '44a3398177da58c31bf77318a8a0277d7d5956e78a6adeb544ab4e056bd292b9'
    audit = build.load(source/'source-audit.json')
    assert audit['source_seal_checked'] and audit['manifest_sha256'] == MANIFEST
    new, old = (build.load(p/'input-manifest.json') for p in (source, parent))
    receipt = build.load(source/'freeze-receipt.json')
    assert build.sha(parent/'input-manifest.json') == original.export.PARENT
    assert receipt['manifest_sha256'] == MANIFEST and receipt['preprocessing_passed']
    assert receipt['compiled_common_hdl'] == 170 and receipt['payloads'] == 192
    assert not receipt['full_wrapper_elaborated'] and not receipt['source_contract_passed']
    assert new['variant'] == VARIANT and new['qualification'] == 'UNQUALIFIED'
    assert new['processor_platform_simulator_sha256'] == MODEL and new['simulator_sha256'] is None
    assert not any(new[k] for k in ('canonical_gate_passed', 'standard_suite', 'hardware_acceptance', 'full_soc_lint'))
    assert new['gameplay_ipc'] is None and new['fmax_mhz'] is None
    for key in ('hardware_defines', 'core_mhz', 'write_slots', 'l2_sets', 'source_closure'):
        assert new[key] == old[key]
    assert new['hardware_defines'] == (source/'defines.txt').read_text().splitlines()
    before, after = ({r['frozen']: r for r in m['files']} for m in (old, new))
    assert set(before) == set(after) and len(after) == 192
    assert sorted(n for n in after if before[n]['sha256'] != after[n]['sha256']) == original.export.CHANGES
    assert new['changed_parent_payloads'] == original.export.CHANGES
    assert new['changed_flow_payloads'] == [original.export.INJECTOR]
    pins = build.historical(receipt['input_pins'])
    for name, row in after.items():
        current, prior = source/name, parent/name
        assert current.stat().st_size == row['bytes'] and build.sha(current) == row['sha256']
        assert row['parent_sha256'] == before[name]['sha256'] == build.sha(prior)
        original.export.check_delta(name, prior.read_bytes(), current.read_bytes())
        pins[str(current)] = row['sha256']
        pins[str(prior)] = before[name]['sha256']
    assert all(Path(p).resolve(strict=True) == Path(q) for p, q in receipt['input_aliases'].items())
    for p in (Path(__file__).resolve(), Path(build.__file__).resolve(), Path(original.__file__).resolve(),
              Path(original.export.__file__).resolve(), source/'input-manifest.json',
              source/'source-audit.json', source/'freeze-receipt.json', source/'defines.txt',
              parent/'input-manifest.json'):
        pins[str(p)] = build.sha(p)
    assert build.stable(pins), 'parent source or historical evidence drift'
    return pins
