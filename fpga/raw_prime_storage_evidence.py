"""Recheck the three-delta FPGA seal without inheriting timing or acceptance."""
import argparse
import json
from pathlib import Path

import build_raw_prime_storage_soc as native
import freeze_raw_prime_storage_rk_candidate as export

MANIFEST = 'bf079f99538676ae1f43728b78ee52cc7d5b84ae0db49853ee545fcab0b72b66'
MODEL, VARIANT = export.MODEL, export.VARIANT


def check(source):
    source = Path(source).resolve(strict=True)
    parent = native.ROOT/'sfetch-boundary-fpga-r1'
    pins = export.parent_evidence.check(parent)
    new, old = (native.load(p/'input-manifest.json') for p in (source,parent))
    receipt = native.load(source/'freeze-receipt.json')
    assert native.sha(source/'input-manifest.json') == receipt['manifest_sha256'] == MANIFEST
    assert new['variant'] == VARIANT and new['qualification'] == 'UNQUALIFIED'
    assert new['processor_platform_simulator_sha256'] == MODEL and new['simulator_sha256'] is None
    assert receipt['preprocessing_passed'] and receipt['compiled_common_hdl'] == 170
    assert not receipt['full_wrapper_elaborated'] and not receipt['source_contract_passed']
    assert not any(new[k] for k in ('full_soc_lint','canonical_gate_passed','standard_suite','hardware_acceptance'))
    assert new['fmax_mhz'] is None and new['gameplay_ipc'] is None
    for k in ('hardware_defines','core_mhz','write_slots','l2_sets','source_closure'):
        assert new[k] == old[k]
    a, b = ({r['frozen']:r for r in manifest['files']} for manifest in (old,new))
    assert set(a) == set(b) and len(b) == 192
    assert sorted(n for n in a if a[n]['sha256'] != b[n]['sha256']) == export.CHANGES
    assert new['changed_parent_payloads'] == export.CHANGES and new['changed_flow_payloads'] == [export.INJECTOR]
    for name,row in b.items():
        p = source/name
        assert p.stat().st_size == row['bytes'] and native.sha(p) == row['sha256']
        assert row['parent_sha256'] == a[name]['sha256']
        export.check_delta(name,(parent/name).read_bytes(),p.read_bytes())
        pins[str(p)] = row['sha256']
    assert all(Path(p).resolve(strict=True) == Path(q) for p,q in receipt['input_aliases'].items())
    pins.update(receipt['input_pins'])
    for p in (Path(__file__).resolve(),Path(export.__file__).resolve(),Path(native.__file__).resolve(),
              source/'input-manifest.json',source/'freeze-receipt.json',source/'defines.txt'):
        pins[str(p)] = native.sha(p)
    assert native.stable(pins)
    return pins


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    a = ap.parse_args(); source = a.source.resolve(strict=True)
    pins = check(source)
    result = dict(source_seal_checked=True,pins_checked=len(pins),manifest_sha256=MANIFEST,
        processor_model=MODEL,changed_payloads=export.CHANGES,full_wrapper_elaborated=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        fmax_mhz=None,gameplay_ipc=None)
    with (source/'source-audit.json').open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps(result))
