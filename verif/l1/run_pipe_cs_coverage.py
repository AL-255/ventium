"""Cold CS-boundary/interior A/B with an independently qualified host observer.

Compare every record and clock across parent, candidate, observer disabled and
observer enabled. Require actual new/held requests, not default trace U labels.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import traceback

import prepare_pipe_mem_cs_fixtures as boundary
import prepare_pipe_cs_interior as interior
from run_pipe_mem_cs_fixtures import grade_native, tracefmt
from run_prime_cs_core import PARENT, CANDIDATE

REPO = boundary.REPO
sha = boundary.sha


def observations(text, kind, is_interior):
    rows = []
    for raw in re.findall(r'^\[CS-OBS\] (.*)$', text, re.M):
        fields = dict(part.split('=') for part in raw.split())
        rows.append({key:int(value, 10 if key == 'cycle' else 16) for key,value in fields.items()})
    assert rows, 'missing target-PC observations'
    assert len({r['cycle'] for r in rows}) == len(rows)
    if is_interior:
        new = [r for r in rows if r['load'] or r['store']]
        assert len(new) == 1, ('new admission',new)
        assert new[0]['load'] == (kind == 0) and new[0]['store'] == (kind == 1)
        assert new[0]['frontend'] and not new[0]['boundary'] and not new[0]['active']
        assert not new[0]['extent_fault']
        commits = [r for r in rows if r['commit']]
        assert len(commits) == 1 and commits[0]['ack']
        assert commits[0]['state'] == new[0]['state']
        held = [r for r in rows if r['active']]
        assert all(r['held_pc'] == 0x8030 and r['state'] == new[0]['state'] for r in held)
        # WBINVD makes the independent data load cold; require registered ownership
        # followed by final-ACK commit. Stores may legitimately post immediately.
        if kind == 0:
            assert held and commits[0]['active'] and any(not r['ack'] for r in held)
        return dict(new_requests=len(new), held_clocks=len(held), commits=len(commits),
                    pipe_state=new[0]['state'])
    assert all(r['boundary'] and not (r['load'] or r['store'] or r['active'] or r['commit']) for r in rows)
    return dict(new_requests=0, held_clocks=0, commits=0, checked_boundary_clocks=len(rows))


def grade_interior(folder, stem, layout):
    text = '\n'.join((folder/(stem+s)).read_text() for s in ('.stdout','.stderr'))
    assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL|\[FAULT\]|CS-OBS-ERROR', text)
    trace = tracefmt.read_trace(str(folder/(stem+'.vtrace')))
    rows = trace.records; want = layout['expected']
    assert 50 < len(rows) < 3000
    assert [r['n'] for r in rows] == list(range(len(rows)))
    assert all(int(r['pc'],0) != layout['symbols']['fail'] for r in rows)
    footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                        r'after (\d+) retired in (\d+) clocks$', text, re.M)
    assert len(footer) == 1 and int(footer[0][0]) == len(rows)
    if stem.endswith('cycle-func'):
        assert trace.hdr.get('sys') is True
        for field,value in dict(eax=0x42, ebp=want['memory'], edi=0, esi=0, cs=8, ss=0x10).items():
            assert int(rows[-1][field],0) == value, (field,rows[-1][field],value)
        assert int(rows[-1]['edx'],0) & 0xffff == 0xf4
        returns = [r for r in rows if int(r['pc'],0) == layout['symbols']['case_return']]
        assert len(returns) == 1 and int(returns[0]['eax'],0) == want['eax']
        assert all(all(key in row for key in tracefmt.SYS_CR) for row in rows)
    else:
        assert any(r.get('pipe') == 'V' and r.get('paired') and 0x8000 <= int(r['pc'],0) < 0x8020 for r in rows)
    return trace, dict(records=len(rows), clocks=int(footer[0][1]))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('boundary','interior','parent','candidate','observer','out'):
        ap.add_argument('--'+name,type=Path,required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    models = {n:getattr(args,n).resolve(strict=True) for n in ('parent','candidate','observer')}
    assert sha(models['parent']) == PARENT and sha(models['candidate']) == CANDIDATE
    observed = json.loads((models['observer'].parent/'closed.json').read_text())
    assert observed['passed'] and observed['pins_unchanged'] and not observed['rtl_rebuilt']
    assert observed['model_sha256'] == CANDIDATE and sha(models['observer']) == observed['binary_sha256']
    pins = dict(observed['pins']); cases = []
    for name,module,count in (('boundary',boundary,12),('interior',interior,6)):
        folder = getattr(args,name).resolve(strict=True)
        before = json.loads((folder/'started.json').read_text())
        done = json.loads((folder/'closed.json').read_text())
        assert done['layout_passed'] and done['pins_unchanged'] and len(done['cases']) == count
        pins.update(before['pins'])
        for receipt in ('started.json','closed.json'): pins[str(folder/receipt)] = sha(folder/receipt)
        for layout in done['cases']:
            want = layout['expected']; keys = ('kind','length','over') if name == 'boundary' else ('kind','length')
            case = tuple(want[k] for k in keys); image = Path(layout['image'])
            assert image.resolve(strict=True).is_relative_to(folder)
            assert sha(image) == layout['image_sha256']
            assert module.audit_image(image.read_bytes(),layout['symbols'],case) == want
            pins[str(image)] = sha(image); cases.append((name,case,layout))
    for p in [Path(__file__).resolve(),Path(interior.__file__),Path(boundary.__file__),
              REPO/'verif/l1/run_pipe_mem_cs_fixtures.py', REPO/'verif/diff/tracefmt.py',
              models['observer'].parent/'closed.json',*models.values()]: pins[str(p)] = sha(p)
    assert all(sha(p) == h for p,h in pins.items())
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],models={k:str(v) for k,v in models.items()}))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_CS_', 'TB_','AXI_','QEMU_'))}
    start = time.monotonic(); result = dict(passed=False,rows=[],errors=[],runs=0,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    try:
        for name,case,layout in cases:
            leaf = root/(name+'-'+'-'.join(map(str,case))); leaf.mkdir()
            for latency in (0,7):
                reference = {}
                for model_name in ('parent','candidate','observer-off','observer-on'):
                    model = models['observer' if model_name.startswith('observer-') else model_name]
                    for mode in ('cycle-func','cycle'):
                        stem = f'{model_name}-l{latency}-{mode}'
                        command = ['timeout','--signal=TERM','--kill-after=3s','20s',str(model),
                            '--system','--cosim','--'+mode,'--l1-axi','--image',layout['image'],
                            '--out',str(leaf/(stem+'.vtrace')),'--max-insn','3000','--max-cycles','3000000',
                            '--quiesce','4096','+ven_faultlog','+ven_seglog']
                        child_env = dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency))
                        if model_name == 'observer-on': child_env['VENTIUM_CS_OBSERVE'] = '1'
                        save(str((leaf/(stem+'.command.json')).relative_to(root)),dict(argv=command,
                             AXI_RLAT=latency,AXI_WLAT=latency,observer=model_name=='observer-on'))
                        with (leaf/(stem+'.stdout')).open('x') as out, (leaf/(stem+'.stderr')).open('x') as err:
                            code = subprocess.run(command,env=child_env,stdout=out,stderr=err).returncode
                        (leaf/(stem+'.exit')).write_text(str(code)+'\n'); result['runs'] += 1
                        assert code == 133, (name,case,stem,code)
                        grade = grade_interior if name == 'interior' else grade_native
                        trace,measure = grade(leaf,stem,layout)
                        actual = (trace.records,measure)
                        if model_name == 'parent': reference[mode] = actual
                        else: assert reference[mode] == actual, (name,case,stem,'observer/model drift')
                        if model_name == 'observer-on':
                            coverage = observations((leaf/(stem+'.stderr')).read_text(),case[0],name=='interior')
                            result['rows'].append(dict(name=name,case=case,latency=latency,mode=mode,**coverage))
                assert [r['pc'] for r in reference['cycle'][0]] == [r['pc'] for r in reference['cycle-func'][0]]
        assert result['runs'] == 288 and len(result['rows']) == 72
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p) == h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k != 'rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
