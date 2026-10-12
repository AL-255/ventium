"""Exact full-state/clock A/B and QEMU corpora for paired-intent arbitration."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

from build_pair_intent_core import sha,load,save,stable
from run_next_pair_probe import FIELDS,PATTERN
import prepare_pair_intent as recipe

REPO = Path(__file__).resolve().parents[2]
PARENT_MODEL = '4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ('parent','candidate','out'): ap.add_argument('--'+k,type=Path,required=True)
    args = ap.parse_args()
    parent,candidate = args.parent.resolve(strict=True),args.candidate.resolve(strict=True)
    root = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and not root.exists() and scratch.stat().st_dev != REPO.stat().st_dev
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    pins = {str(p):sha(p) for p in (Path(__file__),Path(recipe.__file__),
        REPO/'verif/l1/build_pair_intent_core.py',REPO/'verif/l1/run_next_pair_probe.py',
        REPO/'verif/l1/run_mc_address_held.py')}
    for folder in (parent,candidate):
        started,closed = load(folder/'build-started.json'),load(folder/'build-closed.json')
        assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
        assert sha(folder/'obj/tb_ventium') == closed['binary_sha256']
        if folder == parent: assert closed['binary_sha256'] == PARENT_MODEL
        else: assert started['changes'] == sorted(recipe.PARENTS)
        pins.update(started['pins'])
        for p in (folder/'build-started.json',folder/'build-closed.json',folder/'obj/tb_ventium'):
            pins[str(p)] = sha(p)
    common = ['--control',str(parent/'obj/tb_ventium'),'--candidate',str(candidate/'obj/tb_ventium')]
    plan = [
        ('load-store','verif/l1/run_l1_write_kind_system.py',[],150),
        ('held','verif/l1/run_next_pair_held.py',[],120),
        ('branch','verif/l1/run_mc_address_branch.py',['--workers','4'],420),
        ('integer','verif/fetchguard/run_probe_core_corpus.py',['--suite','integer','--workers','8'],180),
        ('fp','verif/fetchguard/run_probe_core_corpus.py',
         ['--suite','fp','--workers','8','--kind','1','--offset','0','--offset','31','--operand-offset','0'],120),
        ('agi','verif/l1/run_prime_noack_system.py',['--kind','agi'],270),
        ('ref','verif/l1/run_prime_noack_system.py',['--kind','ref'],270),
        ('agi-store','verif/l1/run_next_pair_agi_store.py',[],150),
    ]
    commands = [(label,['/usr/bin/python3','-B',str(REPO/script),*common,*extra,'--out',str(root/label)],cap)
                for label,script,extra,cap in plan]
    for _,cmd,_ in commands: pins[cmd[2]] = sha(cmd[2])
    assert stable(pins) and shutil.disk_usage(scratch).free > 4*1024**3
    root.mkdir(); save(root/'started.json',dict(pins=pins,commands=commands,invocation=os.environ['INVOCATION_ID']))
    begin = time.monotonic()
    result = dict(passed=False,rows=[],errors=[],coverage={k:0 for k in FIELDS},probe_runs=0,
        gameplay_ipc=None,standard_suite=False,hardware_acceptance=False,canonical_gate_passed=False,
        intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=True)
    try:
        for label,cmd,cap in commands:
            assert shutil.disk_usage(scratch).free > 3*1024**3
            start = time.monotonic()
            with (root/(label+'.log')).open('x') as f:
                native = subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=cap)
            row = dict(label=label,native_exit=native.returncode,seconds=time.monotonic()-start)
            result['rows'].append(row); save(root/(label+'-exit.json'),row)
            assert native.returncode == 0,row
            receipt = root/label/('result.json' if label == 'held' else 'closed.json')
            checked = load(receipt)
            assert checked['passed'] and not checked['errors']
            assert checked['inputs_unchanged' if label == 'held' else 'pins_unchanged']
            row['receipt_sha256'] = sha(receipt)
            print(row,flush=True)
            for p in (root/label).rglob('candidate*.stdout'):
                if not re.fullmatch(r'candidate-(?:lat|l)\d+-cycle(?:-func)?\.stdout',p.name): continue
                matches = PATTERN.findall(p.read_text()); assert len(matches) == 1,p
                counts = dict(zip(FIELDS,map(int,matches[0])))
                assert counts['clocks'] > 0 and counts['retained'] == 0
                result['probe_runs'] += 1
                for k,v in counts.items(): result['coverage'][k] += v
        assert result['probe_runs'] == 4240
        assert result['coverage'] == dict(clocks=21190336,agi=18172,ref=24352,retained=0,
            prime=282808,intent=5616,request=3072,accept=1872,shape_only=1536)
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=stable(pins))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json',result)
    print(result,flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
