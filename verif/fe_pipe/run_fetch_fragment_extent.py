"""Actual source-extracted fragment/fetch leaf, both demand profiles and mutants.

Run under tools/build_scope.sh and a retained, bounded systemd owner. Native
children inherit explicit CPU13-16 affinity; all wait/reap and source receipts
are retained under the external scratch filesystem. No production RTL edits.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import time

import prepare_fetch_fragment_extent as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root, parent = args.out.resolve(), args.parent.resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == set(range(13,17)) and os.environ['INVOCATION_ID']
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], check=True, pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime',
        os.environ['VENTIUM_BUILD_SCOPE_UNIT']+'.scope','MemoryMax=2G','MemorySwapMax=0'],
        check=True,timeout=10)
    subprocess.run([REPO/'tools/verilator_serial.sh','--version'], check=True, timeout=10)
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    source = parent/'candidate'/recipe.FILE
    bus = parent/'candidate/rtl/core/core_bus_driver.svh'
    old = source.read_text(); changed = recipe.transform(old)
    template = (HERE/'tb_fetch_fragment_extent.sv').read_text()
    leaf, body = template.split('\nmodule tb_fetch_fragment_extent;', 1)
    replacements = {'/* SIZE */':recipe.fetch_size(old), '/* BUS */':recipe.fetch_bus(bus.read_text())}
    for before, after in replacements.items():
        assert leaf.count(before)==1
        leaf = leaf.replace(before, after)
    new_cross = recipe.NEW.split('`ifndef SYNTHESIS')[0]
    variants = {'old':recipe.OLD, 'new':new_cross,
        'bad_guard':new_cross.replace('!((state == S_FETCH) && sfetch_boundary) &&', ''),
        'bad_width':new_cross.replace("{9'd0, cur_data_size}", "13'd4")}
    assert len(set(variants.values())) == 4
    pins = {str(p):sha(p) for p in (source,bus,Path(__file__),Path(recipe.__file__),
        HERE/'tb_fetch_fragment_extent.sv',HERE/'test_fetch_fragment_extent.py',
        REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',
        Path(os.environ['VENTIUM_VERILATOR_BIN']),Path('/usr/bin/z3'))}
    root.mkdir()
    def save(path, text):
        with path.open('x') as stream: stream.write(text)
    def generated(name, text):
        path=root/name; save(path,text); pins[str(path)]=sha(path); return path
    generated('core.sv',changed)
    sources = [generated(name+'.sv',leaf.replace('fetch_fragment_leaf', 'fetch_fragment_leaf_'+name)
                         .replace('/* CROSS */',text)) for name,text in variants.items()]
    sources.append(generated('tb.sv','`timescale 1ns/1ps\nmodule tb_fetch_fragment_extent;'+body))
    result = dict(passed=False,errors=[],native=[],pins=pins,proofs=[],profiles=[],
        invocation=os.environ['INVOCATION_ID'],scope=os.environ['VENTIUM_BUILD_SCOPE_UNIT'],
        whole_core=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    save(root/'started.json',json.dumps(result,indent=2)+'\n')
    began=time.monotonic()
    def native(command, name, seconds, stdin=None):
        assert time.monotonic()-began<400 and shutil.disk_usage(scratch).free>4*1024**3
        log=root/(name+'.log'); start=time.monotonic()
        with log.open('x') as stream:
            child=subprocess.Popen(command,stdout=stream,stderr=subprocess.STDOUT,
                stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                pass_fds=(9,),start_new_session=True)
            try:
                affinity=sorted(os.sched_getaffinity(child.pid)); assert affinity==list(range(13,17))
                child.communicate(stdin,timeout=seconds)
                code=child.wait()
            finally:
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGKILL); child.wait()
        row=dict(command=list(map(str,command)),native_exit=code,actual_wait=True,
            reaped=not Path('/proc',str(child.pid)).exists(),affinity=affinity,
            seconds=time.monotonic()-start,log=str(log),sha256=sha(log))
        result['native'].append(row)
        assert row['reaped']
        return code,log.read_text()
    try:
        for mutant in (None,'no-exclusion','fixed-width','lost-page-clamp'):
            label=mutant or 'equivalence'; query=generated(label+'.smt2',recipe.symbolic(mutant))
            code,log=native(['/usr/bin/z3',query],label,10)
            expected='sat' if mutant else 'unsat'
            assert code==0 and log.strip()==expected, log
            result['proofs'].append(dict(name=label,result=expected))
        for enabled in (False,True):
            label='demand'+str(int(enabled)); folder=root/label; folder.mkdir()
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv',
                '-j','32','--threads','1','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *(['+define+VEN_SFETCH16_DEMAND'] if enabled else []),
                '--top-module','tb_fetch_fragment_extent','--Mdir',folder/'obj','-o','test',*sources]
            code,log=native(command,label+'-build',90); assert code==0, log[-2000:]
            model=folder/'obj/test'; pins[str(model)]=sha(model)
            for mutant in (0,1,2):
                code,log=native([model,'+mutant='+str(mutant)],label+'-mutant'+str(mutant),60)
                if mutant==0:
                    assert code==0 and 'FETCH-FRAGMENT-OK checks=8529920 ' in log,log
                else:
                    assert code in (-6,1,134) and 'FETCH-FRAGMENT-MISMATCH' in log,log
            result['profiles'].append(dict(demand16=enabled,checks=8529920,mutants_failed=2))
        result['passed']=True
    except Exception as exc:
        import traceback
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    events=dict(line.split() for line in (cg/'memory.events').read_text().splitlines())
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  seconds=time.monotonic()-began,memory_peak=int((cg/'memory.peak').read_text()),memory_events=events)
    result['passed'] &= result['pins_unchanged'] and all(int(v)==0 for k,v in events.items() if k.startswith('oom'))
    save(root/'closed.json',json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','native')},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__':
    raise SystemExit(main())
