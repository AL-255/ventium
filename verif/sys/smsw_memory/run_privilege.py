"""Cold CPL3/V86 SMSW tests with full QEMU system-state comparison.

No RTL rebuild, injected guest state, trace trimming, extra masks or fallback
mode. Ordinary MOV controls validate the fixture, not the missing instruction.
V86 uses IOPL=3; paging, fault precision and event boundaries remain separate.
"""
import argparse
import concurrent.futures
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

from run_probe import HERE, REPO, EXTERNAL, QEMU, sha
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def save(path, value):
    with path.open('x') as stream:
        json.dump(value,stream,indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',required=True,type=Path)
    parser.add_argument('--core',required=True,type=Path)
    parser.add_argument('--control-model',required=True,type=Path)
    args = parser.parse_args()
    root,core,oldmodel = args.out.resolve(),args.core.resolve(strict=True),args.control_model.resolve(strict=True)
    model = core/'obj/tb_ventium'
    assert __debug__ and root.is_relative_to(EXTERNAL) and root != EXTERNAL and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == EXTERNAL
    assert shutil.disk_usage(EXTERNAL).free > 4*1024**3+256*1024**2
    assert sha(oldmodel) == '73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca'
    before,built = [json.loads((core/file).read_text()) for file in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(model) == built['binary_sha256']
    assert len(before['definitions']) == 152 and all(sha(p)==h for p,h in before['pins'].items())
    pins = {str(p):sha(p) for p in (Path(__file__),HERE/'run_probe.py',HERE/'privilege.S',
        HERE/'privilege.ld',QEMU,model,oldmodel,core/'build-started.json',core/'build-closed.json',
        REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py')}
    allowed = sorted(os.sched_getaffinity(0))
    assert len(allowed) == 16
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_','QEMU_'))}
    env.update(AXI_RLAT='7',AXI_WLAT='7',PYTHONDONTWRITEBYTECODE='1')
    cases = [dict(zip(('V86','ADDR32','OP32','SEG','OFFSET','CONTROL'),values))
             for values in itertools.product((0,1),(0,1),(0,1),(0,1,2),(1,4095),(0,))]
    cases += [dict(V86=v,ADDR32=0,OP32=0,SEG=s,OFFSET=d,CONTROL=1)
              for v,s,d in itertools.product((0,1),(0,1,2),(1,4095))]
    assert len(cases) == 60
    root.mkdir()
    save(root/'started.json',dict(pins=pins,cases=cases,invocation=os.environ.get('INVOCATION_ID'),
        affinity=allowed,definitions=before['definitions'],model_sha256=sha(model)))

    def case_run(index,c):
        name = '-'.join(k.lower()+str(v) for k,v in c.items())
        folder = root/name
        folder.mkdir()
        cpus = allowed[2*(index%8):2*(index%8)+2]
        affinity = ','.join(map(str,cpus))
        def run(label,command,expected=0,leaf=None,seconds=15):
            command = ['taskset','-c',affinity,'timeout','--kill-after=2s',str(seconds)+'s',*map(str,command)]
            save(folder/(label+'-command.json'),dict(argv=command,affinity=cpus))
            seen = {}
            with (folder/(label+'.log')).open('x') as stream:
                child = subprocess.Popen(command,env=env,stdout=stream,stderr=subprocess.STDOUT)
                try:
                    while child.poll() is None:
                        if leaf:
                            queue = [child.pid]
                            while queue:
                                pid = queue.pop()
                                try:
                                    proc = Path('/proc')/str(pid)
                                    queue.extend(map(int,(proc/'task'/str(pid)/'children').read_text().split()))
                                    if (proc/'exe').readlink().name == leaf:
                                        actual = sorted(os.sched_getaffinity(pid))
                                        assert actual == cpus,(name,pid,actual,cpus)
                                        seen[pid] = actual
                                except (FileNotFoundError,ProcessLookupError):
                                    pass
                        time.sleep(0.002)
                    code = child.wait()
                finally:
                    if child.poll() is None:
                        child.terminate()
                        child.wait(timeout=5)
            save(folder/(label+'-native.json'),dict(exit=code,observed_affinity=seen))
            assert code == expected,(name,label,code,expected)
            assert not leaf or seen,(name,label,'native affinity unobserved')

        obj,elf,image = [folder/('probe'+suffix) for suffix in ('.o','.elf','.bin')]
        run('assemble',['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
            *[f'-D{k}={v}' for k,v in c.items()],'-c',HERE/'privilege.S','-o',obj])
        run('link',['ld','-m','elf_i386','-T',HERE/'privilege.ld','--build-id=none',obj,'-o',elf])
        run('binary',['objcopy','-O','binary',elf,image])
        assert image.stat().st_size == 65536
        symbols = {row.split()[2]:int(row.split()[0],16) for row in
                   subprocess.check_output(['nm','-n',elf],text=True).splitlines() if len(row.split()) == 3}
        pc,after = [symbols[key] for key in ('smsw_probe','smsw_after')]
        encoding = image.read_bytes()[pc-0xf0000:after-0xf0000]
        if not c['CONTROL']:
            prefix = ([0x64] if c['SEG']==2 else []) + ([0x66] if c['OP32']!=1-c['V86'] else [])
            prefix += [0x67] if c['ADDR32']!=1-c['V86'] else []
            operand = [0x64,0x35 if c['SEG']==1 else 0x33,8] if c['ADDR32'] else [0x62 if c['SEG']==1 else 0x60,8]
            assert encoding == bytes(prefix+[0x0f,0x01]+operand),(name,encoding.hex())
        run('qemu-native',[QEMU,'-display','none','-monitor','none','-serial','none','-no-reboot',
            '-machine','pc','-cpu','pentium','-m','32','-device','isa-debug-exit,iobase=0xf4,iosize=0x04',
            '-bios',image],expected=133,leaf=QEMU.name)
        for label,binary,code in (('control',oldmodel,133 if c['CONTROL'] else 135),('candidate',model,133)):
            run(label,[binary,'--system','--cosim','--cycle-func','--l1-axi','--image',image,
                '--out',folder/(label+'.vtrace'),'--max-insn','3000','--max-cycles','1000000',
                '--quiesce','4096','+ven_faultlog','+ven_seglog'],expected=code,leaf=binary.name)
            log = (folder/(label+'.log')).read_text()
            assert 'isa-debug-exit' in log
            if code == 133:
                assert '[FAULT] vec=' not in log
            else:
                faults = [line for line in log.splitlines() if line.startswith('[FAULT] vec=')]
                assert len(faults) == 1 and faults[0].startswith('[FAULT] vec=6 '),(name,faults)
        run('golden',['python3',REPO/'verif/qemu-trace/gen_trace.py','--system','--qemu',QEMU,
            '--cpu','pentium','--image',image,'--image-mode','bios','--max-insn','3000',
            '--port',str(12510+index),'--out',folder/'golden.vtrace'],leaf=QEMU.name)
        assert 'guest exited' in (folder/'golden.log').read_text()
        run('compare',['python3',REPO/'verif/diff/compare.py','--mode','func',
            folder/'golden.vtrace',folder/'candidate.vtrace'])
        assert 'sys compared: True' in (folder/'compare.log').read_text()
        golden,rtl = [tracefmt.read_trace(str(folder/(label+'.vtrace'))) for label in ('golden','candidate')]
        for trace in (golden,rtl):
            assert trace.sys and trace.mode == 'func'
            # The system trace uses architectural EIP in V86, not CS.base+EIP.
            trace_pc = pc-0xf0000 if c['V86'] else pc
            probe = [r for r in trace.records if int(r['pc'],16) == trace_pc]
            assert len(probe) == 1,(name,pc,len(probe))
            assert int(probe[0]['cs'],16) == (0xf000 if c['V86'] else 0x1b)
            assert bool(int(probe[0]['eflags'],16)&0x20000) == bool(c['V86'])
            assert int(trace.records[-1]['eax'],16)&255 == 0x42
        row = dict(case=c,name=name,passed=True,records=len(rtl.records),pc=pc,encoding=encoding.hex(),
                   image_sha256=sha(image),artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()})
        save(folder/'closed.json',row)
        return row

    begin = time.monotonic()
    result = dict(passed=False,rows=[],errors=[],standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        jobs = {pool.submit(case_run,index,c):c for index,c in enumerate(cases)}
        for job in concurrent.futures.as_completed(jobs):
            try:
                result['rows'].append(job.result())
            except Exception as error:
                result['errors'].append(dict(case=jobs[job],error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  records=sum(row['records'] for row in result['rows']))
    result['passed'] = len(result['rows']) == 60 and not result['errors'] and result['pins_unchanged']
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k != 'rows'}),flush=True)
    print('cases',len(result['rows']),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
