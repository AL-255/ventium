"""Replay closed cold-system fixtures and require actual immediate V acceptance.

Keep all architectural/cycle records identical to the completed QEMU-checked
matrix. The only new simulator argument enables a passive RTL event witness.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt

MODEL='66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrix',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    matrix=args.matrix.resolve(strict=True); out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert sorted(os.sched_getaffinity(0))==[12]
    closed=json.loads((matrix/'closed.json').read_text())
    start=json.loads((matrix/'started.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    pins=dict(start['pins']); model=Path(start['models']['candidate'])
    assert sha(model)==MODEL
    for path in (Path(__file__).resolve(),matrix/'started.json',matrix/'closed.json'):
        pins[str(path)]=sha(path)
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir(); rows=[]
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    result=dict(passed=False,pins=pins,rows=rows,invocation=os.environ.get('INVOCATION_ID'),
                gameplay_ipc=None,standard_suite=False)
    try:
        for label in ('wide','byte','same-bank','split'):
            leaf=matrix/(label+'-r0-o0')
            elf=leaf/'fixture.elf'; pins[str(elf)]=sha(elf)
            symbols={p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                     if len(p:=line.split())==3 and p[0] != 'U'}
            for latency in (0,7):
                witnesses=[]
                for mode in ('cycle','cycle-func'):
                    name=f'candidate-lat{latency}-{mode}'
                    commandfile=leaf/(name+'.command.json'); oldtrace=leaf/(name+'.vtrace')
                    for path in (commandfile,oldtrace): pins[str(path)]=sha(path)
                    command=json.loads(commandfile.read_text())
                    assert str(model) in command and '--l1-axi' in command and '--'+mode in command
                    index=command.index('--out')+1
                    assert Path(command[index]).resolve()==oldtrace
                    folder=out/f'{label}-lat{latency}-{mode}'; folder.mkdir()
                    path=folder/'rtl.vtrace'; command[index]=str(path)
                    command.append('+ven_pair_now_read_ack_witness')
                    (folder/'command.json').write_text(json.dumps(command,indent=2)+'\n')
                    with (folder/'stdout').open('x') as stdout,(folder/'stderr').open('x') as stderr:
                        native=subprocess.run(command,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                            stdout=stdout,stderr=stderr,timeout=50)
                    assert native.returncode==133,(label,latency,mode,native.returncode)
                    text=(folder/'stdout').read_text()+(folder/'stderr').read_text()
                    assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL',text)
                    current,old=tracefmt.read_trace(str(path)),tracefmt.read_trace(str(oldtrace))
                    assert current.hdr==old.hdr and current.records==old.records
                    events=re.findall(r'^\[PAIR-NOW-READ-ACK\] pc=([0-9a-f]+) vaddr=([0-9a-f]+) byte=([01])$',text,re.M)
                    hot=[r for r in events if int(r[0],16)==symbols['hot_u']]
                    if label in ('wide','byte'):
                        assert len(hot)>=12,(label,latency,mode,'missing immediate accept',hot)
                        assert all(r[2]==('1' if label=='byte' else '0') for r in hot)
                    else:
                        assert not hot,(label,'unsafe immediate pair')
                    witnesses.append(events)
                    rows.append(dict(label=label,latency=latency,mode=mode,native_exit=native.returncode,
                        records=len(current.records),immediate_hot_pairs=len(hot),
                        artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()}))
                assert witnesses[0]==witnesses[1], 'observation mode changed acceptance'
        result['passed']=True
    finally:
        result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
        (out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    assert result['pins_unchanged']
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)


if __name__=='__main__': main()
