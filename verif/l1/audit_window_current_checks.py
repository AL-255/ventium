"""Reuse complete regression grading for the exact saved-window candidate."""
import ast
import hashlib
from pathlib import Path

REPO=Path(__file__).resolve().parents[2]
SOURCE=REPO/'verif/sys/fp_env_store/audit_write_regressions.py'
SOURCE_SHA='a343f8d1f8eb67218793f7b9ed72002938e3cc781920a5d9c6fed0bf8d6eda72'


def derive():
    text=SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest()==SOURCE_SHA
    replacements=[
        ('REPO=Path(__file__).resolve().parents[3]','REPO=Path(__file__).resolve().parents[2]',1),
        ("core,func,parent=root/'env-write-core-r1',root/'env-write-func-r1',root/'core-r1'",
         "core,func,parent=root/'window-current-core-r1',root/'window-current-func-r1',root/'env-write-core-r1'",1),
        ("'ventium-env-write-'+label","'ventium-window-current-'+label",1),
        ("'env-write-'+label","'window-current-'+label",2),
        ('360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779',
         '737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',1),
        ("with (root/'env-write-regression-audit.json').open('x')",
         "with (root/'window-current-regression-audit.json').open('x')",1),
        ("root/'audit.json'","root/'env-write-regression-audit.json'",3),
        ("root/'func-r1/work'","root/'env-write-func-r1/work'",1),
        ('parent_paired==30134','parent_paired==30132',1),
        ("    assert sorted(pair_deltas,key=lambda r:r['name'])==[\n"
         "        dict(name='tx_fenv',parent_v=4,candidate_v=3,parent_clocks=200760,candidate_clocks=200760),\n"
         "        dict(name='tx_fsave',parent_v=3,candidate_v=2,parent_clocks=201526,candidate_clocks=201320)]",
         '    assert not pair_deltas',1),
        ('    pins={};owners={}',
         '    pins={'+repr(str(SOURCE))+':'+repr(SOURCE_SHA)+'};owners={}',1),
        ('    records=paired=parent_paired=0;unmasked_failures=[];pair_deltas=[]',
         "    replay=root/'window-current-same-input-r1'\n"
         "    rs,rc=load(replay/'started.json'),load(replay/'closed.json')\n"
         "    assert rc['passed'] and rc['pins_unchanged'] and not rc['errors']\n"
         "    assert len(rc['rows'])==108 and rc['records']==80800\n"
         "    props=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',\n"
         "        'ventium-window-current-same-input-oct13-r1.service','-pMainPID','-pSubState',\n"
         "        '-pExecMainStatus','-pInvocationID'],text=True,timeout=5).splitlines())\n"
         "    assert props==dict(MainPID='0',SubState='exited',ExecMainStatus='0',InvocationID=rs['invocation'])\n"
         "    owners['same_input']=props;pins.update(rs['pins'])\n"
         "    for row in rc['rows']:\n"
         "        assert row['passed'] and row['counts']['parent']==row['counts']['candidate']\n"
         "        assert len(row['native'])==2\n"
         "        assert all(r['native_exit']==0 and r['actual_wait'] and r['affinity_verified'] and r['error'] is None for r in row['native'])\n"
         "    pins.update({str(p):sha(p) for p in replay.rglob('*') if p.is_file()})\n"
         '    records=paired=parent_paired=0;unmasked_failures=[];pair_deltas=[]',1),
        ('        records+=len(r.records)',
         "        old_trace=replay/name/'parent.vtrace'\n"
         "        new_trace=replay/name/'candidate.vtrace'\n"
         '        assert r.records==tracefmt.read_trace(str(old_trace)).records==tracefmt.read_trace(str(new_trace)).records\n'
         '        records+=len(r.records)',1),
        ('        before=old_log.read_text();old_v=',
         "        assert re.search(r'^  clocks\\s+(\\d+)',log,re.M)[1]==re.search(r'^  clocks\\s+(\\d+)',old_log.read_text(),re.M)[1]\n"
         '        before=old_log.read_text();old_v=',1)]
    for before,after,count in replacements:
        assert text.count(before)==count,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
