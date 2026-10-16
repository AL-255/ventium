"""Cold whole-PC keyboard transport probe; never Windows or FPGA acceptance.

The guest configures/reads the actual 8042 through normal CPU I/O. The only
external inputs are named-key commands sent to an owned FIFO. No debugger,
saved state, forced DUT state, accelerated wire timing or speculative replay.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import time

from build_pc_input_probe import REPO,sha

RAW=[0x14,0x76,0xf0,0x76,0xf0,0x14,0x5a,0xf0,0x5a]
EXPECTED={0:[0x1d,0x01,0x81,0x9d,0x1c,0x9c],1:RAW}
COMMANDS=b'1 key ctrl+esc\n2 key enter\n3 capture\n'


def grade(text,raw):
    assert not re.search(r'UI-ERROR|UI-FAILED|UI-REJECT|UI-SETUP-ERROR|UI-PROBE-FAIL|%Error|%Fatal|Assertion failed|CPU HUNG|UNIMPLEMENTED',text)
    assert f'UI-PROBE-READY raw={raw}' in text and f'UI-PROBE-PASS raw={raw}' in text
    assert text.index(f'UI-PROBE-READY raw={raw}')<text.index('[UI-QUEUED] id=1')<text.index(f'UI-PROBE-PASS raw={raw}')
    queued=re.findall(r'\[UI-QUEUED\] id=(\d+) cycle=\d+ op=(key|capture) bytes=(\d+)',text)
    assert queued==[('1','key','6'),('2','key','3'),('3','capture','0')]
    wire=re.findall(r'\[UI-WIRE-BYTE\] id=(\d+) cycle=(\d+) index=(\d+) total=(\d+) raw=([0-9a-f]{2})',text)
    assert [int(r[4],16) for r in wire]==RAW
    assert [(int(r[0]),int(r[2]),int(r[3])) for r in wire]==[(1,i,6) for i in range(1,7)]+[(2,i,3) for i in range(1,4)]
    assert re.findall(r'\[UI-WIRE-COMPLETE\] id=(\d+) cycle=\d+ bytes=(\d+)',text)==[('1','6'),('2','3')]
    reads=[int(v,16) for v in re.findall(r'\[UI-GUEST-READ\] cycle=\d+ id_context=\d+ value=([0-9a-f]{2})',text)]
    assert reads==EXPECTED[raw],reads
    assert len(re.findall(r'\[UI-CAPTURE-UNAVAILABLE\] id=3 cycle=\d+ path=none pixels=raw ui_success=not_asserted',text))==1
    assert '[UI-CAPTURE-PUBLISHED]' not in text
    assert re.findall(r'\[UI-END\] cycle=\d+ pending=(\d+) owned=(\d+) failed=(\d+)',text)==[('0','0','0')]
    assert re.search(r'\[UI-READY\].* half=1667 idle=4000 ',text)
    assert '[BOARD_AXI] real RTL profile=1 slots=16 B-delay=20 R-first=21 gap=1' in text
    samples=re.findall(r'\[VEN-PERF\] cycle=(\d+) retires=(\d+) clocks=(\d+) u=(\d+) v=(\d+)',text)
    assert samples and int(samples[-1][4])>0,'no actual paired execution'
    return dict(raw=raw,wire_bytes=RAW,guest_reads=reads,last_cycle=int(samples[-1][0]),
        last_u=int(samples[-1][3]),last_v=int(samples[-1][4]),
        graphics_capture=False,ui_success_asserted=False,standard_suite=False,gameplay_ipc=None)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('soc','images','qemu_proof','out'):ap.add_argument('--'+name.replace('_','-'),type=Path,required=True)
    a=ap.parse_args();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    soc=a.soc.resolve(strict=True);images=a.images.resolve(strict=True);proof=a.qemu_proof.resolve(strict=True);out=a.out.resolve()
    assert __debug__ and os.environ['TMPDIR']=='/home/yukidama/external/tmp'
    assert os.sched_getaffinity(0)=={16,17}
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>4*1024**3
    assert out!=scratch and out.is_relative_to(scratch) and not out.exists()
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=2*1024**3
    assert (group/'memory.swap.max').read_text().strip()=='0'
    def load(p):return json.loads(p.read_text())
    built,start=load(soc/'build-closed.json'),load(soc/'build-started.json')
    assert built['passed'] and built['inputs_unchanged'] and built['native_exit']==0
    assert start['controller_sha256']=='9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405'
    assert start['processor_rtl_changes']==[] and start['added_defines']==[]
    assert 'pc_keyboard_retained.h' in start['host_headers']
    assert not start['original_transport_gate_passed'] and not start['full_pc_input_qualified']
    assert re.search(r"\.cycle_mode\s*\(1'b1\)",(soc/'source/ao486-sim/ven/ven_ao486_shim.sv').read_text())
    defs=set((soc/'defines.txt').read_text().splitlines())
    assert len(defs)==157 and {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
        'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_KBC_FAST','VEN_KBD_AUTOACK'}<=defs
    model=soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted'
    assert sha(model)==built['binary_sha256']
    qemu=load(proof/'closed.json');assert qemu['passed'] and qemu['pins_unchanged']
    assert [(r['case'],r['native_exit']) for r in qemu['rows']]==[
        ('raw0-positive',33),('raw1-positive',33),('raw0-wrong-key',35)]
    image_build=load(images/'built.json');assert image_build['built'] and image_build['pins_unchanged']
    rom=scratch/'ventium-sfetch16-soc.p8u2t1lA/quake-cold-sfetch16-oct10.1/run/rom'
    pins=dict(start['pins']);pins.update(image_build['pins']);pins.update(load(proof/'started.json')['pins'])
    for p in (Path(__file__),model,soc/'build-started.json',soc/'build-closed.json',soc/'defines.txt',
              images/'built.json',proof/'closed.json',rom/'boot0.rom',rom/'boot1.rom'):
        pins[str(p.resolve())]=sha(p)
    for raw in (0,1):pins[str(images/f'raw{raw}'/'input.img')]=sha(images/f'raw{raw}'/'input.img')
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir(mode=0o700)
    def save(p,d):
        with p.open('x') as f:json.dump(d,f,indent=2)
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],model=sha(model),
        cold_boot=True,cycle_mode=1,uv_fast=True,standard_suite=False,physical_board=False))
    def case(raw):
        cpu=16+raw;work=out/f'raw{raw}';work.mkdir(mode=0o700);shutil.copytree(rom,work/'rom')
        shutil.copyfile(images/f'raw{raw}'/'input.img',work/'input.img')
        endpoint=work/'input.fifo';stop=work/'stop.request';log=work/'run.log'
        argv=['/usr/bin/taskset','-c',str(cpu),str(model),'--ide',str(work/'input.img'),
            '--rate','40000000','--rate-rtc','40000000','--rate-vga','80000000','--mem','16',
            '--cycles','14000000','--ven-perf-every','250000','--vgatext-every','250000',
            '--ui-fifo',str(endpoint),'--stop-request',str(stop)]
        env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','AO486_','AXI_','TB_'))}
        env.update(TMPDIR=str(work),AO486_BIOS_DIR=str(work/'rom'))
        begin=time.monotonic();sent=False;stopped=False;error=None;graded=None;observed={}
        with log.open('x') as stream:
            child=subprocess.Popen(argv,cwd=work,env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                deadline=begin+5
                while Path('/proc',str(child.pid),'exe').resolve()!=model:
                    assert child.poll() is None and time.monotonic()<deadline
                    time.sleep(.01)
                observed=dict(pid=child.pid,affinity=sorted(os.sched_getaffinity(child.pid)),
                    exe=str(Path('/proc',str(child.pid),'exe').resolve()),
                    argv=Path('/proc',str(child.pid),'cmdline').read_bytes().rstrip(b'\0').decode().split('\0'),
                    cgroup=Path('/proc',str(child.pid),'cgroup').read_text(),bios=str(work/'rom'))
                assert observed['affinity']==[cpu] and observed['argv']==argv[3:]
                assert observed['cgroup']==Path('/proc/self/cgroup').read_text()
                save(work/'native.json',observed)
                while child.poll() is None:
                    assert time.monotonic()-begin<480,'native timeout'
                    assert shutil.disk_usage(scratch).free>4*1024**3,'disk reserve'
                    text=log.read_text()
                    assert not re.search(r'UI-ERROR|UI-FAILED|UI-SETUP-ERROR|UI-PROBE-FAIL|%Error|%Fatal',text),text[-2000:]
                    if not sent and f'UI-PROBE-READY raw={raw}' in text:
                        info=endpoint.lstat()
                        assert stat.S_ISFIFO(info.st_mode) and info.st_uid==os.geteuid() and stat.S_IMODE(info.st_mode)==0o600
                        fd=os.open(endpoint,os.O_WRONLY|os.O_NONBLOCK|os.O_NOFOLLOW)
                        try:
                            opened=os.fstat(fd);assert (opened.st_dev,opened.st_ino)==(info.st_dev,info.st_ino)
                            assert os.write(fd,COMMANDS)==len(COMMANDS)
                        finally:os.close(fd)
                        save(work/'sent.json',dict(commands=COMMANDS.decode(),device=info.st_dev,inode=info.st_ino))
                        sent=True
                    if sent and not stopped and f'UI-PROBE-PASS raw={raw}' in text and '[UI-CAPTURE-UNAVAILABLE] id=3 ' in text:
                        with stop.open('x') as f:f.write('input probe completed; close native model for independent grading\n')
                        stopped=True
                    time.sleep(.1)
                code=child.wait();assert code==0 and sent and stopped
                text=log.read_text();graded=grade(text,raw)
                assert '[HOST-STOP] request=' in text
                assert all('BIOS: '+str(work/'rom'/n) in text for n in ('boot0.rom','boot1.rom'))
                assert sha(work/'input.img')==sha(images/f'raw{raw}'/'input.img')
            except Exception as exc:error=repr(exc)
            finally:
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try:child.wait(timeout=5)
                    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
                else:child.wait()
        result=dict(raw=raw,passed=error is None,error=error,argv=argv,observed=observed,
            native_exit=child.returncode,actual_wait=True,proc_gone=not Path('/proc',str(child.pid)).exists(),
            seconds=time.monotonic()-begin,grade=graded,log_sha256=sha(log),commands_sent=sent,graceful_stop=stopped)
        save(work/'closed.json',result);print(json.dumps({k:v for k,v in result.items() if k not in ('argv','observed','grade')}),flush=True)
        return result
    with ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(case,(0,1)))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result=dict(passed=stable and all(r['passed'] and r['proc_gone'] for r in rows)
        and not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),rows=rows,pins_unchanged=stable,
        memory_events=events,memory_peak=int((group/'memory.peak').read_text()),
        cold_input_transport=True,windows_ui=False,physical_board=False,standard_suite=False,gameplay_ipc=None)
    save(out/'closed.json',result);print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
