"""Build the new-request CS cofactor on the measured PRIME-COHERENCE core.

Only core.sv changes. Retain the 195-source closure, 152 UV-fast definitions,
assertions, unique model-dependent host and actual generated-header audit.
No correctness, performance or FPGA qualification is inherited from the leaf.
"""
import ast
import json
from pathlib import Path
import subprocess

import build_mc_local_core as previous
import prepare_pipe_mem_cs_extent as recipe
import run_pipe_mem_cs_extent_leaf as leaf
from run_intent_ready_pairs import replace
from run_parallel_tag_cache import sha

HERE=Path(__file__).resolve().parent
MODEL='ea3cde2721fd7af43bd4efdeaf8cbe154b803ff74a989a5660588233966b9c6b'
CHANGES=['rtl/core/core.sv']


def admit_leaf(root):
    before=json.loads((root/'started.json').read_text())
    done=json.loads((root/'closed.json').read_text())
    owner=dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show','ventium-prime-cs-leaf-oct13.service',
        '-p','SubState','-p','MainPID','-p','ExecMainStatus','-p','InvocationID'],text=True).splitlines())
    assert owner==dict(SubState='exited',MainPID='0',ExecMainStatus='0',InvocationID=before['invocation'])
    assert done['passed'] and done['pins_unchanged'] and done['checks']==65536
    assert not done['whole_core_qualified'] and not done['timing_measured']
    assert not done['standard_suite'] and done['gameplay_ipc'] is None
    expected=[(f's{s}-f{f}-positive',0,False) for s in (0,1) for f in (0,1)]
    expected += [('s1-f1-lost-limit',1,True),('s1-f1-wrap32',1,True)]
    assert [(r['label'],r['native_exit'],r['expected_failure']) for r in done['profiles']]==expected
    assert [(r['name'],r['result'],r['native_exit']) for r in done['queries']]==[
        (n,v,0) for n,_,v in leaf.QUERIES]
    pins=dict(before['pins'])
    source=[Path(p) for p in pins if p.endswith('/rtl/core/core.sv')]
    assert len(source)==1 and sha(source[0])==recipe.PRIME_PARENT
    old=source[0].read_text(); new=recipe.transform(old)
    for row in done['profiles']:
        pins.update(row['artifacts'])
        code=leaf.module(old,'original')+leaf.module(new,'cofactor',True,
            row['label'].split('-',2)[2] if row['expected_failure'] else None)+leaf.bench()
        assert (root/row['label']/'miter.sv').read_text()==code
    for name,formula,expected_result in leaf.QUERIES:
        path=root/(name+'.smt2')
        assert path.read_text()==leaf.problem()+'(assert '+formula+')\n(check-sat)\n'
        assert (root/(name+'.stdout')).read_text().strip()==expected_result
        for p in (path,root/(name+'.stdout')): pins[str(p)]=sha(p)
    for name in ('started.json','closed.json'): pins[str(root/name)]=sha(root/name)
    assert all(sha(p)==h for p,h in pins.items())
    return pins


def derive():
    text=previous.derive()
    for old,new in (
        (repr(previous.__doc__),repr(__doc__)),
        ('import prepare_mc_local_commit as recipe','import prepare_pipe_mem_cs_extent as recipe'),
        ('import test_mc_local_commit as leaf_gate','import run_pipe_mem_cs_extent_leaf as leaf_gate'),
        ('MODEL='+repr(previous.MODEL),'MODEL='+repr(MODEL)),
        ("    changes={CHANGES[0]:recipe.transform({n:(source/'rtl/core'/n).read_text() for n in recipe.PARENTS})}\n"
         "    assert changes[CHANGES[0]]==(leaf/'core_mem_chain.svh').read_text()",
         "    assert sha(source/CHANGES[0])==recipe.PRIME_PARENT\n"
         "    changes={CHANGES[0]:recipe.transform((source/CHANGES[0]).read_text())}"),
        ("HERE/'build_fp_high_valid_core.py',", "HERE/'build_fp_high_valid_core.py',HERE/'build_mc_local_core.py',"),
        ("host=root/('tb_mc_local_commit_'", "host=root/('tb_prime_cs_'"),
        ('MC-LOCAL-CORE-PREPARED ', 'PRIME-CS-CORE-PREPARED '),
    ):
        text=replace(text,old,new)
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
