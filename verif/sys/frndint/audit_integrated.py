"""Check all cold FRNDINT retire states; retain the private-QEMU disagreement."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time

REPO=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt

def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def load(p):return json.loads(p.read_text())


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--run',type=Path,required=True)
    a=ap.parse_args();root=a.run.resolve(strict=True)
    assert __debug__ and os.sched_getaffinity(0)=={12} and not(root/'audit.json').exists()
    started,closed=load(root/'started.json'),load(root/'closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert all(sha(p)==h for p,h in started['pins'].items())
    owner=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',
        'ventium-frndint-integrated-oct13-r2.service','-p','MainPID','-p','ExecMainStatus','-p','InvocationID'],text=True).splitlines())
    assert owner==dict(MainPID='0',ExecMainStatus='0',InvocationID=started['invocation'])
    rows=load(root/'cases.json');assert len(rows)==412
    r=tracefmt.read_trace(str(root/'repaired.vtrace')).records
    assert len(r)==11129 and int(r[-1]['pc'],16)==0x8048067
    assert int(r[-1]['ebx'],16)==0 and int(r[-1]['ebp'],16)==412
    indices=[i for i,v in enumerate(r) if int(v['pc'],16)==0x804800b]
    assert len(indices)==412
    for index,(case,expected) in zip(indices,rows):
        before,after=r[index-1],r[index]
        assert int(before['pc'],16)==0x8048009
        assert int(before['fctrl'],16)==case['cw'] and int(after['fctrl'],16)==case['cw']
        assert int(before['st0'],16)==case['hi']<<64|case['m']
        assert int(after['st0'],16)==expected[0]|expected[1]<<32|expected[2]<<64
        assert (int(after['fstat'],16)^expected[3])&0x82ff==0
        assert all(after['st'+str(j)]==before['st'+str(j)] for j in range(1,8))
    native=subprocess.run([root/'test.elf'],capture_output=True,timeout=15)
    assert native.returncode==0 and not native.stdout and not native.stderr
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    qemu=scratch/'ventium-qemu-c1.Mw2HgVmG/build-r1/build/qemu-i386'
    assert sha(qemu)=='01510a0f2592ab0f21306596a70160b3f31b6fbc0f8a0952dcf5bc322021c8e4'
    q=subprocess.run([qemu,'-cpu','pentium',root/'test.elf'],capture_output=True,timeout=15)
    assert q.returncode==4 and not q.stdout and not q.stderr
    command=[sys.executable,'-B',str(REPO/'verif/qemu-trace/gen_trace.py'),'--qemu',str(qemu),
        '--elf',str(root/'test.elf'),'--out',str(root/'private-qemu.vtrace'),
        '--max-insn','50000','--port','42483','--x87']
    with (root/'private-qemu.log').open('x') as f:
        done=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=45,
            env=dict(os.environ,VTM_QEMU_GDB_PREEXIT='1',TMPDIR=str(root)))
    assert done.returncode==0
    qt=tracefmt.read_trace(str(root/'private-qemu.vtrace')).records
    assert len(qt)==27 and int(qt[-1]['ebx'],16)==4 and int(qt[-1]['ebp'],16)==0
    assert qt[4]['pc']=='0x0804800b' and qt[4]['fstat']=='0x4520'
    assert r[4]['fstat']=='0x4522' and qt[4]['st0']==r[4]['st0']
    assert all(sha(p)==h for p,h in started['pins'].items())
    artifacts={str(p):sha(p) for p in root.iterdir() if p.is_file()}
    artifacts[str(Path(__file__))]=sha(__file__);artifacts[str(qemu)]=sha(qemu)
    result=dict(passed=True,owner=owner,cold_core_cases=412,full_records=11129,
        native_program_exit=0,repaired_guest_exit=0,parent_guest_exit=4,
        private_qemu_guest_exit=4,private_qemu_trace_producer_exit=0,
        private_qemu_failure=dict(pc='0x0804800b',input='00000000000000000001',
            cw='0x037f',expected_fsw='0x4522',actual_fsw='0x4520',missing='denormal operand flag'),
        artifacts=artifacts,full_qemu_differential_pass=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'},indent=2))


if __name__=='__main__':main()
