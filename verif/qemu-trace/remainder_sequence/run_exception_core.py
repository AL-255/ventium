"""Cold UV-fast masked-DE and small-quotient reproduction with repaired QEMU.

Keep the original pinned driver untouched. Rebind only its exact reference
path/hash, and pin both that driver and this wrapper in the new receipts.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from run_small_quotient import sha, save


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('out','core','build','program'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve();build=a.build.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={13}
    built=json.loads((build/'closed.json').read_text());qemu=Path(built['binary'])
    assert built['passed'] and built['pins_unchanged'] and sha(qemu)==built['sha256']
    source=Path(__file__).with_name('run_small_quotient.py');text=source.read_text()
    assert sha(source)=='ef83f7f0dc0f94a2b105a7682b2adace2817521034ecca25de436ce820b3cc41'
    old="qemu=scratch/'ventium-qemu-frndint.wRXifJwr/build-r1/build/qemu-i386'"
    assert text.count(old)==1;text=text.replace(old,'qemu=Path('+repr(str(qemu))+')')
    old='da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d'
    assert text.count(old)==1;text=text.replace(old,built['sha256'])
    old='HERE=Path(__file__).resolve().parent'
    assert text.count(old)==1;text=text.replace(old,'HERE=Path('+repr(str(source.parent))+')')
    driver=root.with_suffix('.driver.py')
    with driver.open('x') as f:f.write(text)
    pins={str(p.resolve()):sha(p) for p in (Path(__file__),source,driver,build/'closed.json',qemu)}
    command=[sys.executable,'-B',str(driver),'--out',str(root),'--core',str(a.core.resolve(strict=True)),
             '--program',str(a.program.resolve(strict=True))]
    save(root.with_suffix('.driver.json'),dict(pins=pins,command=command,only_reference_rebound=True))
    code=subprocess.run(command,timeout=180).returncode
    assert all(sha(p)==h for p,h in pins.items())
    return code


if __name__=='__main__':raise SystemExit(main())
