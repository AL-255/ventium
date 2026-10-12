"""Cover AGI/reference hint producers and reject the shape-only timing cut."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

from run_next_pair_probe import MODEL, PARENT_MODEL, PATTERN, FIELDS, REPO, sha, load, save, stable


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ('parent','candidate','out'): ap.add_argument('--'+k,type=Path,required=True)
    args = ap.parse_args()
    parent,candidate = args.parent.resolve(strict=True),args.candidate.resolve(strict=True)
    root = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    pins = {}
    for folder,model in ((parent,PARENT_MODEL),(candidate,MODEL)):
        closed = load(folder/'build-closed.json')
        assert closed['passed'] and closed['native_exit'] == 0 and closed['pins_unchanged']
        assert sha(folder/'obj/tb_ventium') == closed['binary_sha256'] == model
        pins.update(load(folder/'build-started.json')['pins'])
        for p in (folder/'build-closed.json',folder/'build-started.json',folder/'obj/tb_ventium'):
            pins[str(p)] = sha(p)
    for p in (Path(__file__).resolve(),REPO/'verif/l1/run_next_pair_probe.py',
              REPO/'verif/l1/run_prime_noack_system.py',REPO/'verif/l1/run_next_pair_agi_store.py',
              REPO/'verif/l1/run_l1_write_kind_system.py'):
        pins[str(p)] = sha(p)
    assert stable(pins) and shutil.disk_usage(scratch).free > 3*1024**3
    root.mkdir()
    common = ['--control',str(parent/'obj/tb_ventium'),'--candidate',str(candidate/'obj/tb_ventium')]
    plan = [(k,REPO/'verif/l1/run_prime_noack_system.py',['--kind',k]) for k in ('agi','ref')]
    plan += [('agi-store',REPO/'verif/l1/run_next_pair_agi_store.py',[])]
    commands = [(k,['python3','-B',str(script),*common,*extra,'--out',str(root/k)])
                for k,script,extra in plan]
    save(root/'started.json',dict(pins=pins,commands=commands,invocation=os.environ['INVOCATION_ID']))
    start = time.monotonic()
    result = dict(passed=False,rows=[],errors=[],probe_runs=0,coverage={k:0 for k in FIELDS},
                  hardware_behavior_changed=False,standard_suite=False,gameplay_ipc=None)
    try:
        for k,command in commands:
            begin = time.monotonic()
            with (root/(k+'.log')).open('x') as stream:
                p = subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=270)
            row = dict(label=k,native_exit=p.returncode,seconds=time.monotonic()-begin)
            result['rows'].append(row); save(root/(k+'-exit.json'),row)
            assert p.returncode == 0,row
            done = load(root/k/'closed.json')
            assert done['passed'] and done['pins_unchanged'] and not done['errors']
        witnesses = []
        for k,_ in commands:
            for p in (root/k).rglob('candidate*.stdout'):
                if not re.fullmatch(r'candidate-(?:lat|l)\d+-cycle(?:-func)?\.stdout',p.name):
                    continue
                matches = PATTERN.findall(p.read_text()); assert len(matches) == 1,str(p)
                counts = dict(zip(FIELDS,map(int,matches[0])))
                assert counts['clocks'] and counts['retained'] == 0
                result['probe_runs'] += 1
                for key,value in counts.items(): result['coverage'][key] += value
                if counts['shape_only'] and p.name == 'candidate-lat0-cycle.stdout': witnesses.append(p)
        assert all(result['coverage'][k] > 0 for k in ('agi','ref','prime','intent','request','accept','shape_only'))
        witness = sorted(witnesses)[0]
        assert re.search(r'NEXT-PAIR-SHAPE pc=[0-9a-f]+ load=0 agi=1',witness.read_text())
        command = load(witness.with_suffix('.command.json'))
        assert str(candidate/'obj/tb_ventium') in command
        # Preserve the image and invocation, but put the negative run's trace in
        # its own path. Never overwrite the successful positive witness.
        command[command.index('--out')+1] = str(root/'shape-only-negative.vtrace')
        command.append('+next_pair_reject_shape')
        save(root/'shape-only-negative-command.json',command)
        with (root/'shape-only-negative.log').open('x') as stream:
            p = subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,
                env=dict(os.environ,AXI_RLAT='0',AXI_WLAT='0'),timeout=60)
        log = (root/'shape-only-negative.log').read_text()
        assert p.returncode != 133 and p.returncode != 0
        assert 'NEXT-PAIR-BROAD: shape-only exclusion loses a real hint' in log
        result['negative'] = dict(native_exit=p.returncode,witness=str(witness),
            log_sha256=sha(root/'shape-only-negative.log'),expected_failure=True)
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins_unchanged=stable(pins))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
