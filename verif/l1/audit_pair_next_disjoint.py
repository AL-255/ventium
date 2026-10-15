"""Regrade the exact candidate, preserving canonical failures as failures."""
import ast
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys

import audit_current_u_pair_cold_alias as cold_support
import prepare_pair_next_disjoint as recipe

REPO = Path(__file__).resolve().parents[2]
DATA = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve()
MODEL = '9beb7023ddfd56888fe6eac6b12ed2feebdbcb7fc367748a989fcb2b63292516'
sha = cold_support.sha
load = lambda p: json.loads(p.read_text())


def audit_cold():
    root = DATA/'pair-next-disjoint-coldalias-r1'
    started,closed = [load(root/n) for n in ('started.json','closed.json')]
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert len(closed['measurements']) == 144
    bindings = load(root.with_suffix('.inputs.json'))
    assert all(sha(p)==h for p,h in {**started['pins'],**bindings}.items())
    cases = sorted(p for p in root.iterdir() if p.is_dir())
    assert len(cases)==36
    records=first_pairs=comparisons=0
    for leaf in cases:
        symbols = {p[2]:int(p[0],16) for line in subprocess.check_output(
            ['nm','-n',leaf/'fixture.elf'],text=True).splitlines()
            if len(p:=line.split())==3 and p[0]!='U'}
        golden = cold_support.tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert load(leaf/'golden.exit.json')['native_exit']==0
        assert load(leaf/'free-qemu.exit.json')['native_exit']==133
        for latency in (0,7):
            traces={}
            for label in ('control','candidate'):
                for mode in ('cycle-func','cycle'):
                    stem=f'{label}-lat{latency}-{mode}'
                    command=load(leaf/(stem+'.command.json'))
                    assert started['models'][label] in command
                    assert '--'+mode in command and '--l1-axi' in command
                    assert not any('snapshot' in a or 'dbg-bp' in a or 'step' in a for a in command)
                    assert load(leaf/(stem+'.exit.json'))['native_exit']==133
                    trace=cold_support.tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
                    stdout,stderr=[(leaf/(stem+'.'+ext)).read_text() for ext in ('stdout','stderr')]
                    assert not cold_support.native.FATAL.search(stdout+stderr)
                    cold_support.check_faultlog.check_counts(
                        cold_support.check_faultlog.read_counts(stdout.splitlines()),{})
                    if mode=='cycle-func':
                        cold_support.native.grade_native(trace,stdout,stderr,133,133,2000)
                        output=io.StringIO()
                        assert cold_support.compare.compare_func(golden,trace,False,0xffffffff,
                            False,20,output,sys_both=True)==0,output.getvalue()
                        comparisons+=1
                    elif label=='candidate':
                        events=[r for r in trace.records if int(r['pc'],0)==symbols['hot_load']]
                        assert len(events)==16 and events[0]['paired'] and events[0]['pipe']=='V'
                        first_pairs+=1
                    traces[label,mode]=trace.records
            for mode in ('cycle-func','cycle'):
                assert traces['control',mode]==traces['candidate',mode]
            records+=len(traces['candidate','cycle-func'])
    assert (records,comparisons,first_pairs)==(15840,144,72)
    return dict(cases=36,latencies=[0,7],comparisons=72,complete_qemu_comparisons=144,
                candidate_records=records,first_v_pairs=first_pairs,cycle_delta=0)


def derive():
    original=REPO/'verif/fe_pipe/audit_fetch_fragment_owned.py'
    source=original.read_text()
    for old,new in (
        ("replay = root/'fetch-fragment-owned-same-input-r1'", "replay = root/'pair-next-disjoint-replay-r1'"),
        ("core = root/'fetch-fragment-core-r1'", "core = root/'pair-next-disjoint-core-r1'"),
        ('assert sha(core/\'obj/tb_ventium\') == fs[\'model\'] == MODEL',
         f"assert sha(core/'obj/tb_ventium') == {MODEL!r}\n    assert fs['model'] == MODEL"),
        ("root/'fetch-fragment-regression-audit.json'", "root/'pair-next-disjoint-regression-audit.json'"),
        ('physical_board=False, gameplay_ipc=None)',
         'physical_board=False, gameplay_ipc=None, candidate_fresh_qemu=False,\n'
         '        authenticated_input_replay=True, pending_translation=audit_cold())'),
    ):
        source=recipe.once(source,old,new)
    anchor="    pins = dict(fs['pins'])"
    addition=f"\n    pins[{str(original)!r}]={sha(original)!r}"
    # Independently bind the complete three-file source delta, including
    # the integrated parameter selection and every original build input.
    addition+='''
    build=load(core/'build-started.json')
    built=load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert len(build['definitions'])==152 and '--assert' in ' '.join(build['command'])
    assert not {'SYNTHESIS','VEN_P54_DUAL_LOAD_PRIME','VEN_P54_STORE_LOAD_PAIR'} & set(build['definitions'])
    pins.update(build['pins'])
    source=parent/'candidate'
    names=sorted(str(p.relative_to(source)) for p in source.rglob('*') if p.is_file())
    assert len(names)==195
    assert names==sorted(str(p.relative_to(core/'candidate')) for p in (core/'candidate').rglob('*') if p.is_file())
    assert sorted(n for n in names if sha(source/n)!=sha(core/'candidate'/n))==sorted(recipe.PARENTS)
    for name in recipe.PARENTS:
        assert (core/'candidate'/name).read_text()==recipe.transform((source/name).read_text(),name)
    for folder in ('pair-next-disjoint-leaf-r6','pair-next-disjoint-load-r1',
                   'pair-next-disjoint-store-r1','pair-next-disjoint-coldalias-r1'):
        receipt=load(root/folder/'closed.json')
        assert receipt['passed'] and receipt['pins_unchanged'] and not receipt['errors']
    for filename in ('build-started.json','build-closed.json','prepared.json'):
        pins[str(core/filename)]=sha(core/filename)
'''
    source=recipe.once(source,anchor,anchor+addition)
    source=recipe.once(source,'    artifacts = {str(path): sha(path)',
        "    extra_artifacts={str(p):sha(p) for p in (root/'pair-next-disjoint-coldalias-r1').rglob('*') if p.is_file()}\n"
        '    artifacts = {str(path): sha(path)')
    source=recipe.once(source,'    report = dict(audit_passed=True,',
        '    artifacts.update(extra_artifacts)\n'
        '    for path in (original,Path(recipe.__file__),Path(cold_support.__file__)):\n'
        '        artifacts[str(path)]=sha(path)\n'
        '    report = dict(audit_passed=True,')
    ast.parse(source)
    return original,source


if __name__=='__main__':
    sys.path.insert(0,str(REPO/'verif/fe_pipe'))
    original,source=derive()
    exec(compile(source,str(__file__),'exec'),globals())
