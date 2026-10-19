#!/usr/bin/env python3
"""Check or build the source profile of the board-tested 2886d24c image.

Checking never invokes Vivado. Building creates a fresh project: the original
physical layout is not distributed and a new implementation needs acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'fpga/known_good_2886d24c.json'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(root=ROOT, manifest=MANIFEST):
    data = json.loads(manifest.read_text())
    assert data['schema'] == 'ventium-known-good-source-v1'
    for name, expected in data['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError(f'unsafe manifest path: {name}')
        path = root / relative
        if not path.is_file() or path.is_symlink() or sha(path) != expected:
            raise ValueError(f'known-good source mismatch: {name}')
    for name in ('rtl_ven_core.f', 'rtl_ven_soc.f'):
        for raw in (root / name).read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith(('#', '//', '+incdir+')):
                continue
            if line.startswith('+'):
                raise ValueError(f'unexpected filelist option: {line}')
            if line not in data['files'] or not (root / line).is_file():
                raise ValueError(f'unpinned filelist input: {line}')
    defines = (root / 'fpga/known_good_defines.txt').read_text().splitlines()
    if len(defines) != 159 or len(set(defines)) != 159:
        raise ValueError('expected the exact 159-define hardware profile')
    required = {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
                'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTLOAD_BOUNDED',
                'VEN_SYS_FASTSTORE_FLAT', 'VEN_FP_SHARED', 'VEN_FP_PIPE2'}
    if not required.issubset(defines) or {'VEN_CACHE_HALF', 'VEN_IC_NARROWB'} & set(defines):
        raise ValueError('UV/fast-pipe/full-P5-cache contract failed')
    return data


def environment(root, output, vivado_root):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('VEN_', 'VENTIUM_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(output / 'tmp'), VEN_FPGA_JOBS='1',
               VEN_FPGA_CORE_MHZ='40', VEN_FPGA_BUILD_PROFILE='logic_only',
               VEN_FPGA_SKIP_PRESET='1', VEN_FPGA_SOURCE_ROOT=str(root),
               VEN_FPGA_FLOW_ROOT=str(root / 'fpga/rk'),
               VEN_FPGA_DEFINE_FILE=str(root / 'fpga/known_good_defines.txt'),
               VENTIUM_VIVADO_ROOT=str(vivado_root),
               VENTIUM_VIVADO_MEMORY_POLICY='unbounded',
               VENTIUM_VIVADO_LOCK_DIR=str(Path('/tmp')))
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--check', action='store_true', help='hash/filelist check only; no build')
    action.add_argument('--build', action='store_true', help='explicitly start fresh Vivado build')
    parser.add_argument('--output', type=Path, help='new output directory outside the checkout')
    parser.add_argument('--vivado-root', type=Path, help='Vivado 2025.2 directory containing settings64.sh')
    args = parser.parse_args()
    data = verify()
    print(f"SOURCE-CHECK-OK: {len(data['files'])} pinned files, 159 defines, 40 MHz target", flush=True)
    if args.check:
        return
    if args.output is None or args.vivado_root is None:
        parser.error('--build requires --output and --vivado-root')
    output, vendor = args.output.expanduser().resolve(), args.vivado_root.expanduser().resolve()
    if output == ROOT or ROOT in output.parents or output.exists():
        parser.error('--output must be a new directory outside the checkout')
    if not (vendor / 'settings64.sh').is_file() or not (vendor / 'bin/vivado').is_file():
        parser.error('invalid Vivado installation directory')
    if not output.parent.is_dir() or shutil.disk_usage(output.parent).free < 8 * 1024**3:
        parser.error('output parent must exist and have at least 8 GiB free')
    # No checkpoint, prebuilt IP cache, private submodule or guest media input.
    command = ['timeout', '--signal=TERM', '--kill-after=60s', '8h',
               str(ROOT / 'fpga/run_vivado_exclusive.sh'), '-mode', 'batch', '-notrace',
               '-log', str(output / 'native.log'), '-journal', str(output / 'native.jou'),
               '-source', str(ROOT / 'fpga/launch_programmable_clock.tcl'),
               '-tclargs', 'all', str(output / 'build')]
    output.mkdir()
    (output / 'tmp').mkdir()
    receipt = dict(command=command, source_manifest_sha256=sha(MANIFEST),
                   reference_image=data['reference_bitstream_sha256'],
                   inputs=dict(data['files']), hardware_acceptance=False,
                   timing_signoff=False, gameplay_ipc=None)
    (output / 'started.json').write_text(json.dumps(receipt, indent=2) + '\n')
    code = subprocess.call(command, cwd=output, env=environment(ROOT, output, vendor))
    changed = [n for n, h in data['files'].items() if not (ROOT/n).is_file() or sha(ROOT/n) != h]
    products = {p.name: sha(p) for p in (output / 'build').glob('*.bit*') if p.is_file()}
    complete = (output / 'native.log').is_file() and 'PROGRAMMABLE-CLOCK-BUILD-COMPLETE' in (output / 'native.log').read_text(errors='replace')
    passed = code == 0 and not changed and complete and len(products) == 2
    (output / 'closed.json').write_text(json.dumps(dict(native_exit=code,
        source_changed=changed, products=products, build_completed=passed,
        hardware_acceptance=False, timing_signoff=False, gameplay_ipc=None), indent=2) + '\n')
    print('BUILD-COMPLETE; inspect timing and validate on board' if passed else 'BUILD-FAILED; retain native.log')
    sys.exit(0 if passed else 1)


if __name__ == '__main__':
    main()
