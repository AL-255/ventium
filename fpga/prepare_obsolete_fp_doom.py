"""Prepare the unchanged bounded cold diagnostic on the obsolete-x87 PC.

Same original media, passive logging, lifecycle and disk/memory guards.
No FPGA programming, snapshots, breakpoints, stepping or guest patches.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil

import prepare_lmsw_doom as old
import build_obsolete_fp_soc as native

MODEL='f0b7197c7b1becc3043f18ffe650c4956152ae8a20fc7397f9213f55ebdd5d98'


def transform(source):
    text=old.transform(source)
    edits=[('import build_lmsw_soc as native','import build_obsolete_fp_soc as native',1),
        ('ventium-lmsw-doom-smoke-','ventium-obsolete-fp-doom-smoke-',1),
        ("pc=timing.ROOT/'lmsw-soc-r1'","pc=timing.ROOT/'obsolete-fp-soc-r1'",1),
        (old.MODEL,MODEL,2)]
    for before,after,count in edits:
        if text.count(before)!=count:raise ValueError('obsolete-FP cold runner drift')
        text=text.replace(before,after)
    return text


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('out','pc'):parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args();root,pc=args.out.resolve(),args.pc.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert pc.name=='obsolete-fp-soc-r1' and pc.parent==root.parent
    c,s=native.load(pc/'build-closed.json'),native.load(pc/'build-started.json')
    assert c['passed'] and c['inputs_unchanged'] and c['native_exit']==0
    assert native.sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==c['binary_sha256']==MODEL
    assert s['changes']==native.CHANGES and native.stable(s['pins'])
    source=Path(__file__).with_name('run_endpoint_map_doom_smoke.py')
    text=transform(source.read_text())
    pins={str(p):native.sha(p) for p in (Path(__file__),Path(old.__file__),Path(native.__file__),
        source,pc/'build-started.json',pc/'build-closed.json')}
    root.mkdir();(root/'run.py').write_text(text)
    native.save(root/'prepared.json',dict(pins=pins,model=MODEL,
        driver_sha256=hashlib.sha256(text.encode()).hexdigest(),max_cycles=50000000,max_seconds=900,
        cold=True,passive=True,new_model=True,guest_modified=False,fpga_modified=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fps=None))


if __name__=='__main__':main()
