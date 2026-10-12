"""Original 22 fetch-boundary cases: full QEMU state and exact UV-fast A/B.

Prebuilt models/fixtures only. Native children use the existing bounded group
supervisor inside a separate 2048-task service, not the compiler's 128-task scope.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback

REPO=Path(__file__).resolve().parents[2]
HERE=REPO/'verif/sys/tests/pfetchbound'
sys.path[:0]=[str(HERE),str(REPO/'verif/diff')]
import check_witness as checks
import compare
spec=importlib.util.spec_from_file_location('fetch_native',REPO/'verif/sys/run-native-system.py')
native=importlib.util.module_from_spec(spec); spec.loader.exec_module(native)
contracts=checks.contracts; tracefmt=contracts.tracefmt; sha=native.digest


def save(path,value):
    with path.open('x') as stream: json.dump(value,stream,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate','fixtures','out'): ap.add_argument('--'+name,type=Path,required=True)
    ap.add_argument('--port-base',type=int,default=45200)
    args=ap.parse_args(); root=args.out.resolve(); fixtures=args.fixtures.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert 1024<=args.port_base<=65514
    models={}; profiles={}; pins={}
    for name in ('parent','candidate'):
        build=getattr(args,name).resolve(strict=True)
        closed=json.loads((build/'build-closed.json').read_text())
        assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
        model=build/'obj/tb_ventium'; record=build/'obj/Vventium_top__verFiles.dat'
        profiles[name]=contracts.validate_build(model,closed['binary_sha256'],record,sha(record),[])
        assert ' --assert ' in record.read_text()
        assert {'VEN_L1_AXI','VEN_L1D_PERF','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC'}<=set(profiles[name])
        assert not {'SYNTHESIS','VTM_NO_DPI'}&set(profiles[name])
        pins.update(json.loads((build/'build-started.json').read_text())['pins'])
        for p in (model,record,build/'build-started.json',build/'build-closed.json'): pins[str(p)]=sha(p)
        models[name]=model
    assert profiles['parent']==profiles['candidate']
    contracts.pin(contracts.QEMU,contracts.QEMU_SHA)
    checks.validate_manifest(json.loads((HERE/'manifest.json').read_text()))
    for p in [*fixtures.glob('pfetchbound_*.bin'),*fixtures.glob('pfetchbound_*.elf'),
              HERE/'pfetchbound.S',HERE/'pfetchbound.ld',HERE/'Makefile',HERE/'manifest.json',
              Path(__file__).resolve(),Path(checks.__file__),checks.SHARED,Path(native.__file__),
              Path(tracefmt.__file__),Path(compare.__file__),contracts.QEMU,
              REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/sys/check_faultlog.py']:
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    for key in list(os.environ):
        if key.startswith(('AXI_','TB_','QEMU_','VEN_','VTM_')): del os.environ[key]
    root.mkdir(); affinity=sorted(os.sched_getaffinity(0))
    save(root/'started.json',dict(pins=pins,profiles=profiles,affinity=affinity,
        invocation=os.environ['INVOCATION_ID'],workers=22,cycle_mode=1))
    begin=time.monotonic(); deadline=begin+480
    result=dict(passed=False,errors=[],rows=[],canonical_gate_passed=False,standard_suite=False,
                gameplay_ipc=None,hardware_acceptance=False)

    def run(leaf,label,argv,expected=0):
        allowance=min(60,deadline-time.monotonic())
        assert allowance>0
        out,err,receipt=[leaf/(label+s) for s in ('.stdout','.stderr','.exit.json')]
        receipt=native.supervise(argv,out,err,receipt,allowance)
        assert receipt['actual_return_code']==expected and receipt['group_closed'] and receipt['actual_wait'],(label,receipt)
        return out.read_text(),err.read_text()

    def case(case):
        leaf=root/f'case{case}'; leaf.mkdir()
        image=fixtures/f'pfetchbound_{case}.bin'; elf=image.with_suffix('.elf')
        sym,bios=contracts.symbols(elf),image.read_bytes()
        checks.validate_image(case,sym,bios)
        run(leaf,'free-qemu',[contracts.QEMU,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
            '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
            '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
        golden=leaf/'golden.vtrace'
        out,err=run(leaf,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py',
            '--qemu',contracts.QEMU,'--system','--image',image,'--image-mode','bios','--cpu','pentium',
            '--max-insn',str(checks.MAX_INSN),'--port',str(args.port_base+case-1),'--out',golden])
        gold=contracts.read_complete_trace(golden)
        checks.grade_golden(case,gold,out+err,sym,bios,0,133)
        rows=[]
        for latency in (0,7):
            both={}
            for name,model in models.items():
                traces={}; clocks={}; witness_count=0
                for mode in ('cycle-func','cycle'):
                    label=f'{name}-lat{latency}-{mode}'; actual=leaf/(label+'.vtrace')
                    out,err=run(leaf,label,['env',f'AXI_RLAT={latency}',f'AXI_WLAT={latency}',model,
                        '--cosim','--system','--'+mode,'--l1-axi','--image',image,'--out',actual,
                        '--max-insn',str(checks.MAX_INSN),'--max-cycles','1000000','--quiesce','4096',
                        '+ven_faultlog','+ven_fetch_probe_payload_witness'],133)
                    trace=tracefmt.read_trace(str(actual)); traces[mode]=trace.records
                    assert [r['n'] for r in trace.records]==list(range(len(gold.records)))
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                    assert not native.FATAL.search(out+err)
                    if mode=='cycle-func':
                        checked=checks.grade_native(case,trace,out,err,sym,bios,133)
                        clocks[mode]=native.grade_native(trace,out,err,133,133,checks.MAX_INSN)['clocks']
                        with (leaf/(label+'.diff.log')).open('x') as stream:
                            assert compare.compare_func(gold,trace,False,0xffffffff,False,20,stream,sys_both=True)==0
                    else:
                        clocks[mode]=int(re.search(r'after \d+ retired in (\d+) clocks',err)[1])
                    backing=re.findall(r'^\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)$',out,re.M)
                    assert len(backing)==1 and int(backing[0][0])>0 and int(backing[0][2])>0
                    witness_count+=len(re.findall(r'^\[FETCH-PROBE-PAYLOAD\]',out,re.M))
                assert clocks['cycle']==clocks['cycle-func']
                both[name]=traces
                rows.append(dict(case=case,model=name,latency=latency,records=len(traces['cycle']),
                    clocks=clocks['cycle'],probe_witnesses=witness_count,
                    paired_v=sum(r.get('pipe')=='V' and r.get('paired') for r in traces['cycle'])))
            assert both['parent']==both['candidate'],('complete A/B mismatch',case,latency)
        print(f'FETCH-PROBE case{case} complete QEMU/state/cycle A/B PASS',flush=True)
        return rows

    try:
        with ThreadPoolExecutor(max_workers=22) as pool:
            futures={pool.submit(case,i):i for i in checks.CASES}
            for future in as_completed(futures):
                try: result['rows'].extend(future.result())
                except Exception as error:
                    result['errors'].append(dict(case=futures[future],error=repr(error),traceback=traceback.format_exc()))
        assert not result['errors'] and len(result['rows'])==88
        candidate=[r for r in result['rows'] if r['model']=='candidate']
        assert any(r['probe_witnesses'] for r in candidate)
        result.update(passed=True,candidate_records=sum(r['records'] for r in candidate),
            paired_v=sum(r['paired_v'] for r in candidate),probe_witnesses=sum(r['probe_witnesses'] for r in candidate))
        assert result['paired_v']>0
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
        result['passed']=False
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
