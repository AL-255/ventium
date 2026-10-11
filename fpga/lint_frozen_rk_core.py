#!/usr/bin/env python3
"""Strict CPU-hierarchy lint of an immutable, exported RK hardware candidate.

This is not full-SoC lint, standard-suite acceptance or FPGA timing sign-off.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from freeze_rk_candidate import frozen_path

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    args = parser.parse_args()
    source, out = args.source.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 4*1024**3
    manifest_path = source/'input-manifest.json'
    assert sha(manifest_path) == args.manifest_sha256
    manifest = json.loads(manifest_path.read_text())
    assert manifest['qualification'] == 'UNQUALIFIED'
    definitions = (source/'defines.txt').read_text().splitlines()
    assert definitions == manifest['hardware_defines'] and len(definitions) == len(set(definitions)) == 156
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT','SYNTHESIS','VTM_NO_DPI'} <= set(definitions)
    assert not {'VEN_CACHE_HALF','VEN_IC_NARROWB','VEN_SYS_FASTPATH_ALL'} & set(definitions)
    pins = {str(source/frozen_path(row['frozen'])):row['sha256'] for row in manifest['files']}
    assert len(pins) == len(manifest['files']) == 190
    for path in (Path(__file__), manifest_path, source/'defines.txt',
                 REPO/'tools/build_scope.sh', REPO/'tools/verilator_serial.sh'):
        pins[str(path)] = sha(path)
    assert all(sha(path) == digest for path, digest in pins.items())
    out.mkdir()
    def save(name, value):
        with (out/name).open('x') as stream: json.dump(value, stream, indent=2)
    cmd = [str(REPO/'tools/verilator_serial.sh'),'--lint-only','-sv','--assert','--top-module','ventium_top',
        '-Wall','-Wno-UNUSED','-Wno-fatal',
        *['-Werror-'+kind for kind in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
        *['+define+'+name for name in definitions], '-F', str(source/'ventium/rtl_ven_core.f'),
        '--Mdir',str(out/'obj')]
    env = dict(os.environ, TMPDIR=str(out), VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    save('started.json',dict(pins=pins,command=cmd,invocation=os.environ['INVOCATION_ID']))
    begin = time.monotonic()
    with (out/'native.log').open('x') as stream:
        done = subprocess.run([str(REPO/'tools/build_scope.sh'),'--','timeout','--kill-after=10s','240s',*cmd],
            cwd=source/'ventium',env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=300)
    stable = all(sha(path) == digest for path,digest in pins.items())
    result = dict(passed=done.returncode == 0 and stable,native_exit=done.returncode,
        inputs_unchanged=stable,seconds=time.monotonic()-begin,source_manifest_sha256=args.manifest_sha256,
        hardware_defines=len(definitions),full_soc_lint=False,fpga_qualified=False,gameplay_ipc=None)
    save('closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
