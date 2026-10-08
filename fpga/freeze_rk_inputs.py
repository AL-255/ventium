#!/usr/bin/env python3
"""Freeze explicit RK filelist inputs and an already-verified simulator profile.

No RTL discovery/globbing: filelists supply compilation inputs; the simulator's
SHA manifest supplies their include closure. Extra board sources are explicit.
The destination must be a new, empty directory. This does not start Vivado.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', type=Path, required=True)
    p.add_argument('--model-dir', type=Path, required=True)
    p.add_argument('--flow', type=Path, required=True)
    p.add_argument('--template', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    repo, model, out = a.repo.absolute(), a.model_dir.absolute(), a.out.absolute()
    if not out.is_dir() or any(out.iterdir()):
        raise RuntimeError('destination must exist and be empty')
    quake = json.loads((model / 'standard-acceptance/root-quake-closed-pass.json').read_text())
    win95 = json.loads((model / 'standard-acceptance/root-win95-closed-pass.json').read_text())
    model_sha = quake['model_sha256']
    if quake['qualification'] != 'PASS' or win95['status'] != 'PASS':
        raise RuntimeError('both closed simulator component receipts must be PASS')
    if win95['candidate_sha256'] != model_sha:
        raise RuntimeError('component receipts refer to different model builds')
    if digest(model / 'ao486sim_ven_standard') != model_sha:
        raise RuntimeError('model binary differs from the accepted component receipts')
    for line in (model / 'build-output.sha256').read_text().splitlines():
        sha, name = line.split('  ', 1)
        if digest(Path(name)) != sha:
            raise RuntimeError(f'accepted build output changed: {name}')
    pinfile = model / 'compile-inputs.before.sha256'
    pins = {}
    for line in pinfile.read_text().splitlines():
        sha, name = line.split('  ', 1)
        src = Path(name)
        if not src.is_absolute():
            src = repo / src
        # This build's resource guard is deliberately being tightened. It is
        # a host launcher, not an RTL/simulator compilation input.
        if src == repo / 'tools/build_scope.sh':
            continue
        if digest(src) != sha:
            raise RuntimeError(f'verified source pin changed: {src}')
        pins[src] = sha
    dat = model / 'Vsystem__verFiles.dat'
    command = next(x for x in dat.read_text().splitlines() if x.startswith('C "'))
    defs = re.findall(r'\+define\+([A-Z][A-Z0-9_]*)', command)
    if len(defs) != 107 or len(set(defs)) != 107:
        raise RuntimeError('expected exact verified 107-define profile')
    defs += ['SYNTHESIS', 'VTM_NO_DPI', 'VEN_ALTSYNCRAM_XPM']
    if any(x in defs for x in ('VEN_CACHE_HALF', 'VEN_IC_NARROWB', 'VEN_UOPCACHE')):
        raise RuntimeError('retired/extra cache experiment in verified profile')
    records = []

    def copy(src, relative, expected=None):
        before = digest(src)
        if expected is not None and before != expected:
            raise RuntimeError(f'changed input during freeze: {src}')
        dst = out / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        if digest(dst) != before or digest(src) != before:
            raise RuntimeError(f'input not stable: {src}')
        records.append({'source': str(src), 'frozen': str(relative),
                        'sha256': before, 'bytes': dst.stat().st_size})

    for name in ('rtl_ven_core.f', 'rtl_ven_soc.f'):
        f = repo / name
        if f not in pins:
            raise RuntimeError(f'filelist absent from verified pins: {f}')
        for line in f.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith(('#', '//', '+')):
                continue
            if repo / line not in pins:
                raise RuntimeError(f'filelist source absent from verified pins: {line}')
    for src, sha in sorted(pins.items()):
        if src.is_relative_to(repo) and src.suffix in ('.sv', '.v', '.svh', '.vh', '.f', '.hex', '.mif'):
            copy(src, Path('ventium') / src.relative_to(repo), sha)
    for name in ('create_project_3mhz_wrapper.tcl', 'launch_impl_existing.tcl',
                 'clk_div32_40mhz.v', 'clk_div32_45mhz.v', 'clk_div32_50mhz.v',
                 'ven_video_capture.sv', 'ven_axi_read_profiler.sv',
                 'ven_axi_write_profiler.sv', 'ven_ddram_axi_posted.sv',
                 'board-tools/ven_board_probe.py',
                 'board-tools/ven_vga_stream_to_video.py'):
        src = repo / 'fpga' / name
        copy(src, Path('ventium/fpga') / name)
    for name in ('hw/create_project.tcl', 'hw/bitstream.xdc', 'hw/led.xdc',
                 'hw/fpatan_mcp.xdc', 'src/ven_ddram_axi.v',
                 'src/ven_mgmt_axil.v', 'src/ven_soc_dbg.sv',
                 'src/ven_ps2_kbd_inject.v', 'src/clk_div32.v',
                 'src/rk_ao486_system_pl.v'):
        copy(a.flow / name, Path('flow') / name)
    copy(a.template / 'board/XCZU15EG_Base_Config.tcl',
         Path('template/board/XCZU15EG_Base_Config.tcl'))
    copy(pinfile, Path('evidence/compile-inputs.before.sha256'))
    copy(dat, Path('evidence/Vsystem__verFiles.dat'))
    for name in ('root-quake-closed-pass.json', 'root-win95-closed-pass.json'):
        copy(model / 'standard-acceptance' / name, Path('evidence') / name)
    (out / 'defines.txt').write_text('\n'.join(defs) + '\n')
    manifest = {'schema': 1, 'model_profile': model_sha[:8], 'model_sha256': model_sha,
                'simulator_defines': 107, 'hardware_additions': defs[-3:],
                'hardware_defines': defs, 'core_mhz': 40,
                'profile_note': 'Win95/Quake simulation PASS; XPM hardware mapping separate',
                'files': records}
    (out / 'input-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'frozen_files': len(records), 'defines': len(defs),
                      'manifest_sha256': digest(out / 'input-manifest.json'),
                      'out': str(out)}))


if __name__ == '__main__':
    main()
