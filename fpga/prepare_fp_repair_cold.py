"""Prepare the existing cold Quake flow for the repaired FPGA-source model.

No launch, snapshot or guest edits. Preserve native completion/EOF and source
checks; extend only the host startup task budget and live free-disk guard.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha, span

SCRATCH=Path('/home/yukidama/external/tmp').resolve(strict=True)
PARENT=SCRATCH/'ventium-sfetch16-soc.p8u2t1lA'
MODEL='c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd'
MANIFEST='bf2a944dc6aedaa7ec406fdf5c5607c54d707b8cb04fa25ad88b6ba74fac9b93'
TEMPLATES={
    'run_win95_cold.py':'b97b2bd77595e09e0b622a57ada60a9f378c54b6817fc350496d1c845e03eee3',
    'run_quake_cold.py':'3496c79a1927ac4d0c136595fa22e15bd6f3497bfc1683c9eccadc1cca97c66f',
    'cold-helpers/run_quake_standard.py':'26496df49814dc3885fb347dd066a529f58dc3a8b8feb941e9a297789bffaade',
    'cold-helpers/check_quake_timedemo.py':'427d9e7471eb4d6a65361fc468646307c66df4fe70fe8001e51977307bb85ad7',
}
OLD_MODEL='958f7ec4ab8e5b2e12ccc8e35fec6fd987e1693ef480c5df432ccc6eeda9eff2'


def derive(original, soc, pins):
    helper=original['cold-helpers/run_quake_standard.py']
    helper=replace(helper,'            while process.poll() is None:\n',
        '            while process.poll() is None:\n'
        '                if shutil.disk_usage(out).free < 4 * 1024**3 and not reason:\n'
        '                    reason = "external disk reserve below 4 GiB"\n'
        '                    stop.write_text("disk reserve; not an acceptance marker\\n")\n'
        '                    deadline = min(deadline, time.monotonic() + 30)\n')
    helper_sha=hashlib.sha256(helper.encode()).hexdigest()
    guard=original['run_win95_cold.py'].replace(str(PARENT),str(soc)).replace(OLD_MODEL,MODEL)
    guard=replace(guard,"values['pids.max'] == '32'","values['pids.max'] == '160'")
    # This file supplies only proc/resource/closure helpers to Quake. Its Win95
    # main is deliberately disabled rather than offering an unreviewed launch.
    guard=replace(guard,'    require(len(sys.argv) == 2, \'supply one fresh win95-cold-* leaf\')',
                  "    raise ValueError('resource helper only; Win95 launch not prepared here')")
    guard=span(guard,'PINS = {','TERMINAL = ', 'PINS = {}  # Not used by the Quake resource-only import.\n')
    guard_sha=hashlib.sha256(guard.encode()).hexdigest()
    text=original['run_quake_cold.py'].replace(str(PARENT),str(soc)).replace(OLD_MODEL,MODEL)
    text=replace(text,"'quake-cold-sfetch16-oct10.1'","'quake-cold-fp-repair-oct13.1'")
    text=replace(text,"'ventium-sfetch16-quake-oct10.service'","'ventium-fp-repair-quake-oct13.service'")
    text=replace(text,'CPU, CYCLES, SECONDS = 27,','CPU, CYCLES, SECONDS = 11,')
    text=replace(text,TEMPLATES['run_win95_cold.py'],guard_sha)
    text=replace(text,TEMPLATES['cold-helpers/run_quake_standard.py'],helper_sha)
    pinned = {str(p): h for p,h in pins.items()}
    block='PINS = {Path(p): h for p,h in '+repr(pinned)+'.items()}\n'
    block+='PINS.update({MODEL: MODEL_SHA, DISK: DISK_SHA, GUARD: GUARD_SHA,\n'
    block+='    **{ROMS/n:h for n,h in ROM_SHAS.items()},\n'
    block+='    **{HERE/\'cold-helpers\'/(n+\'.py\'):h for n,h in HELPERS.items()}})\n\n\n'
    text=span(text,'PINS = {','def require(',block)
    # Recheck the complete candidate ledger before copying the simulator/media.
    anchor='    before = guard.resource_receipt()\n'
    text=replace(text,anchor,anchor+'''    frozen = json.loads((HERE / 'build-started.json').read_text())
    closed = json.loads((HERE / 'build-closed.json').read_text())
    require(closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged'] and
            closed['binary_sha256'] == MODEL_SHA, 'candidate build not closed')
    for path, expected in frozen['pins'].items():
        with Path(path).open('rb') as stream:
            require(hashlib.file_digest(stream, 'sha256').hexdigest() == expected, 'candidate input drift: ' + path)
''')
    outputs={'run_win95_cold.py':guard,'run_quake_cold.py':text,
             'cold-helpers/run_quake_standard.py':helper,
             'cold-helpers/check_quake_timedemo.py':original['cold-helpers/check_quake_timedemo.py']}
    for name,code in outputs.items():ast.parse(code,filename=name)
    assert 'values[\'pids.max\'] == \'160\'' in guard
    assert '"--rate", "40000000"' in helper and '"--mem", "16"' in helper
    assert "result.get('result', {}).get('frames') == 969" in text
    assert 'No snapshot' in text
    return outputs


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root==SCRATCH/'ventium-fp-repair-transfer.a8nzrjHu'
    assert Path(os.environ['TMPDIR']).resolve()==SCRATCH
    soc=root/'soc-r1'; manifest=root/'fpga-r1/input-manifest.json'
    assert sha(manifest)==MANIFEST
    assert sha(soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    cm=json.loads((soc/'coremark/audit.json').read_text())
    assert cm['passed'] and cm['model']==MODEL and cm['no_oom'] and cm['all_children_reaped']
    original,pins={},{}
    for name,h in TEMPLATES.items():
        p=PARENT/name;assert sha(p)==h
        original[name]=p.read_text();pins[p]=h
    for p in (soc/'prepared.json',soc/'build-started.json',soc/'build-closed.json',
              soc/'defines.txt',soc/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat',
              soc/'coremark/audit.json',manifest,Path(__file__).resolve()):pins[p]=sha(p)
    outputs=derive(original,soc,pins)
    assert not (root/'cold-prepared.json').exists() and all(not (soc/n).exists() for n in outputs)
    for name,code in outputs.items():
        path=soc/name;path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as f:f.write(code)
    with (root/'cold-prepared.json').open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True,model=MODEL,manifest=MANIFEST,
            inputs={str(p):h for p,h in pins.items()},outputs={str(soc/n):sha(soc/n) for n in outputs},
            cold_reset=True,snapshots=False,guest_patches=False,tasks_max=160,
            cpu=11,memory_max=2*1024**3,swap_max=0,disk_stop_floor=4*1024**3,
            standard_suite=False,hardware_acceptance=False,gameplay_ipc=None),f,indent=2)
    print('Cold Quake prepared; no process launched. Resource-only Win95 helper cannot launch Win95.',flush=True)


if __name__=='__main__':main()
