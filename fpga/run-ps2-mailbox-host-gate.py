#!/usr/bin/env python3
"""Test the real Python host adapter against native mailbox RTL, serial BFM.

No /dev/mem, FPGA, processor, AXI management bridge or physical PS/2 access.
This small Icarus build is not a full-core build or FPGA acceptance.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import time


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    repo=Path(__file__).resolve().parents[1]
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    out=args.out.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert out.parent==scratch and not list(out.iterdir())
    assert shutil.disk_usage(out).free>4*1024**3
    paths=[repo/'fpga'/n for n in ('ven_ps2_mailbox.sv','tb_ps2_mailbox_host.sv',
        'board-tools/ven_ps2_mouse.py','board-tools/ven_ps2_mailbox_host.py')]
    pins={str(p):sha(p) for p in paths+[Path(__file__).resolve()]}
    tools={name:str(Path(shutil.which(name)).resolve(strict=True)) for name in ('iverilog','vvp')}
    pins.update({p:sha(p) for p in tools.values()})
    for p in paths: shutil.copyfile(p,out/p.name)
    sys.path.insert(0,str(out))
    import ven_ps2_mailbox_host as adapter
    assert Path(adapter.__file__).resolve()==out/'ven_ps2_mailbox_host.py'
    assert len(os.sched_getaffinity(0))==1, 'explicit single-CPU test admission required'
    build=[tools['iverilog'],'-g2012','-s','tb_ps2_mailbox_host','-o',str(out/'test.vvp'),
           str(out/'ven_ps2_mailbox.sv'),str(out/'tb_ps2_mailbox_host.sv')]
    before=dict(pins=pins,build=build,affinity=sorted(os.sched_getaffinity(0)),
        invocation=os.environ.get('INVOCATION_ID'),scope='actual mailbox RTL; serial BFM; no MMIO/AXI/wire/guest')
    (out/'started.json').write_text(json.dumps(before,indent=2))
    with (out/'build.log').open('xb') as log:
        subprocess.run(build,check=True,stdout=log,stderr=subprocess.STDOUT,timeout=30)
    start=time.monotonic()
    proc=subprocess.Popen([tools['vvp'],str(out/'test.vvp')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT,bufsize=0)
    selector=selectors.DefaultSelector(); selector.register(proc.stdout,selectors.EVENT_READ)
    buffer=b''; requests=0; actions=[]
    native=dict(pid=proc.pid,affinity=sorted(os.sched_getaffinity(proc.pid)),
        exe=str((Path('/proc')/str(proc.pid)/'exe').resolve(strict=True)))
    assert native['affinity']==before['affinity'] and native['exe']==tools['vvp']
    with (out/'native.log').open('xb') as log:
        def line():
            nonlocal buffer
            deadline=min(start+60,time.monotonic()+5)
            while b'\n' not in buffer:
                remaining=deadline-time.monotonic()
                if remaining<=0 or not selector.select(remaining): raise TimeoutError('mailbox native response')
                data=os.read(proc.stdout.fileno(),65536)
                if not data: raise RuntimeError('unexpected native EOF: '+repr(buffer))
                log.write(data); log.flush(); buffer+=data
            value,buffer=buffer.split(b'\n',1)
            return value.decode()
        def command(op,address=0,value=0):
            nonlocal requests
            requests+=1
            proc.stdin.write(f'{op} {address:x} {value:x}\n'.encode())
            proc.stdin.flush()
            return line()
        def read(index):
            response=command(1,index)
            assert response.startswith('READ '),response
            return int(response[5:],16)
        hook=None
        def write(index,value):
            nonlocal hook
            if hook:
                callback,hook=hook,None
                callback(index,value)
            assert command(2,index,value)=='OK'
        def reset(value): assert command(5,0,value)=='OK'
        now=0
        def poll(expected):
            nonlocal now
            now+=1
            result=host.poll(now)
            assert result==expected,(result,expected)
            actions.append(result)
        def tx(value):
            poll('pending'); poll('tx_admitted')
            assert command(3,0,1)==f'TX {value:02x}'
            poll('pending'); poll('tx_delivered')
        def receive(value):
            assert command(4,0,value)=='OK'
            poll('pending'); poll('rx_received')
        status=None
        try:
            assert line()=='READY MAILBOX-CSR'
            host=adapter.Adapter(read,write)
            poll('reset'); reset(0); poll('pending'); poll('armed')
            tx(0xaa); tx(0)
            receive(0xf2); tx(0xfa); tx(0)
            receive(0xf4); tx(0xfa)
            host.input(20,-12,1); now=10_000_100
            for byte in (0x29,20,244): tx(byte)
            receive(0xfe)
            for byte in (0x29,20,244): tx(byte)
            assert (host._mouse.dx,host._mouse.dy)==(0,0)
            # RX preempts a genuinely queued, software-owned TX before wire admission.
            receive(0xf4); poll('pending'); poll('tx_admitted')
            assert command(4,0,0xf2)=='OK'
            poll('pending'); poll('tx_aborted'); poll('pending'); poll('rx_received')
            tx(0xfa); tx(0)
            # READY-to-store contention really causes the mailbox's ERROR bit.
            receive(0xf4)
            hook=lambda _a,_v: command(4,0,0xf2)
            poll('pending'); assert read(1)&adapter.ERROR
            poll('pending'); poll('flags_acknowledged'); poll('pending'); poll('rx_received')
            tx(0xfa); tx(0)
            # Old event acknowledgement races a full reset/deassert interval.
            receive(0xf4); poll('pending'); poll('tx_admitted')
            assert command(3,0,1)=='TX fa'
            def reset_before_ack(_a,_v): reset(1); reset(0)
            hook=reset_before_ack
            poll('pending'); assert read(1)&adapter.ERROR
            poll('pending'); poll('flags_acknowledged'); poll('pending'); poll('armed')
            tx(0xaa); tx(0)
            assert command(6)=='OK'
            poll('pending'); poll('flags_acknowledged')
            assert command(0)==f'DONE {requests}'
            proc.stdin.close(); proc.stdin=None
            tail=proc.communicate(timeout=5)[0]; log.write(tail)
            status=proc.wait(timeout=5)
            assert status==0
        finally:
            selector.close()
            if proc.poll() is None: proc.kill()
            proc.wait(timeout=5)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,native_exit=status,child_reaped=True,native=native,
        pins_unchanged=True,seconds=time.monotonic()-start,csr_requests=requests,
        policy_actions=actions,hardware_acceptance=False,serial_bfm=True,
        source_sha256={p.name:sha(out/p.name) for p in paths})
    (out/'closed.json').write_text(json.dumps(result,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ('policy_actions','source_sha256')}),flush=True)


if __name__=='__main__': main()
