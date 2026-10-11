#!/usr/bin/env python3
"""Retry a terminal pre-launch disk rejection without changing any guard or RTL."""
import ast
import json
import os
from pathlib import Path
import shutil
import subprocess

from prepare_fragment_exact_timing import sha, replace

REPO=Path(__file__).resolve().parents[1]
scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
root=scratch/'ventium-mc-read-commit.PNi1O0xm'
assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
def load(p):return json.loads(p.read_text())
def state(unit):
    return dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
        '-pInvocationID','-pMainPID','-pSubState','-pExecMainStatus'],text=True).splitlines())
failed=state('ventium-mc-read-synth-oct11.service')
assert failed==dict(InvocationID='e66afabbb14f416da9730d01864cf32f',MainPID='0',SubState='failed',ExecMainStatus='1')
queue=state('ventium-mc-read-timing-queue-oct11.service')
assert queue==dict(InvocationID='8155476807884799bcf17b3fedb07fe0',MainPID='0',SubState='failed',ExecMainStatus='1')
assert not (root/'synthesis/started.json').exists() and not (root/'synthesis/native-synthesis').exists()
assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
assert load(root/'soc-r1/coremark/audit.json')['passed']
assert load(root/'soc-queue-r1/closed.json')['passed']
prepared=load(root/'timing-prepared.json')
assert all(sha(Path(p))==h for p,h in {**prepared['template_pins'],**prepared['outputs']}.items())
# Check the SAME growth-derived requirement that blocked R1, not a lower floor.
prior=scratch/'ventium-l1-write-kind.sxvBsfBb/synthesis'
growth=load(prior/'started.json')['disk_admission']-min(
    json.loads(s)['disk_free'] for s in (prior/'watch.jsonl').read_text().splitlines())
free=shutil.disk_usage(root).free;gib=1024**3
assert 0<growth<2*gib and free>6*gib and free-4*gib>2*growth
sources={name:(root/name).read_text() for name in (
    'synthesis/run.py','synthesis/audit_closed.py','clock/run.py','clock/audit_closed.py',
    'clock/audit.tcl','after_prepare_synth.py')}
outputs={}
for name in ('synthesis/run.py','synthesis/audit_closed.py','clock/run.py','clock/audit_closed.py'):
    text=sources[name]
    for label in ('synth','clock'):
        text=text.replace('ventium-mc-read-'+label+'-oct11.service',
                          'ventium-mc-read-'+label+'-r2-oct11.service')
    if name=='synthesis/run.py':
        text=replace(text,"load_proof('timing-prepared.json')",
            "load_proof('timing-prepared.json')\nload_proof('timing-retry-prepared.json')")
    elif name=='clock/run.py':
        text=replace(text,"synthesis = root.parent/'synthesis'","synthesis = root.parent/'synthesis-r2'")
    if name.endswith('/run.py'):
        boundary='owner = None\n'
        assert text[text.index(boundary):]==sources[name][sources[name].index(boundary):]
        for guard in ("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                      'if free < 4*gib:','memory+swap > 13*gib','min(host.values()) < 2*gib'):
            assert guard in text
    directory,leaf=name.split('/',1)
    outputs[directory+'-r2/'+leaf]=text
outputs['clock-r2/audit.tcl']=sources['clock/audit.tcl']
text=sources['after_prepare_synth.py']
text=replace(text,"work=root/'timing-queue'","work=root/'timing-queue-r2'")
text=replace(text,"unit='ventium-mc-read-'+label+'-oct11.service'","unit='ventium-mc-read-'+label+'-r2-oct11.service'")
text=replace(text,"directory='synthesis' if label=='synth' else 'clock'",
                  "directory='synthesis-r2' if label=='synth' else 'clock-r2'")
text=text.replace("'synthesis/","'synthesis-r2/").replace("'clock/","'clock-r2/")
outputs['after_prepare_synth_r2.py']=text
assert not (root/'timing-retry-prepared.json').exists()
for name,text in outputs.items():
    assert not (root/name).exists()
    if name.endswith('.py'):ast.parse(text,filename=name)
for name,text in outputs.items():
    path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('x') as f:f.write(text)
journal=subprocess.check_output(['journalctl','--user','-u','ventium-mc-read-synth-oct11.service',
    '--no-pager','-o','cat'],text=True)
assert 'assert shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth' in journal
with (root/'synthesis/admission-failure.log').open('x') as f:f.write(journal)
pins={str(root/name):sha(root/name) for name in sources}
for p in (Path(__file__),REPO/'fpga/prepare_fragment_exact_timing.py',
          root/'timing-prepared.json',root/'timing-queue/closed.json',root/'synthesis/admission-failure.log',
          root/'soc-r1/coremark/audit.json'):pins[str(p)]=sha(p)
record=dict(passed=True,controllers_generated_not_launched=True,failed_owner=failed,failed_queue=queue,
    reason='original growth-derived disk guard rejected R1 before native launch; disk reclaimed, no guard changed',
    disk_free=free,matched_parent_growth=growth,required_disk_bytes=max(6*gib,4*gib+2*growth),
    pins=pins,outputs={str(root/name):sha(root/name) for name in outputs},
    unchanged_guard_lifecycle=True,source_manifest_sha256=prepared['source_manifest_sha256'],
    model_sha256=prepared['model_sha256'],canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False)
with (root/'timing-retry-prepared.json').open('x') as f:json.dump(record,f,indent=2)
print(json.dumps({k:v for k,v in record.items() if k not in ('pins','outputs')},indent=2))
