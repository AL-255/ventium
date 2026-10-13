"""Prepare a bounded passive cold Doom replay on the source-matched LMSW PC.

Reuse the qualified diagnostic lifecycle/media/resource checks, changing only
the audited model, owner label and cycle bound. No board or guest changes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil

import prepare_endpoint_map_doom_trace as old
import build_lmsw_soc as native

MODEL = '3e0f22506604fba879a6fa292463b5d07e442e86d24a4e91ec012cfcf2d05751'


def transform(text):
    text = old.transform(text)
    text = old.change(text, '34000000', '50000000', 2)
    text = old.change(text, 'import build_endpoint_map_soc as native', 'import build_lmsw_soc as native')
    text = old.change(text, 'ventium-endpoint-map-doom-smoke-', 'ventium-lmsw-doom-smoke-')
    text = old.change(text, "pc=timing.ROOT/'endpoint-map-soc-r1'", "pc=timing.ROOT/'lmsw-soc-r1'")
    text = old.change(text, 'timing.MODEL', repr(MODEL), 2)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--pc', type=Path, required=True)
    args = parser.parse_args()
    root, pc = args.out.resolve(), args.pc.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert pc.name=='lmsw-soc-r1' and pc.parent==root.parent
    closed = native.load(pc/'build-closed.json'); started = native.load(pc/'build-started.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert native.sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==MODEL
    assert started['changes']==native.CHANGES and native.stable(started['pins'])
    source = Path(__file__).with_name('run_endpoint_map_doom_smoke.py')
    text = transform(source.read_text())
    pins = {str(p):native.sha(p) for p in (Path(__file__),Path(old.__file__),Path(native.__file__),
        source,pc/'build-started.json',pc/'build-closed.json')}
    root.mkdir(); (root/'run.py').write_text(text)
    native.save(root/'prepared.json',dict(pins=pins,model=MODEL,
        driver_sha256=hashlib.sha256(text.encode()).hexdigest(),max_cycles=50000000,max_seconds=900,
        cold=True,passive=True,new_model=True,guest_modified=False,fpga_modified=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fps=None))


if __name__=='__main__': main()
