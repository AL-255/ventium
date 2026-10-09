#!/usr/bin/env python3
"""Real PIC IRQ5 versus RTL held pins after m64 admission; complete state diff.

Flat CS only: this is standalone PIC/core-pin coverage, not full-PC acceptance.
The RTL event-entry ABI records are compared separately, never discarded.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import tracefmt
import check_faultlog
from x87_event_compare import compare_complete


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f:
        json.dump(value, f, indent=2)


def split_entries(trace, marker, boundary, handler):
    rows = trace.records
    indices = [i for i in range(1, len(rows)-1)
               if [int(rows[j]['pc'], 0) for j in (i-1, i, i+1)] == [marker, boundary, handler]]
    assert len(indices) == 16, ('IRQ entry ABI count', indices)
    entries = tracefmt.Trace(trace.hdr, [dict(rows[j], n=i) for i,j in enumerate(indices)])
    excluded = set(indices)
    instructions = tracefmt.Trace(trace.hdr, [dict(row, n=i) for i,row in enumerate(
        row for j,row in enumerate(rows) if j not in excluded)])
    return entries, instructions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models = {name: getattr(args, name).resolve(strict=True) for name in ('control','candidate')}
    pins, profiles = {}, {}
    for name, tb in models.items():
        stamp = tb.parent/'Vventium_top__verFiles.dat'
        command = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)', command))
        assert {'VEN_L1_AXI','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_FE_PIPE',
                'VEN_FP_SHARED','VEN_FP_ASYNC_STREAM','VEN_FP_MEM_QUEUE'} <= defs
        assert ' --assert ' in command
        assert not {'VEN_UOPCACHE','VTM_NO_DPI','SYNTHESIS','VEN_SYS_FASTPATH_ALL'} & defs
        profiles[name] = defs
        pins.update({str(p):sha(p) for p in (tb,stamp)})
    assert 'VEN_FP_MEM_QUEUE64' not in profiles['control']
    added = profiles['candidate']-profiles['control']
    assert added in ({'VEN_FP_MEM_QUEUE64'}, {'VEN_FP_MEM_QUEUE64','VEN_FP_SCALAR_DISPATCH'})
    assert profiles['control'] <= profiles['candidate']
    source = REPO/'verif/fe_pipe/fp-mem64-queue.S'
    generator = REPO/'verif/fe_pipe/prepare-fp-mem64-irq.py'
    linker = REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), source, generator, linker, qemu,
              REPO/'verif/fe_pipe/prepare-fp-mem64-event.py',
              REPO/'verif/sys/x87_queue_irq_oracle.py', REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py', REPO/'verif/diff/compare.py',
              REPO/'verif/sys/check_faultlog.py', REPO/'verif/sys/x87_event_compare.py',
              REPO/'verif/tb/irq_inject_probe.h'):
        pins[str(p)] = sha(p)
    save(args.out/'inputs.json', pins)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(argv, leaf, stem, expected=0, extra=None):
        argv = ['timeout','--kill-after=3s','60s',*map(str,argv)]
        save(leaf/(stem+'.command.json'), dict(argv=argv, cwd=str(leaf), environment=extra))
        with (leaf/(stem+'.stdout')).open('x') as out, (leaf/(stem+'.stderr')).open('x') as err:
            rc = subprocess.run(argv, cwd=leaf, env=dict(env, **(extra or {})),
                                stdout=out, stderr=err, pass_fds=(9,)).returncode
        save(leaf/(stem+'.exit.json'),dict(exit=rc))
        assert rc == expected, (stem,rc,expected)

    def prepare(case):
        kind, drain = case
        leaf = args.out/f'k{kind}-d{drain}'
        leaf.mkdir()
        run([sys.executable,'-B',generator,'--source',source,'--out',leaf/'fixture.S'],leaf,'generate')
        run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
             f'-DKIND={kind}',f'-DDRAIN={drain}','-DRELOC=0','-DEVENT_GP=0',
             '-c','fixture.S','-o','fixture.o'],leaf,'assemble')
        run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
             '-Wl,--build-id=none','fixture.o','-o','fixture.elf'],leaf,'link')
        run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',
             'fixture.elf','fixture.bin'],leaf,'binary')
        symbols = {p[2]:int(p[0],16) for line in subprocess.check_output(
            ['nm','-n',leaf/'fixture.elf'],text=True).splitlines() if len(p:=line.split())==3 and p[0]!='U'}
        assert (leaf/'fixture.bin').stat().st_size == 65536
        # Short relative Unix-socket names avoid sockaddr_un's length limit.
        code = ('import sys;sys.path.insert(0,'+repr(str(REPO/'verif/sys'))+');'
                'from x87_queue_irq_oracle import generate;'
                f'generate("fixture.bin","golden.vtrace",{symbols["integer_begin"]},'
                f'{symbols["irq_boundary"]},{symbols["event_handler"]},count=16)')
        run([sys.executable,'-B','-c',code],leaf,'golden')
        gold = tracefmt.read_trace(str(leaf/'golden.vtrace'))
        entries = tracefmt.read_trace(str(leaf/'qemu-irq-events.vtrace'))
        assert 100 < len(gold.records) < 2500 and len(entries.records)==16
        assert int(gold.records[-1]['eax'],0)&255 == 0x42
        return case,leaf,symbols,gold,entries

    def measure(job):
        (case,leaf,symbols,gold,entries),name,latency = job
        results = {}
        for mode in ('cycle-func','cycle'):
            stem = f'{name}-l{latency}-{mode}'
            extra = dict(AXI_RLAT=str(latency),AXI_WLAT=str(latency),
                         VEN_TEST_IRQ_PC=hex(symbols['integer_begin']),
                         VEN_TEST_IRQ_VECTOR='69',VEN_TEST_IRQ_COUNT='16')
            run([models[name],'+ven_fp_mem_queue_log','+ven_faultlog','--system','--cosim','--x87',
                 '--'+mode,'--l1-axi','--image',leaf/'fixture.bin','--out',leaf/(stem+'.vtrace'),
                 '--max-insn','2500','--max-cycles','3000000','--quiesce','200000'],leaf,stem,133,extra)
            stdout,stderr = [(leaf/(stem+ext)).read_text() for ext in ('.stdout','.stderr')]
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL|\[TEST-IRQ\] FAIL',stdout+stderr)
            check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),{(69,0):16})
            requests = re.findall(r'^\[TEST-IRQ\] REQUEST n=(\d+) cycle=(\d+) pc=([0-9a-f]+) next=([0-9a-f]+) owners=(\d+) vector=69$',stderr,re.M)
            acks = re.findall(r'^\[TEST-IRQ\] INTA n=(\d+) cycle=(\d+) next=([0-9a-f]+) owners=0 vector=69$',stderr,re.M)
            assert len(requests)==len(acks)==16
            assert [int(r[0]) for r in requests]==[int(r[0]) for r in acks]==list(range(1,17))
            assert all(int(r[2],16)==symbols['integer_begin'] and int(r[3],16)==symbols['irq_boundary'] for r in requests)
            assert all(int(a[2],16)==symbols['irq_boundary'] and int(a[1])>int(r[1]) for a,r in zip(acks,requests))
            assert '[TEST-IRQ] PASS requests=16 acknowledgements=16 vector=69' in stderr
            pending = sum(int(r[4])>=2 for r in requests)
            queued = sum(int(pc,16)==symbols['source_op'] and int(owners)>0 for pc,owners in
                         re.findall(r'\[FP-MEM-QUEUE\] ACCEPT pc=([0-9a-f]+) owners=(\d+)',stdout))
            if name=='control' or case[1]:
                assert pending==queued==0
            else:
                assert pending>0 and queued>0, ('missing real pending queue at IRQ',case,latency)
            raw = tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
            irq,actual = split_entries(raw,symbols['integer_begin'],symbols['irq_boundary'],symbols['event_handler'])
            assert [r['pc'] for r in actual.records]==[r['pc'] for r in gold.records]
            assert sum(int(r['pc'],0)==symbols['event_handler'] for r in actual.records)==16
            if mode=='cycle-func':
                for suffix,a,b in (('irq',entries,irq),('instructions',gold,actual)):
                    with (leaf/(stem+'-'+suffix+'-diff.log')).open('x') as log:
                        assert compare_complete(a,b,log)==0,(case,name,latency,suffix)
            else:
                assert any(r.get('pipe')=='V' and r.get('paired') and int(r['pc'],0)==symbols['pair_v'] for r in actual.records)
            results[mode] = dict(queued=queued,pending_at_irq=pending,records=len(actual.records))
        assert results['cycle']==results['cycle-func']
        return dict(case=case,model=name,latency=latency,passed=True,**results['cycle'])

    result = dict(passed=False,cases=[],errors=[],gameplay_ipc=None,standard_suite=False)
    try:
        # Oracle ports are OS assigned; serialize QEMU preparation to avoid
        # reuse races in the unchanged real-PIC generator. RTL fanout is 32.
        cases = [(k,d) for k in ((0,6,7) if args.smoke else range(8)) for d in (0,1)]
        prepared = [prepare(c) for c in cases]
        jobs = [(c,n,l) for c in prepared for n in models for l in (0,7)]
        with ThreadPoolExecutor(max_workers=32) as pool:
            for future in [pool.submit(measure,j) for j in jobs]:
                try:result['cases'].append(future.result())
                except Exception as exc:result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
        assert len(result['cases'])==len(jobs) and not result['errors']
        result['passed']=True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save(args.out/'result.json',result)
    print(json.dumps(dict(passed=result['passed'],cases=len(result['cases']),
                         errors=result['errors'][:2],inputs_unchanged=result['inputs_unchanged'])),flush=True)
    assert result['passed']


if __name__=='__main__':
    main()
