"""Compose the timing CPU with the qualified retained-input controller/host.

Preparation is source-only. Compilation uses the existing exclusive build
scope; no suite, timing or FPGA acceptance is inherited from either parent.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil

import build_next_ready_soc as cpu
import build_retained_ui_soc as ui
import build_retained_ui_bound_soc as bound

ROOT = cpu.leaf.ROOT
PARENT = ROOT/'next-ready-soc-r1'
UI_PARENT = ROOT/'retained-ui-soc-r3'
PARENT_MODEL = '5945191c453e113cab7e1c4e009ba768f45c39563b840064008608c94e82e72e'
UI_MODEL = '0e25af3b6831e0acc44a0f0faba224f66316be2a499127165a66534893983779'
sha, load, save, stable = cpu.sha, cpu.load, cpu.save, cpu.stable


def check_delta(name, before, after):
    if name == ui.PS2:
        assert hashlib.sha256(before).hexdigest() == ui.host_recipe.PS2_SHA
        assert hashlib.sha256(after).hexdigest() == ui.PS2_SHA
        assert ui.controller_recipe.transform(before.decode()).encode() == after
        return True
    assert before == after, 'unreviewed integration change: '+name
    return False


def prepare(root):
    assert root.parent == ROOT and not root.exists()
    pins = {}; parents = []
    for parent, model in ((PARENT,PARENT_MODEL),(UI_PARENT,UI_MODEL)):
        start, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
        assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
        binary = parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted'
        assert sha(binary) == closed['binary_sha256'] == model
        assert stable(start['pins']); pins.update(start['pins']); parents.append(start)
        for path in (parent/'build-started.json',parent/'build-closed.json',parent/'build.log',binary):
            pins[str(path)] = sha(path)
    before, input_before = parents
    assert before['directed_model'] == cpu.CORE_MODEL and before['changes'] == cpu.CHANGES
    assert len(before['intersecting_rtl_sources']) == 102
    assert input_before['binding_read_wire'] == 'kb_fifo_rdreq'
    for name in ('retained-pc-input-r1','kbd-controller-inhibit-r1','kbd-backpressure-r2'):
        path = ROOT/name
        start, closed, audit = (load(path/n) for n in ('started.json','closed.json','audit.json'))
        assert closed['passed'] and closed['pins_unchanged'] and audit['passed']
        assert not closed['standard_suite'] and closed['gameplay_ipc'] is None
        assert stable(start['pins']) and stable(audit['artifacts'])
        pins.update(start['pins']); pins.update(audit['artifacts'])
        for p in (path/'started.json',path/'closed.json',path/'audit.json'): pins[str(p)] = sha(p)
    source = PARENT/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p) == before['pins'][str(p)] for p in files)
    old_host, accepted_host = Path(before['host']), Path(input_before['host'])
    assert sha(old_host) == ui.host_recipe.MAIN_SHA
    host_text = ui.transform_host(old_host.read_text())
    assert host_text == accepted_host.read_text()
    accepted_headers = accepted_host.parent
    for name in ui.HEADERS:
        text = (ui.host_recipe.HERE/name).read_text()
        if name == 'pc_keyboard_retained.h': text = bound.binding(text)
        assert text == (accepted_headers/name).read_text()
    controller = UI_PARENT/'source'/ui.PS2
    check_delta(ui.PS2,(source/ui.PS2).read_bytes(),controller.read_bytes())
    # Prepare only after all parents/proofs are checked. No object/run copying.
    root.mkdir(); shutil.copytree(source,root/'source')
    shutil.copyfile(controller,root/'source'/ui.PS2)
    changed = [str(p.relative_to(source)) for p in files if check_delta(str(p.relative_to(source)),
               p.read_bytes(),(root/'source'/p.relative_to(source)).read_bytes())]
    assert changed == [ui.PS2]
    host = root/'source/ao486-sim/ven'/('sim_next_ready_ui_'+sha_bytes(str(root).encode())[:12]+'.cpp')
    with host.open('x') as stream: stream.write(host_text)
    for name in ui.HEADERS:
        assert not (host.parent/name).exists()
        shutil.copyfile(accepted_headers/name,host.parent/name)
    command = [s.replace(str(PARENT),str(root)) for s in before['command']]
    mapped_host = str(root/old_host.relative_to(PARENT))
    assert command.count(mapped_host) == 1
    command = [str(host) if s == mapped_host else s for s in command]
    cpu.check_definitions(command,(PARENT/'defines.txt').read_text().splitlines())
    shutil.copyfile(PARENT/'defines.txt',root/'defines.txt')
    for p in (Path(__file__),Path(cpu.__file__),Path(ui.__file__),Path(bound.__file__),
              root/'defines.txt',*(p for p in (root/'source').rglob('*') if p.is_file())):
        pins[str(p.resolve())] = sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,parent=str(PARENT),parent_model=PARENT_MODEL,
        input_parent=str(UI_PARENT),input_parent_model=UI_MODEL,host=str(host),changes=[ui.PS2],
        processor_rtl_changes=[],added_defines=[],host_headers=list(ui.HEADERS),
        directed_core=before['directed_core'],directed_model=before['directed_model'],
        intersecting_rtl_sources=before['intersecting_rtl_sources'],controller_sha256=ui.PS2_SHA,
        binding_read_wire='kb_fifo_rdreq',canonical_gate_passed=False,qualification='UNQUALIFIED',
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        note='Latest timing CPU unchanged; exact retained controller and already-tested native input host. '
             'Public-pin host simulation is not the FPGA MMIO injector or physical UI acceptance.'))


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args(); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root.parent == ROOT and scratch.stat().st_dev != cpu.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        prepare(root); print('Combined next-read/UI source prepared; no compiler or guest launched.'); return 0
    return cpu.base.build(root)


if __name__ == '__main__': raise SystemExit(main())
