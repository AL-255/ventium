"""Exercise the unchanged core with the next-read/load-store overlap probe.

Reuse full-state QEMU and exact A/B retirement-clock checks. Coverage is
counted from actual hardware predicates, not inferred from fixture names.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

from build_next_pair_probe import MODEL as PARENT_MODEL, sha, load, save, stable

REPO = Path(__file__).resolve().parents[2]
MODEL = '7ce9cfa450ee674e59fc296503153ac9c9fd24b03f52f9175e04bce5eb482f32'
FIELDS = ('clocks','agi','ref','retained','prime','intent','request','accept','shape_only')
PATTERN = re.compile('NEXT-PAIR-PROBE ' + ' '.join(k+r'=(\d+)' for k in FIELDS))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('parent','candidate','out'):
        ap.add_argument('--'+key, type=Path, required=True)
    args = ap.parse_args()
    parent, candidate = args.parent.resolve(strict=True), args.candidate.resolve(strict=True)
    root = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    pins = {str(Path(__file__).resolve()):sha(__file__)}
    for folder, model in ((parent,PARENT_MODEL),(candidate,MODEL)):
        closed = load(folder/'build-closed.json')
        assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
        assert sha(folder/'obj/tb_ventium') == closed['binary_sha256'] == model
        pins.update(load(folder/'build-started.json')['pins'])
        for p in (folder/'build-started.json',folder/'build-closed.json',folder/'obj/tb_ventium'):
            pins[str(p)] = sha(p)
    common = ['--control',str(parent/'obj/tb_ventium'),'--candidate',str(candidate/'obj/tb_ventium')]
    plan = [
        ('load-store','verif/l1/run_l1_write_kind_system.py',[],150),
        ('held','verif/l1/run_mc_address_held.py',[],120),
        ('branch','verif/l1/run_mc_address_branch.py',['--workers','4'],420),
        ('integer','verif/fetchguard/run_probe_core_corpus.py',['--suite','integer','--workers','8'],180),
        ('fp','verif/fetchguard/run_probe_core_corpus.py',
         ['--suite','fp','--workers','8','--kind','1','--offset','0','--offset','31','--operand-offset','0'],120),
    ]
    commands = [(label,['/usr/bin/python3','-B',str(REPO/script),*common,*extra,'--out',str(root/label)],cap)
                for label,script,extra,cap in plan]
    for _,cmd,_ in commands: pins[cmd[2]] = sha(cmd[2])
    assert stable(pins) and shutil.disk_usage(scratch).free > 4*1024**3
    root.mkdir()
    save(root/'started.json',dict(pins=pins,commands=commands,invocation=os.environ['INVOCATION_ID']))
    start = time.monotonic()
    result = dict(passed=False,rows=[],errors=[],coverage={k:0 for k in FIELDS},
                  probe_runs=0,gameplay_ipc=None,hardware_acceptance=False,standard_suite=False,
                  canonical_gate_passed=False,hardware_behavior_changed=False)
    try:
        for label,command,cap in commands:
            assert shutil.disk_usage(scratch).free > 3*1024**3
            begin = time.monotonic()
            with (root/(label+'.log')).open('x') as stream:
                child = subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,
                                       pass_fds=(9,),timeout=cap)
            row = dict(label=label,native_exit=child.returncode,seconds=time.monotonic()-begin)
            result['rows'].append(row); save(root/(label+'-exit.json'),row)
            assert child.returncode == 0, row
            receipt = root/label/('result.json' if label == 'held' else 'closed.json')
            checked = load(receipt)
            assert checked['passed'] and not checked['errors']
            assert checked['inputs_unchanged' if label == 'held' else 'pins_unchanged']
            row['receipt_sha256'] = sha(receipt)
            print(json.dumps(row),flush=True)
        witnesses = []
        for label,_,_ in commands:
            for p in (root/label).rglob('candidate*.stdout'):
                text = p.read_text(); matches = PATTERN.findall(text)
                assert len(matches) == 1, (str(p),'missing probe final')
                counts = dict(zip(FIELDS,map(int,matches[0])))
                assert counts['clocks'] > 0 and counts['retained'] == 0
                result['probe_runs'] += 1
                for key,value in counts.items(): result['coverage'][key] += value
                if counts['shape_only']: witnesses.append(str(p))
        assert result['probe_runs'] > 0
        assert all(result['coverage'][k] > 0 for k in ('agi','ref','prime','intent','request','accept'))
        result['shape_only_witnesses'] = witnesses
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins_unchanged=stable(pins))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
