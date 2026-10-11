#!/usr/bin/env python3
"""Check real AXI bytes during crossing-IDT replacement, using passive host GDB.

The CPU is free-running in UV-fast mode. A native host breakpoint reads the
generated model at each rising-edge NBA boundary; no guest debugger request,
HDL force, register/memory injection or native model patch is performed.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

from observe_fragment_abort_bus import FIELDS, sha
from build_fragment_exact_core import stable, save, load


def check_bytes(rows, first):
    """Independent oracle: both fragments cover exactly the intended four bytes."""
    assert first in (1,2,3) and rows and rows[0]['event']=='replacement'
    initial=rows[0]
    assert all(initial[key]==1 for key in ('fx_act','fx_abort_q','fx_start','mem_req'))
    assert initial['state']==42 and initial['cur_lin_nat']==0x9000-first
    assert initial['cur_size']==4 and initial['fx_first']==2 and initial['bd_we']==0
    assert initial['mem_wstrb']==(1<<first)-1, 'replacement used wrong first-fragment mask'
    assert rows[-1]['event']=='first-beat-complete'
    assert all(row['clk']==1 and row['__VnbaTriggered']&1 for row in rows)
    touched={0:Counter(),1:Counter()}; transfers=[]
    for row in rows:
        if row['event']!='axi-ar':
            continue
        phase=row['fx_ph']; assert phase in (0,1)
        start,count=(0x9000-first,first) if phase==0 else (0x9000,4-first)
        assert row['fbase']==start and row['bypass']==1 and row['byp_strobes']==(1<<count)-1
        assert row['fx_act']==1 and row['fx_wr']==0 and row['fx_abort_q']==0
        assert row['m_axi_arvalid']==row['m_axi_arready']==1 and row['m_axi_arlen']==0
        width=1<<row['m_axi_arsize']; address=row['m_axi_araddr']
        assert width in (1,2,4) and address%width==0
        assert start<=address and address+width<=start+count, 'AXI overread outside fragment'
        touched[phase].update(range(address,address+width))
        transfers.append(dict(phase=phase,address=address,bytes=width))
    for phase in (0,1):
        start,count=(0x9000-first,first) if phase==0 else (0x9000,4-first)
        assert touched[phase]==Counter(range(start,start+count)), 'missing or duplicate read byte'
    final_acks=[row for row in rows if row['event']=='core-ack']
    assert len(final_acks)==1 and final_acks[0]['fx_ph']==1
    return transfers


def offset_source():
    lines=['#include <cstddef>','#include <cstdio>','#include <type_traits>',
        '#include "Vventium_top___024root.h"','using Root=Vventium_top___024root;',
        'static_assert(std::is_standard_layout_v<Root>);','int main() { std::printf("{");']
    for index,(key,member) in enumerate(FIELDS.items()):
        prefix=',' if index else ''
        lines.append(f'std::printf("{prefix}\\\"{key}\\\":[%zu,%zu]", '
                     f'offsetof(Root,{member}),sizeof(Root::{member}));')
    return '\n'.join(lines+['std::printf("}\\n"); }'])+'\n'


SCRIPT='''set pagination off
set confirm off
set print thread-events off
set disable-randomization off
python
import gdb,json
offsets=OFFSETS
first=FIRST
class Observe(gdb.Breakpoint):
    def __init__(self):
        super().__init__('Vventium_top___024root___eval_nba(Vventium_top___024root*)',internal=True)
        self.armed=False
        self.count=0
    def stop(self):
        base=int(gdb.parse_and_eval('$rdi'))
        inferior=gdb.selected_inferior()
        row={k:int.from_bytes(bytes(inferior.read_memory(base+v[0],v[1])),'little') for k,v in offsets.items()}
        if row['clk']!=1 or not row['__VnbaTriggered']&1:
            return False
        if not self.armed:
            if not all(row[k]==1 for k in ('fx_act','fx_abort_q','fx_start','mem_req')):
                return False
            if row['state']!=42 or row['cur_lin_nat']!=0x9000-first:
                return False
            self.armed=True
            row['event']='replacement'
        elif row['state']!=42 or row['cur_lin_nat']!=0x9000-first:
            row['event']='first-beat-complete'
            self.enabled=False
        elif row['m_axi_arvalid'] and row['m_axi_arready']:
            row['event']='axi-ar'
        elif row['mem_ack']:
            row['event']='core-ack'
        else:
            return False
        self.count+=1
        print('FRAGMENT_EXACT_BUS '+json.dumps(row,sort_keys=True))
        if self.count>32:
            raise RuntimeError('unexpected bus observation volume')
        return False
watch=Observe()
end
run
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('build','corpus','matrix','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    build,corpus,matrix=(getattr(args,key).resolve(strict=True) for key in ('build','corpus','matrix'))
    out=args.out.resolve(); model=build/'obj/tb_ventium'; obj=model.parent
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and not out.exists() and Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>4*1024**3
    built,checked=load(build/'build-closed.json'),load(matrix/'closed.json')
    assert built['passed'] and built['binary_sha256']==sha(model) and checked['passed']
    assert stable(checked['pins'])
    paths=[Path(__file__),Path(__file__).with_name('observe_fragment_abort_bus.py'),model,
        obj/'Vventium_top___024root.h',obj/'Vventium_top__verFiles.dat',
        build/'build-closed.json',matrix/'closed.json']
    pins={str(path):sha(path) for path in paths}; out.mkdir()
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)),passive_host_observer=True))
    errors=[]; rows=[]; cases=[]; began=time.monotonic()

    def write(path,text):
        with path.open('x') as stream:stream.write(text)
        pins[str(path)]=sha(path)

    def run(leaf,label,argv,expected=0,latency=0):
        argv=['timeout','--signal=TERM','--kill-after=2s','60s',*map(str,argv)]
        save(leaf/(label+'.command.json'),argv)
        with (leaf/(label+'.stdout')).open('x') as stdout,(leaf/(label+'.stderr')).open('x') as stderr:
            native=subprocess.run(argv,stdout=stdout,stderr=stderr,
                env={**os.environ,'AXI_RLAT':str(latency),'AXI_WLAT':str(latency)})
        rows.append(dict(label=str(leaf.name)+'/'+label,native_exit=native.returncode,
            stdout_sha256=sha(leaf/(label+'.stdout')),stderr_sha256=sha(leaf/(label+'.stderr'))))
        assert native.returncode==expected,rows[-1]
        text=(leaf/(label+'.stdout')).read_text()+(leaf/(label+'.stderr')).read_text()
        assert 'Error occurred in Python' not in text
        return (leaf/(label+'.stdout')).read_text()

    try:
        write(out/'offsets.cpp',offset_source())
        run(out,'offset-build',['g++','-std=c++20','-O0','-I'+str(obj),
            '-I/tools/verilator/v5.046/share/verilator/include',
            '-I/tools/verilator/v5.046/share/verilator/include/vltstd',out/'offsets.cpp','-o',out/'offsets'])
        offsets=json.loads(run(out,'offsets',[out/'offsets']))
        assert all(width in (1,4,8) for _,width in offsets.values()); save(out/'offsets.json',offsets)
        for first in (1,2,3):
            name=f'first{first}-warm1-cd1'; case=corpus/name
            for latency in (0,7):
                leaf=out/(name+f'-lat{latency}'); leaf.mkdir()
                image=case/'fixture.bin'; previous=matrix/name/f'lat{latency}-cycle-func.vtrace'
                pins.update({str(path):sha(path) for path in (image,previous)})
                write(leaf/'observe.gdb',SCRIPT.replace('OFFSETS',repr(offsets)).replace('FIRST',str(first)))
                text=run(leaf,'observe',['gdb','-nx','-batch','--return-child-result','-x',leaf/'observe.gdb',
                    '--args',model,'--system','--cosim','--l1-axi','--cycle-func','--image',image,
                    '--out',leaf/'observed.vtrace','--max-insn','3000','--max-cycles','3000000',
                    '--quiesce','8000','+ven_faultlog'],133,latency)
                observed=[json.loads(line.removeprefix('FRAGMENT_EXACT_BUS ')) for line in text.splitlines()
                          if line.startswith('FRAGMENT_EXACT_BUS ')]
                save(leaf/'observations.json',observed)
                transfers=check_bytes(observed,first)
                assert (leaf/'observed.vtrace').read_bytes()==previous.read_bytes()
                result=dict(name=name,latency=latency,passed=True,transfers=transfers,
                    whole_trace_bytes_identical=True,observations_sha256=sha(leaf/'observations.json'))
                save(leaf/'closed.json',result); cases.append(result)
    except Exception as error:
        errors.append(dict(error=repr(error),traceback=traceback.format_exc()))
    unchanged=stable(pins)
    result=dict(passed=not errors and len(cases)==6 and unchanged,cases=cases,errors=errors,
        pins=pins,pins_unchanged=unchanged,rows=rows,seconds=time.monotonic()-began,
        byte_exact_replacement_cases=len(cases),standard_suite=False,gameplay_ipc=None)
    save(out/'closed.json',result)
    print(json.dumps({key:value for key,value in result.items() if key not in ('pins','rows')},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
