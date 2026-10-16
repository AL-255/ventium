"""Freeze the existing design for the user's physical overclock experiment.

No RTL, define, synthesis or clock change. Clone the completed project so the
closed timing evidence remains immutable. Reuse the successful bank64 native
implementation monitor, with a stricter 4 GiB live disk reserve. A generated
controller is not a launched run, timing sign-off or hardware acceptance.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve()
OLD = ROOT.parent/'ventium-bank64-implementation.BnulMM'
OUT = ROOT/'parallel-write-implementation-r1'
SYNTH = ROOT/'parallel-write-synthesis-r1'
CLOCK = ROOT/'parallel-write-clock-r1'
REPO = Path('/home/yukidama/github/ventium')
TEMPLATE_SHA = '129919070ee071eeeb39965639c38c263d1e0477575390fb6833115588a02dd5'
LAUNCH_SHA = 'd9aa92c47a54c1e8fe4351c23ee1b32061220f7889a6f180f877c5dbb4de35e6'
DCP_SHA = 'db7f4cbfb804e8d93871cf8ccb8951d24de78d32aa8cc0d9bf2ccaf91b5bea03'
AUDIT_SHA = '7090d98b1112d377c679f1295c26c2a31ffe9e460a58ed7ba20878a9637740a2'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def derive(text):
    assert hashlib.sha256(text.encode()).hexdigest() == TEMPLATE_SHA
    start = text.index('source = Path(')
    end = text.index("scope = 'ventium-vivado.scope'", start)
    text = text[:start]+f'source = root\nrepo = Path({str(REPO)!r})\n'+text[end:]
    start = text.index('# Deliberate manual handoff')
    end = text.index("save('implementation-inputs.json', pins)", start)
    admission = '''# User explicitly requests unchanged-design physical overclock testing.
assert state().get('ActiveState') in ('inactive','failed'), 'never preempt live Vivado'
assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
prepared = json.loads((root/'prepared.json').read_text())
assert prepared['experiment'] == 'unchanged_parallel_write_physical_clock_sweep'
pins = prepared['pins']
assert all(sha(p) == digest for p,digest in pins.items()), 'input drift'
project = root/'project/rk_ao486_system.xpr'
dcp = project.parent/'rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.dcp'
assert sha(dcp) == prepared['dcp_sha256']
assert project.is_file() and not project.is_symlink()
launcher = repo/'fpga/launch_impl_existing.tcl'
assert sha(launcher) == 'e8dc24959c8ccf6ce8ae0e93a9cf838e4a82d9224effcaf45725a2416ad4b7ba'
for p in (Path(__file__),root/'launch.tcl',launcher,root/'prepared.json'):
    pins[str(p)] = sha(p)
assert str(project) in pins and str(dcp) in pins
assert root.stat().st_dev != repo.stat().st_dev
assert shutil.disk_usage(root).free > 8*gib, 'unchanged 8 GiB implementation admission'
assert available()['MemAvailable'] > 22*gib and available()['SwapFree'] > 10*gib
'''
    text = text[:start]+admission+text[end:]
    text = text.replace("source=str(source),audit=str(audit)", "source=str(source),audit=prepared['timing_audit']")
    assert text.count('stop_disk_floor=2*gib') == 1
    assert text.count('if free < 2*gib:') == 1
    text = text.replace('stop_disk_floor=2*gib', 'stop_disk_floor=4*gib')
    text = text.replace('if free < 2*gib:', 'if free < 4*gib:')
    text = text.replace('"""Manually admitted one-family implementation of the completed bank64 synthesis."""',
        '"""Unchanged parallel-write design: user-requested physical clock experiment."""')
    # Preserve the observed single-family lifecycle and every RAM/swap limit.
    for marker in ('memory+swap > 27*gib', "signal_owned(owner,'TERM')",
                   "signal_owned(owner,'KILL')", 'proc.wait(timeout=90)',
                   "VENTIUM_VIVADO_MEMORY_MAX='20G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='8G'",
                   "'--kill-after=60s','6h'", 'host[\'MemAvailable\'] < 2*gib'):
        assert marker in text
    compile(text, '<parallel-implementation>', 'exec')
    return text


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    assert not OUT.exists() and shutil.disk_usage(ROOT).free > 8.5*1024**3
    assert sha(OLD/'run_implementation.py') == TEMPLATE_SHA
    assert sha(OLD/'launch.tcl') == LAUNCH_SHA
    assert sha(CLOCK/'audit.json') == AUDIT_SHA
    pins = {}
    for folder in (SYNTH, CLOCK):
        audit = json.loads((folder/'audit.json').read_text())
        assert audit['passed'] and audit['native_exit'] == 0 and audit['no_oom']
        started = json.loads((folder/'started.json').read_text())
        for group in (started['pins'], audit.get('artifact_pins',{}), audit.get('pins',{})):
            for name,digest in group.items():
                assert name not in pins or pins[name] == digest
                pins[name] = digest
        pins[str(folder/'audit.json')] = sha(folder/'audit.json')
    for name,digest in pins.items(): assert sha(name) == digest, name
    project = SYNTH/'native-synthesis/rk_ao486_system'
    assert sha(project/'rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.dcp') == DCP_SHA
    paths = sorted(p for p in project.rglob('*') if p.is_file())
    assert paths and not any(p.is_symlink() for p in project.rglob('*'))
    assert not (project/'rk_ao486_system.runs/impl_1').exists()
    closure = {str(p.relative_to(project)):sha(p) for p in paths}
    controller = derive((OLD/'run_implementation.py').read_text())
    OUT.mkdir()
    shutil.copytree(project,OUT/'project',copy_function=shutil.copy2)
    assert all(sha(OUT/'project'/name)==digest for name,digest in closure.items())
    for name,digest in closure.items(): pins[str(OUT/'project'/name)] = digest
    for p in (Path(__file__).resolve(),OLD/'run_implementation.py',OLD/'launch.tcl'):
        pins[str(p)] = sha(p)
    for name,text in (('run.py',controller),('launch.tcl',(OLD/'launch.tcl').read_text())):
        with (OUT/name).open('x') as stream: stream.write(text)
        pins[str(OUT/name)] = sha(OUT/name)
    result = dict(experiment='unchanged_parallel_write_physical_clock_sweep',
        pins=pins, dcp_sha256=DCP_SHA, project_clone_sha256=closure,
        timing_audit=str(CLOCK/'audit.json'), timing_audit_sha256=AUDIT_SHA,
        source_rtl_changed=False, defines_changed=False, synthesis_repeated=False,
        core_constraint_mhz=40,pl_constraint_mhz=100,
        known_unplaced_estimate_mhz=35.87958810232859,
        user_requests_physical_overclock_testing=True,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        controller_prepared_not_launched=True,gameplay_ipc=None)
    with (OUT/'prepared.json').open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps(dict(prepared=str(OUT),clone_files=len(closure),pins=len(pins),launched=False)))


if __name__ == '__main__': main()
