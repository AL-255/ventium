#!/usr/bin/env python3
"""Cold scalar store fault precision: full QEMU diff, not filtered traces."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import tracefmt
import check_faultlog
from x87_event_compare import compare_complete


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models = {name: getattr(args, name).resolve(strict=True) for name in ('control', 'candidate')}
    source = REPO/'verif/fe_pipe/fp-scalar-fault.S'
    linker = REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    pins, profiles = {}, {}
    for name, tb in models.items():
        stamp = tb.parent/'Vventium_top__verFiles.dat'
        command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        profiles[name] = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
                'VEN_FP_SHARED', 'VEN_FP_SHORT_WINDOW'} <= profiles[name]
        assert not {'VEN_UOPCACHE', 'VTM_NO_DPI', 'SYNTHESIS', 'VEN_SYS_FASTPATH_ALL'} & profiles[name]
        pins.update({str(p): sha(p) for p in (tb, stamp)})
    assert profiles['candidate'] == profiles['control'] | {'VEN_FP_SCALAR_DISPATCH'}
    assert 'VEN_FP_SCALAR_DISPATCH' not in profiles['control']
    for p in (Path(__file__),source,linker,qemu,REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py',
              REPO/'verif/sys/check_faultlog.py',REPO/'verif/sys/x87_event_compare.py'):
        pins[str(p)] = sha(p)
    save(args.out/'inputs.json', pins)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')

    def run(command, leaf, name, expected=0, latency=0):
        command = ['timeout','--signal=TERM','--kill-after=3s','60s',*map(str,command)]
        save(leaf/(name+'.command.json'),command)
        with (leaf/(name+'.stdout')).open('x') as out, (leaf/(name+'.stderr')).open('x') as err:
            rc = subprocess.run(command,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                                stdout=out,stderr=err).returncode
        save(leaf/(name+'.exit.json'),dict(exit=rc))
        assert rc == expected,(name,rc,expected)
        return (leaf/(name+'.stdout')).read_text()+'\n'+(leaf/(name+'.stderr')).read_text()

    def prepare(case):
        kind,split,present = case
        leaf = args.out/f'k{kind}-split{split}-present{present}'
        leaf.mkdir()
        obj,elf,image = [leaf/('fixture.'+ext) for ext in ('o','elf','bin')]
        run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
             f'-DKIND={kind}',f'-DSPLIT={split}',f'-DPRESENT={present}','-c',source,'-o',obj],leaf,'assemble')
        run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
             '-Wl,--build-id=none',obj,'-o',elf],leaf,'link')
        run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],leaf,'binary')
        assert image.stat().st_size == 65536
        symbols = {p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                   if len(p := line.split()) == 3 and p[0] != 'U'}
        run([qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,'-display','none',
             '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
             '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],leaf,'free-qemu',133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
        run([sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
             '--system','--x87','--image',image,'--image-mode','bios','--cpu','pentium',
             '--out',leaf/'golden.vtrace','--max-insn','5000','--port',str(port)],leaf,'golden')
        gold = tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert 100 < len(gold.records) < 5000
        assert int(gold.records[-1]['eax'],0)&255 == 0x42
        return case,leaf,image,symbols,gold

    def measure(job):
        prepared,name,latency = job
        case,leaf,image,symbols,gold = prepared
        kind,split,present = case
        traces, dispatch_faults = {}, 0
        for mode in ('cycle-func','cycle'):
            stem = f'{name}-l{latency}-{mode}'
            path = leaf/(stem+'.vtrace')
            text = run([models[name],'+ven_fetchdbg','+ven_faultlog','--system','--cosim','--x87',
                        '--'+mode,'--l1-axi','--image',image,'--out',path,'--max-insn','5000',
                        '--max-cycles','3000000','--quiesce','200000'],leaf,stem,133,latency)
            trace = tracefmt.read_trace(str(path)); traces[mode] = trace
            assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
            assert [r['n'] for r in trace.records] == list(range(len(trace.records)))
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL',text)
            stdout = (leaf/(stem+'.stdout')).read_text()
            check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),{(14,2+present):1})
            faults = re.findall(r'^\[FAULT\] vec=14 err=([0-9a-f]+) pc=([0-9a-f]+) ',stdout,re.M)
            assert faults == [(f'{2+present:08x}',f'{symbols["hot_op"]:08x}')]
            before_fault = stdout[:stdout.index('[FAULT] vec=14')]
            admissions = [line for line in before_fault.splitlines()
                          if re.search(r'\[FETCHDBG:(FP-SHORT|FP-SDISPATCH|DECODE)\]',line)
                          and f'eip={symbols["hot_op"]:08x} ' in line]
            actual = bool(admissions and '[FETCHDBG:FP-SDISPATCH]' in admissions[-1])
            assert actual == (name == 'candidate'),('fault did not exercise selected path',case,name,admissions[-3:])
            dispatch_faults += actual
            footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                r'after (\d+) retired in (\d+) clocks$',text,re.M)
            assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
            if mode == 'cycle-func':
                assert trace.mode == 'func' and trace.hdr.get('sys') is True and trace.x87
                with (leaf/(stem+'-diff.log')).open('x') as log:
                    assert compare_complete(gold,trace,log) == 0,(case,name,latency,'full QEMU diff')
        rows = traces['cycle'].records
        assert sum(int(r['pc'],0) == symbols['hot_op'] for r in rows) == 10
        assert sum(int(r['pc'],0) == symbols['pf_handler'] for r in rows) == 1
        assert any(r.get('pipe') == 'V' and r.get('paired') and int(r['pc'],0) == symbols['pair_v'] for r in rows)
        return dict(case=case,model=name,latency=latency,full_qemu_diff=True,
                    faulting_scalar_dispatches=dispatch_faults,records=len(rows))

    result = dict(passed=False,measurements=[],errors=[],gameplay_ipc=None,standard_suite=False)
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            prepared = list(pool.map(prepare,itertools.product(range(3),(0,1),(0,1))))
        jobs = [(p,n,l) for p in prepared for n in models for l in (0,7)]
        with ThreadPoolExecutor(max_workers=32) as pool:
            futures = [pool.submit(measure,job) for job in jobs]
            for future in futures:
                try:
                    result['measurements'].append(future.result())
                except Exception as exc:
                    result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
        assert len(result['measurements']) == 48 and not result['errors']
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged'] = all(sha(p) == h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save(args.out/'result.json',result)
    print(json.dumps({k:v for k,v in result.items() if k != 'measurements'},indent=2),flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
