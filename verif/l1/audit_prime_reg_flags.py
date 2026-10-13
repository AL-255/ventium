"""Replay closed register-flag miters/proofs and bind exact sources/models.

Does not qualify the complete core, canonical gates, timing or hardware.
"""
import argparse
import json
from pathlib import Path
import subprocess

import prepare_prime_reg_flags as recipe
import prove_prime_reg_flags as proof
import run_prime_reg_flags_leaf as leaf
from run_parallel_tag_cache import sha


def audit(root, formal):
    start=json.loads((root/'started.json').read_text())
    done=json.loads((root/'closed.json').read_text())
    first=json.loads((formal/'started.json').read_text())
    last=json.loads((formal/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert last['passed'] and last['pins_unchanged']
    assert not done['whole_core_qualified'] and not last['whole_core_proof']
    sources={n:(root/n).read_text() for n in recipe.PARENTS}
    assert recipe.transform(sources)==(root/'candidate_core_mem_chain.svh').read_text()
    owners=[]
    for unit,invocation in (
        ('ventium-prime-reg-leaf-oct13-r3.service','5159aa69568e4982abf1c1367c512827'),
        ('ventium-prime-reg-proof-oct13-r1.service',first['invocation']),
    ):
        state=dict(line.split('=',1) for line in subprocess.check_output([
            'systemctl','--user','show',unit,'-p','InvocationID','-p','MainPID',
            '-p','ExecMainStatus','-p','Result'],text=True).splitlines())
        assert state==dict(InvocationID=invocation,MainPID='0',ExecMainStatus='0',Result='success')
        owners.append(dict(unit=unit,**state))
    expected=[(f'b{b}-r{r}-positive',0,False) for b in (0,1,2) for r in (0,1)]
    expected += [('b2-r1-'+m,1,True) for m in ('stale-alu','stale-shift','wrong-prediction')]
    assert [(r['name'],r['native_exit'],r['expected_failure']) for r in done['rows']]==expected
    pins={**start['pins'],**first['pins'],**last['artifacts']}
    for row in done['rows']:
        folder=root/row['name']
        mutation=row['name'].split('-',2)[2] if row['expected_failure'] else None
        assert (folder/'miter.sv').read_text()==leaf.module(sources,mutation)+leaf.bench()
        pins.update(row['artifacts'])
        binary=folder/'obj/Vtb_prime_reg_flags'
        result=subprocess.run(['taskset','-c','12',binary],capture_output=True,text=True,timeout=5)
        assert result.returncode==row['native_exit']
        # Verilator appends wall-clock speed statistics; compare all semantic
        # output (including the exact mutant failure) before that report.
        def semantic(text):
            return text.split('- S i m u l a t i o n   R e p o r t:',1)[0].strip()
        assert semantic(result.stdout)==semantic(row['coverage'])
        for path in (binary,folder/'obj/Vtb_prime_reg_flags__verFiles.dat'):
            pins[str(path)]=sha(path)
    assert len(last['rows'])==10
    for row in last['rows']:
        path=formal/(row['name']+'.smt2')
        assert path.read_text().startswith(proof.problem(sources,int(row['name'][1])))
        result=subprocess.run(['/usr/bin/z3',path],capture_output=True,text=True,timeout=15)
        assert result.returncode==row['native_exit']==0 and not result.stderr
        assert result.stdout.strip()==row['expected']==row['result']
    for path in (Path(__file__),Path(leaf.__file__),Path(proof.__file__),Path(recipe.__file__),
                 root/'candidate_core_mem_chain.svh',root/'started.json',root/'closed.json',
                 formal/'started.json',formal/'closed.json'):
        pins[str(path.resolve())]=sha(path)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,pins=pins,owners=owners,native_leaf_invocation=start['invocation'],
                comparisons=393216,rejected_mutants=3,smt_queries=10,
                whole_core_qualified=False,timing_measured=False,gameplay_ipc=None)
    with (root/'independent-audit.json').open('x') as stream:json.dump(result,stream,indent=2)
    print('PRIME-REG-AUDIT-OK comparisons=393216 mutants=3 smt_queries=10',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--leaf',required=True,type=Path)
    parser.add_argument('--proof',required=True,type=Path)
    args=parser.parse_args()
    assert __debug__
    audit(args.leaf.resolve(strict=True),args.proof.resolve(strict=True))
