"""Exercise real host-to-keyboard pins with AUTOACK disabled on both sources.

The existing mouse transport test is retained unchanged. This private derivative
selects the keyboard port, uses raw scan bytes and explicitly budgets the reset
inhibit. It neither changes controller RTL nor qualifies a physical keyboard.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import run_loss_aux_transport as transport

ROOT=transport.ROOT
REPO=Path(__file__).resolve().parents[2]


def keyboard_tb(source):
    text=transport.bounded_tb(source)
    edits=(
        ('.irq_keyb(irq_keyb),.irq_mouse(irq_mouse)',
         '.irq_keyb(irq_mouse),.irq_mouse(irq_keyb)'),
        (".ps2_kbclk(1'b1),.ps2_kbdat(1'b1),.ps2_kbclk_out(kc),.ps2_kbdat_out(kd),\n"
         "        .ps2_mouseclk(manual ? 1'b1 : line_clk),\n"
         "        .ps2_mousedat(manual ? 1'b1 : line_dat),\n"
         "        .ps2_mouseclk_out(hc),.ps2_mousedat_out(hd)",
         ".ps2_mouseclk(1'b1),.ps2_mousedat(1'b1),.ps2_mouseclk_out(kc),.ps2_mousedat_out(kd),\n"
         "        .ps2_kbclk(manual ? 1'b1 : line_clk),\n"
         "        .ps2_kbdat(manual ? 1'b1 : line_dat),\n"
         "        .ps2_kbclk_out(hc),.ps2_kbdat_out(hd)"),
        ("            io_wr(4,8'hd4);",'            // Physical keyboard command: no D4 AUX prefix.'),
        ("(status & 8'ha1) !== 8'h21", "(status & 8'ha1) !== 8'h01"),
        ('IRQ12/completion or spurious IRQ1','IRQ1/completion or spurious IRQ12'),
        ('IRQ12 not consumed','IRQ1 not consumed'),
        ('repeat (8) @(negedge clk);\n        for (i=0;i<10;',
         "repeat (8) @(negedge clk);\n        io_wr(4,8'h60); io_wr(0,8'h03); // raw keyboard, both IRQs\n        for (i=0;i<10;"),
        ("        mouse_command(8'hff); received(8'hff,0); consume;",
         "        io_wr(4,8'h60); io_wr(0,8'h03); // reset restored translation\n"
         "        mouse_command(8'hff); received(8'hff,0); consume;"),
    )
    for old,new in edits:
        if text.count(old)!=1: raise ValueError('keyboard transport anchor drift: '+old)
        text=text.replace(old,new)
    text=text.replace('mouse_command','keyboard_command')
    return ('// PRIVATE PHYSICAL-KEYBOARD DERIVATIVE. AUTOACK MUST BE OFF.\n'
            '// Legacy variable irq_mouse now means selected IRQ1, irq_keyb means other IRQ12.\n'+text)


def grade(code,text):
    counts=[tuple(map(int,row)) for row in re.findall(
        r'PS2-DEVICE-OK hz=(\d+) checks=(\d+) completed=(\d+) aborted=(\d+)',text)]
    latencies=re.findall(r'PS2-RECEIVE-LATENCY hz=(\d+) byte=([0-9a-f]+) clocks=(\d+) limit=(\d+)',text)
    return (code==0 and sorted(counts)==[(3125000,49,26,2),(40000000,49,26,2)]
            and text.count('PS2-DEVICE-ALL-OK profiles=2')==1 and 'FATAL' not in text
            and len(latencies)==36 and all(int(n)<int(limit) for _,_,n,limit in latencies))


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    a=parser.parse_args(); out=a.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert ROOT.stat().st_dev != REPO.stat().st_dev
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert sorted(os.sched_getaffinity(0))==[12,13] and os.environ.get('INVOCATION_ID')
    assert shutil.disk_usage(ROOT).free>4*1024**3
    cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((cg/'memory.max').read_text())<=512*1024**2
    assert (cg/'memory.swap.max').read_text().strip()=='0'
    assert 0<int((cg/'pids.max').read_text())<=32
    previous=ROOT/'ps2-loss-aux-transport-r1'
    started=json.loads((previous/'started.json').read_text())
    closed=json.loads((previous/'closed.json').read_text())
    assert closed['passed'] and not closed['original_run_passed']
    files={name:previous/'source'/name for name in
           ('parent.v','candidate.v','simple_fifo.v','ven_ps2_device.sv','tb_ps2_device.sv')}
    for name,path in files.items():
        matches=[h for p,h in started['pins'].items() if Path(p).resolve(strict=True)==path]
        assert len(matches)==1 and sha(path)==matches[0],name
    out.mkdir(); src=out/'source'; src.mkdir()
    pins={str(p):sha(p) for p in [*files.values(),Path(__file__).resolve(),
        Path(transport.__file__).resolve(),previous/'started.json',previous/'closed.json']}
    for name,path in files.items():
        shutil.copyfile(path,src/name); assert sha(src/name)==pins[str(path)]
        pins[str(src/name)]=sha(src/name)
    tb=src/'tb_physical_keyboard.sv'
    with tb.open('x') as stream: stream.write(keyboard_tb(files['tb_ps2_device.sv'].read_text()))
    pins[str(tb)]=sha(tb)
    tools={n:str(Path(shutil.which(n)).resolve(strict=True)) for n in ('iverilog','vvp')}
    pins.update({p:sha(p) for p in tools.values()})
    def save(name,obj):
        with (out/name).open('x') as stream: json.dump(obj,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=[12,13],
        autoack=False,physical_keyboard_pins=True,original_run_passed=False,
        full_pc=False,physical_fpga=False,standard_suite=False,gameplay_ipc=None))
    begin=time.monotonic(); rows=[]; builds=[]; errors=[]
    def execute(label):
        assert shutil.disk_usage(ROOT).free>4*1024**3
        cmd=[tools['vvp'],str(out/(label+'.vvp'))]; log=out/(label+'.log')
        start=time.monotonic()
        with log.open('x') as stream:
            child=subprocess.Popen(cmd,stdout=stream,stderr=subprocess.STDOUT)
            affinity=sorted(os.sched_getaffinity(child.pid))
            try:
                assert affinity==[12,13]
                code=child.wait(timeout=125)
            except BaseException: child.kill(); child.wait(); raise
        text=log.read_text(); good=grade(code,text)
        if label=='bad-parity': good=code==1 and 'TX bit/parity mismatch' in text
        row=dict(label=label,native_exit=code,passed=good,command=cmd,
            native_pid=child.pid,waited=True,affinity=affinity,seconds=time.monotonic()-start,
            log=str(log),log_sha256=sha(log),image_sha256=sha(cmd[1]))
        print(json.dumps(row),flush=True)
        return row
    try:
        original=(src/'ven_ps2_device.sv').read_text(); assert original.count('~^tx_data')==1
        mutant=src/'bad-parity.sv'
        with mutant.open('x') as stream: stream.write(original.replace('~^tx_data','^tx_data'))
        pins[str(mutant)]=sha(mutant)
        for label in ('parent','candidate','bad-parity'):
            cmd=[tools['iverilog'],'-g2012','-Wall','-s','tb_ps2_device','-DVEN_KBC_FAST',
                 '-o',str(out/(label+'.vvp')),str(src/('parent.v' if label=='parent' else 'candidate.v')),
                 str(src/'simple_fifo.v'),str(mutant if label=='bad-parity' else src/'ven_ps2_device.sv'),str(tb)]
            with (out/(label+'-compile.log')).open('x') as stream:
                proc=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            builds.append(dict(command=cmd,native_exit=proc.returncode)); assert proc.returncode==0
        with ThreadPoolExecutor(max_workers=2) as pool:
            for row in pool.map(execute,('parent','candidate','bad-parity')):
                rows.append(row)
                if not row['passed']: errors.append(row['label'])
    except Exception as exc: errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines())}
    good=not errors and stable and len(rows)==3 and not any(events[k] for k in ('oom','oom_kill','oom_group_kill'))
    result=dict(passed=good,rows=rows,builds=builds,errors=errors,pins=pins,pins_unchanged=stable,
        memory_events=events,memory_peak=int((cg/'memory.peak').read_text()),seconds=time.monotonic()-begin,
        original_run_passed=False,full_pc=False,physical_fpga=False,standard_suite=False,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','builds','pins')}),flush=True)
    return 0 if good else 1


if __name__=='__main__': raise SystemExit(main())
