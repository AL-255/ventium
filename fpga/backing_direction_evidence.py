"""Recheck the sealed one-file FPGA transfer; never inherit parent acceptance."""
from pathlib import Path

import build_backing_direction_soc as native
import freeze_backing_direction_rk_candidate as export
import posted_mouse_evidence as mouse

MANIFEST='a241b7f819886adc58ca2fb1e2b3697222f0232754911a814e66a4c061af28a5'
MODEL='810840218013b9e8ec8f3fbc1f0f39da8dbdcbd8b9c09021ba03ea27036014bd'
VARIANT=export.VARIANT


def check(source):
    source=Path(source).resolve(strict=True)
    parent=source.parent/'v-result-carry-posted-mouse-fpga-r1'
    pins=mouse.check(parent)
    new=native.load(source/'input-manifest.json');old=native.load(parent/'input-manifest.json')
    receipt=native.load(source/'freeze-receipt.json')
    assert native.sha(source/'input-manifest.json')==receipt['manifest_sha256']==MANIFEST
    assert new['variant']==VARIANT and new['qualification']=='UNQUALIFIED'
    assert new['processor_platform_simulator_sha256']==MODEL and new['simulator_sha256'] is None
    assert receipt['preprocessing_passed'] and receipt['compiled_common_hdl']==170
    assert not receipt['full_wrapper_elaborated'] and not receipt['source_contract_passed']
    for k in ('hardware_defines','core_mhz','write_slots','l2_sets','source_closure'):assert new[k]==old[k]
    a={r['frozen']:r for r in old['files']};b={r['frozen']:r for r in new['files']}
    assert set(a)==set(b) and len(b)==192
    assert sorted(n for n in a if a[n]['sha256']!=b[n]['sha256'])==export.CHANGES
    for name,row in b.items():
        path=source/name
        assert native.sha(path)==row['sha256']
        export.check_delta(name,(parent/name).read_bytes(),path.read_bytes())
        pins[str(path)]=row['sha256']
    pins.update(receipt['input_pins'])
    for p in (Path(__file__),Path(export.__file__),Path(native.__file__),
              source/'input-manifest.json',source/'freeze-receipt.json',source/'defines.txt'):
        pins[str(p)]=native.sha(p)
    assert native.stable(pins)
    return pins
