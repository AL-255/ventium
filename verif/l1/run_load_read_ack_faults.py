#!/usr/bin/env python3
"""Cold UV-fast A/B of indirect far faults and the original split-page CMPSD.

Complete QEMU architectural comparisons plus complete parent/candidate clock
comparisons. No trace filtering, saved state, changed masks or cycle bands.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import tracefmt
import compare
import check_faultlog
spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
sha = native.digest


def far_fixture(source, kind, width):
    """Retain the cold pcallsel setup; change its tested immediate to memory."""
    assert kind in ('call', 'jump') and width in (16, 32)
    old = '    .byte   0x9A\n    .long   0x00000000\n    .word   0x0F00\n'
    assert source.count(old) == 1
    selector = 0x4a2 if width == 16 else 0x4a4
    prefix = '    .byte 0x66\n' if width == 16 else ''
    modrm = '0x1d' if kind == 'call' else '0x2d'
    new = (f'    movl $0, 0x04a0\n    movw $0x0f00, {selector:#x}\n'
           '    .global load_ack_target\nload_ack_target:\n'+prefix+
           f'    .byte 0xff, {modrm}\n    .long 0x04a0\n')
    source = source.replace(old, new)
    # Independent witnesses of the error code and fault restart EIP, as well
    # as the original EBP witness of an unchanged pre-fault stack pointer.
    assert source.count('gp_handler:\n') == 1
    return source.replace('gp_handler:\n', 'gp_handler:\n'
                          '    movl (%esp), %esi\n    movl 4(%esp), %edi\n')


def save(p, value):
    with p.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    roots = {n:getattr(args,n).resolve(strict=True) for n in ('parent','candidate')}
    pins, profiles, models = {}, {}, {}
    for name, root in roots.items():
        closed = json.loads((root/'build-closed.json').read_text())
        assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
        model = root/'obj/tb_ventium'
        assert sha(model) == closed['binary_sha256']
        models[name] = model
        stamp = root/'obj/Vventium_top__verFiles.dat'
        command = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        profiles[name] = set(re.findall(r'\+define\+(\w+)',command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
                'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT'} <= profiles[name]
        assert not {'SYNTHESIS','VTM_NO_DPI','VEN_SYS_FASTPATH_ALL'} & profiles[name]
        pins.update(json.loads((root/'build-started.json').read_text())['pins'])
        for p in (model, stamp, root/'build-closed.json', root/'build-started.json'):
            pins[str(p)] = sha(p)
    assert profiles['parent'] == profiles['candidate']
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    sources = {n:REPO/f'verif/sys/tests/{n}/{n}.S' for n in ('pcallsel','pxpage')}
    linkers = {n:p.with_suffix('.ld') for n,p in sources.items()}
    for p in (Path(__file__), qemu, *sources.values(), *linkers.values(),
              REPO/'verif/qemu-trace/gen_trace.py', Path(native.__file__),
              Path(tracefmt.__file__), Path(compare.__file__), Path(check_faultlog.__file__)):
        pins[str(p)] = sha(p)
    assert all(sha(p) == h for p,h in pins.items())
    out.mkdir()
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','QEMU_','AXI_'))}
    affinity = sorted(os.sched_getaffinity(0))
    save(out/'started.json',dict(pins=pins, profiles={k:sorted(v) for k,v in profiles.items()},
         invocation=os.environ.get('INVOCATION_ID'), affinity=affinity))
    result = dict(passed=False, errors=[], measurements=[], gameplay_ipc=None,
                  standard_suite=False, hardware_acceptance=False)

    def run(leaf, label, command, expected=0, latency=0):
        command = ['timeout','--kill-after=3s','60s',*map(str,command)]
        save(leaf/(label+'.command.json'), dict(command=command,axi_latency=latency))
        with (leaf/(label+'.stdout')).open('x') as stdout, (leaf/(label+'.stderr')).open('x') as stderr:
            child = subprocess.Popen(command, env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                                     stdout=stdout, stderr=stderr)
            actual_affinity = sorted(os.sched_getaffinity(child.pid))
            rc = child.wait()
        save(leaf/(label+'.exit.json'),dict(native_exit=rc,affinity=actual_affinity))
        assert actual_affinity == affinity and rc == expected,(label,rc,expected)
        return (leaf/(label+'.stdout')).read_text(), (leaf/(label+'.stderr')).read_text()

    begin = time.monotonic()
    try:
        for kind,width in [('call',16),('call',32),('jump',16),('jump',32),('split',32)]:
            leaf = out/f'{kind}{width}'
            leaf.mkdir()
            original = 'pxpage' if kind == 'split' else 'pcallsel'
            source = sources[original].read_text()
            if kind != 'split': source = far_fixture(source,kind,width)
            assembly, obj, elf, image = [leaf/('fixture.'+ext) for ext in ('S','o','elf','bin')]
            assembly.write_text(source)
            run(leaf,'assemble',['gcc','-m32','-nostdlib','-ffreestanding','-fno-pie','-fno-pic',
                                '-c',assembly,'-o',obj])
            run(leaf,'link',['gcc','-m32','-static','-no-pie','-nostdlib',
                            '-Wl,-T,'+str(linkers[original]),'-Wl,--build-id=none',obj,'-o',elf])
            run(leaf,'binary',['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image])
            assert image.stat().st_size == 65536
            symbols = {s[2]:int(s[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                       if len(s:=line.split())==3 and s[0]!='U'}
            run(leaf,'free-qemu',[qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
                '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
                '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
            golden = leaf/'golden.vtrace'
            run(leaf,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
                '--system','--image',image,'--image-mode','bios','--cpu','pentium','--out',golden,
                '--max-insn','5000','--port',port])
            gold = tracefmt.read_trace(str(golden))
            assert 100<len(gold.records)<5000 and gold.sys
            for latency in (0,7):
                both = {}
                for name, model in models.items():
                    traces, clocks = {}, {}
                    for mode in ('cycle-func','cycle'):
                        label=f'{name}-lat{latency}-{mode}'
                        actual=leaf/(label+'.vtrace')
                        stdout,stderr=run(leaf,label,[model,'--system','--cosim','--'+mode,'--l1-axi',
                            '--image',image,'--out',actual,'--max-insn','5000','--max-cycles','3000000',
                            '--quiesce','4096','+ven_faultlog','+ven_load_read_ack_witness'],133,latency)
                        trace=tracefmt.read_trace(str(actual)); traces[mode]=trace.records
                        assert [r['n'] for r in trace.records]==list(range(len(gold.records)))
                        assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                        check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),
                            {} if kind=='split' else {(13,0xf00):1})
                        assert not native.FATAL.search(stdout+stderr)
                        if mode=='cycle-func':
                            clocks[mode]=native.grade_native(trace,stdout,stderr,133,133,5000)['clocks']
                            with (leaf/(label+'-diff.log')).open('x') as log:
                                assert compare.compare_func(gold,trace,False,0xffffffff,False,20,log,sys_both=True)==0
                        else:
                            clocks[mode]=int(re.search(r'after \d+ retired in (\d+) clocks',stderr)[1])
                        if kind!='split':
                            last=trace.records[-1]
                            # Cycle records do not include architectural registers.
                            if mode=='cycle-func':
                                assert int(last['ebp'],0)==0x0ca10000
                                assert int(last['esi'],0)==0xf00
                                assert int(last['edi'],0)==symbols['load_ack_target']
                        if name=='candidate':
                            witnesses=re.findall(r'^\[LOAD-READ-ACK\] (\w+) pc=([0-9a-f]+) split=(\d) cross=(\d) far_call=(\d) far_jump=(\d)$',stdout,re.M)
                            if kind=='split':
                                assert any(w[0]=='S_LOAD2' and w[2]=='1' for w in witnesses), 'missing second-fragment S_LOAD2 completion'
                            else:
                                assert any(int(w[1],16)==symbols['load_ack_target'] and
                                    w[4 if kind=='call' else 5]=='1' for w in witnesses), 'missing actual indirect far-load completion'
                    assert clocks['cycle']==clocks['cycle-func']
                    both[name]=traces
                    result['measurements'].append(dict(case=leaf.name,model=name,latency=latency,
                        records=len(traces['cycle']),clocks=clocks['cycle'],
                        paired_v=sum(r.get('pipe')=='V' and r.get('paired') for r in traces['cycle'])))
                assert both['parent']==both['candidate'], 'complete A/B state or cycle mismatch'
            print(leaf.name+' complete QEMU and cycle A/B PASS',flush=True)
        assert len(result['measurements'])==20
        assert sum(r['paired_v'] for r in result['measurements'] if r['model']=='candidate')>0
        result['passed']=True
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    result['artifacts']={str(p.relative_to(out)):sha(p) for p in out.rglob('*') if p.is_file()}
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('artifacts','measurements')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
