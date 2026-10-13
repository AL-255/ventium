"""Cold REP-SMC to AGI/reference handoff on the real UV-fast AXI backend.

Reuse the existing reset-to-protected-mode SMC fixture, in cached and CD
bypass forms. Follow its two same-line stores with resident hint activity.
Compare every architectural record to pinned QEMU and every cycle to parent.
No snapshots, trace filtering, mode fallback or FPGA acceptance claim.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import traceback

import run_l1_write_kind_system as common
from run_next_pair_probe import FIELDS,PATTERN

REPO=common.REPO
sha,save=common.sha,common.save
HANDOFF='''blob_return:
    /* Re-enter cacheable execution after either SMC path. Prior poison must
     * still have forced fresh REP bytes, but must not corrupt later hints. */
    movl %cr0,%ebp
    andl $0x9fffffff,%ebp
    movl %ebp,%cr0
    movl $0x0002000c,%esi
    movl (%esi),%edx
    .rept 4
    movsbl (%esi),%edx
    leal (%esi),%esi
    movl (%esi),%edx
    .endr
'''


def fixture(original,cached):
    assert original.count('blob_return:\n')==1
    result=original.replace('blob_return:\n',HANDOFF)
    if cached:
        old='    orl     $1, %eax\n    movl    %eax, %cr0'
        assert result.count(old)==1
        result=result.replace(old,'    andl    $0x9fffffff, %eax\n'+old)
        old='    testl   $0x40000000, %ebp\n    jz      fail'
        assert result.count(old)==1
        result=result.replace(old,old.replace('jz','jnz'))
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('parent','candidate','out'):ap.add_argument('--'+key,type=Path,required=True)
    args=ap.parse_args();root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    models={};pins={};profiles=[]
    for label,folder in (('control',args.parent),('candidate',args.candidate)):
        folder=folder.resolve(strict=True)
        done=json.loads((folder/'build-closed.json').read_text())
        before=json.loads((folder/'build-started.json').read_text())
        assert done['passed'] and done['pins_unchanged'] and done['native_exit']==0
        models[label]=folder/'obj/tb_ventium';assert sha(models[label])==done['binary_sha256']
        pins.update(before['pins'])
        stamp=folder/'obj/Vventium_top__verFiles.dat'
        cmd=next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        defs=set(re.findall(r'\+define\+(\w+)',cmd));profiles.append(defs)
        assert ' --assert ' in cmd and len(defs)==152
        assert {'VEN_L1_AXI','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT',
                'VEN_RAW_AGI_PRIME','VEN_REF_OPERAND_PRIME','VEN_REP_CONT_NO_UOP'}<=defs
        assert not {'SYNTHESIS','VTM_NO_DPI','VEN_UOPCACHE'}&defs
        for p in (models[label],stamp,folder/'build-started.json',folder/'build-closed.json'):pins[str(p)]=sha(p)
    assert profiles[0]==profiles[1]
    source=REPO/'verif/sys/tests/prepicbpsmc/prepicbpsmc.S'
    linker=source.with_suffix('.ld')
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    gen=REPO/'verif/qemu-trace/gen_trace.py'
    for p in (Path(__file__),Path(common.__file__),source,linker,qemu,gen,
              REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py',
              REPO/'verif/sys/check_faultlog.py',REPO/'verif/sys/run-native-system.py',
              REPO/'verif/l1/run_next_pair_probe.py'):pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    root.mkdir()
    save(root/'started.json',dict(pins=pins,models={k:str(v) for k,v in models.items()},
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    clean={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','QEMU_','AXI_'))}
    result=dict(passed=False,rows=[],errors=[],gameplay_ipc=None,standard_suite=False,hardware_acceptance=False)
    begin=time.monotonic()

    def run(folder,label,cmd,expected=0,latency=0):
        cmd=['timeout','--kill-after=3s','45s',*map(str,cmd)]
        save(folder/(label+'.command.json'),dict(command=cmd,latency=latency))
        with (folder/(label+'.stdout')).open('x') as out,(folder/(label+'.stderr')).open('x') as err:
            child=subprocess.run(cmd,env=dict(clean,AXI_RLAT=str(latency),AXI_WLAT=str(latency),VEN_AXI_PROFILE='1'),
                                 stdout=out,stderr=err,pass_fds=(9,))
        save(folder/(label+'.exit.json'),dict(native_exit=child.returncode))
        stdout=(folder/(label+'.stdout')).read_text();stderr=(folder/(label+'.stderr')).read_text()
        assert child.returncode==expected,(folder,label,child.returncode,stderr[-1000:])
        return stdout,stderr

    try:
        for cached in (False,True):
            folder=root/('cached' if cached else 'bypass');folder.mkdir()
            asm=folder/'fixture.S';asm.write_text(fixture(source.read_text(),cached))
            obj,elf,image=[folder/('fixture.'+e) for e in ('o','elf','bin')]
            run(folder,'as',['gcc','-m32','-nostdlib','-ffreestanding','-fno-pie','-fno-pic','-c',asm,'-o',obj])
            run(folder,'ld',['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
                             '-Wl,--build-id=none',obj,'-o',elf])
            run(folder,'bin',['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image])
            assert image.stat().st_size==65536
            run(folder,'qemu-free',[qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
                '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
                '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
            with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
            goldpath=folder/'gold.vtrace'
            run(folder,'gold',[sys.executable,'-B',gen,'--qemu',qemu,'--system','--image',image,
                '--image-mode','bios','--cpu','pentium','--out',goldpath,'--max-insn','700','--port',port])
            gold=common.tracefmt.read_trace(str(goldpath))
            assert gold.sys and 50<len(gold.records)<700 and int(gold.records[-1]['eax'],0)&255==0x42
            rep=[r for r in gold.records if int(r['pc'],0)==0x20008]
            assert [(int(r['ecx'],0),int(r['edi'],0)) for r in rep]==[(1,0x20010),(0,0x20014)]
            for latency in (0,7,31):
                records={}
                for label,model in models.items():
                    records[label]={}
                    for mode in ('cycle-func','cycle'):
                        stem=f'{label}-l{latency}-{mode}';trace=folder/(stem+'.vtrace')
                        out,err=run(folder,stem,[model,'--system','--cosim','--'+mode,'--l1-axi',
                            '--image',image,'--out',trace,'--max-insn','700','--max-cycles','1000000',
                            '--quiesce','4096','+ven_faultlog','+ven_repcontlog','+ven_fetchdbg',
                            '+ven_fetchdbg_max=10000'],133,latency)
                        parsed=common.tracefmt.read_trace(str(trace));records[label][mode]=parsed.records
                        assert [r['n'] for r in parsed.records]==list(range(len(gold.records)))
                        assert [r['pc'] for r in parsed.records]==[r['pc'] for r in gold.records]
                        common.check_faultlog.check_counts(common.check_faultlog.read_counts(out.splitlines()),{})
                        assert not common.native.FATAL.search(out) and not common.native.FATAL.search(err)
                        bus=re.search(r'\[AXI_PROFILE\] read ar=(\d+) .*overlap=(\d+) orphan-r=(\d+) valid=(\d+)',err)
                        assert bus and int(bus[1])>0 and bus.group(2,3)==('0','0'), ('missing/invalid AXI activity',stem)
                        probes=PATTERN.findall(out);assert len(probes)==1
                        counts=dict(zip(FIELDS,map(int,probes[0])))
                        if mode=='cycle-func':
                            common.native.grade_native(parsed,out,err,133,133,700)
                            with (folder/(stem+'-diff.log')).open('x') as log:
                                assert common.compare.compare_func(gold,parsed,False,0xffffffff,False,20,log,sys_both=True)==0
                        result['rows'].append(dict(cached=cached,latency=latency,model=label,mode=mode,
                            records=len(parsed.records),trace_sha256=sha(trace),probe=counts,
                            axi_reads=int(bus[1]),axi_drained=bool(int(bus[4])),
                            paired_v=sum(r.get('pipe')=='V' and r.get('paired',False) for r in parsed.records)))
                assert records['control']==records['candidate'],('A/B mismatch',cached,latency)
        candidate=[r for r in result['rows'] if r['model']=='candidate']
        assert sum(r['paired_v'] for r in candidate)>0,'no actual paired retirement'
        assert all(sum(r['probe'][key] for r in candidate)>0 for key in ('agi','ref')), 'missing hint handoff coverage'
        result['passed']=len(result['rows'])==24
    except Exception as exc:result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json',result);print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
