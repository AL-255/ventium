"""Prove and simulate the actual admission expressions, including bad controls.

The leaf abstracts unchanged decode/width producers as independent inputs.
It is not a sequential full-core proof, gameplay run or frequency measurement.
"""
import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time

import prepare_fast_segment as recipe
from run_leaf import sha

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WRAPPER = """module NAME(
  input logic sys_fp_ok, real_mode, cs_d, sys_mode, fp_dbg_active, stk_is16,
  input logic [3:0] decoded, memory_form,
  input logic [2:0] pipe_mem_seg,
  input logic [31:0] pipe_load_addr,
  input logic [7:0] seg_attr [6],
  input logic [31:0] seg_limit [6], seg_base [6],
  input logic seg_pm_loaded [6],
  input logic [15:0] seg_sel [6],
  output logic out_load, out_store, out_bail,
  output logic [31:0] out_lin
);
  localparam int NUM_SEG=6, SG_DS=2, SG_SS=1;
  typedef struct packed {logic simple,is_stack,is_store,is_mem;} decoded_t;
  typedef struct packed {logic [2:0] source_width; logic w8;} fpd_t;
  decoded_t u_d;
  fpd_t pipe_u_eff;
  assign u_d=decoded;
  assign pipe_u_eff=memory_form;
  function automatic logic [2:0] fp_mem_source_width(input fpd_t d);
    return d.source_width;
  endfunction
  /* BODY */
  assign out_load=sys_fp_load_ok;
  assign out_store=sys_fp_store_ok;
  assign out_bail=fp_sys_bail;
  assign out_lin=sys_fp_store_lin;
endmodule
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    parent, root = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == set(range(32))-{11}
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'], check=True, timeout=10)
    subprocess.run([REPO/'tools/verilator_serial.sh','--version'], check=True, timeout=10)
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    original = (parent/'candidate'/recipe.FILE).read_text()
    candidate = recipe.transform(original)
    definitions = json.loads((parent/'build-started.json').read_text())['definitions']
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTLOAD_BOUNDED','VEN_SYS_FASTSTORE_FLAT',
            'VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC'} <= set(definitions)
    old_leaf, new_leaf = recipe.leaf(original), recipe.leaf(candidate)
    variants = [('positive',new_leaf,definitions)]
    mutations = [('wrong-segment', "SG_DS", "SG_SS"),
                 ('expand-down', '!seg_attr[fs][2]', "1'b1"),
                 ('inclusive-page', 'pipe_load_addr[31:12] < seg_limit[SG_DS][31:12]',
                  'pipe_load_addr[31:12] <= seg_limit[SG_DS][31:12]'),
                 ('word-boundary', "12'hFFE", "12'hFFC")]
    for name,before,after in mutations:
        assert before in new_leaf
        variants.append((name,new_leaf.replace(before,after),definitions))
    for name,disabled in [('flat-only',{'VEN_SYS_FASTLOAD_BOUNDED'}),
                          ('load-only',{'VEN_SYS_FASTSTORE_FLAT'}),
                          ('disabled',{'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTPATH'})]:
        variants.append((name,new_leaf,[d for d in definitions if d not in disabled]))
    pins = {str(p):sha(p) for p in (Path(__file__),Path(recipe.__file__),HERE/'run_leaf.py',
        HERE/'test_fast_segment.py', HERE/'tb_fast_segment.sv', parent/'candidate'/recipe.FILE,
        parent/'build-started.json', REPO/'tools/build_scope.sh', REPO/'tools/verilator_serial.sh',
        Path(os.environ['VENTIUM_VERILATOR_BIN']), Path('/usr/bin/z3'))}
    root.mkdir()
    def write(path,text):
        with path.open('x') as stream: stream.write(text)
        pins[str(path)] = sha(path)
    def save(name,obj):
        with (root/name).open('x') as stream: json.dump(obj,stream,indent=2)
    out_source = root/'candidate'/recipe.FILE
    out_source.parent.mkdir(parents=True)
    write(out_source,candidate)
    save('started.json',dict(pins=pins,definitions=definitions,invocation=os.environ['INVOCATION_ID'],
                            affinity=sorted(os.sched_getaffinity(0))))
    rows=[]; queries=[]; begin=time.monotonic()
    result=dict(passed=False,errors=[],whole_core=False,fmax_mhz=None,hardware_acceptance=False,
                standard_suite=False,gameplay_ipc=None)
    try:
        for name,expected in [('equivalence','unsat')]+[(m[0],'sat') for m in mutations]:
            path=root/(name+'.smt2'); write(path,recipe.symbolic(None if name=='equivalence' else name))
            native=subprocess.run(['/usr/bin/z3',path],capture_output=True,text=True,timeout=20)
            write(root/(name+'.log'),native.stdout+native.stderr)
            assert native.returncode==0 and not native.stderr and native.stdout.strip()==expected
            queries.append(dict(name=name,result=expected))
        for name,body,profile in variants:
            folder=root/name; folder.mkdir(); code=folder/'miter.sv'
            modules='\n'.join(WRAPPER.replace('NAME','admission_'+label).replace('/* BODY */',text)
                              for label,text in [('old',old_leaf),('new',body)])
            write(code,(HERE/'tb_fast_segment.sv').read_text().replace('/* MODULES */',modules))
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv','-j','32',
                '-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in profile], '--top-module','tb_fast_segment',
                '--Mdir',folder/'obj','-o','test',code]
            row=dict(name=name,command=list(map(str,command))); rows.append(row)
            with (folder/'build.log').open('x') as stream:
                native=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=120)
            row['build_exit']=native.returncode; assert native.returncode==0
            with (folder/'run.log').open('x') as stream:
                native=subprocess.run([folder/'obj/test'],stdout=stream,stderr=subprocess.STDOUT,timeout=60)
            row['native_exit']=native.returncode; log=(folder/'run.log').read_text(); row['log']=log
            if name in {m[0] for m in mutations}:
                assert native.returncode in (-6,1,134) and 'FAST-SEGMENT-MISMATCH' in log
            else:
                assert native.returncode==0 and 'FAST-SEGMENT-OK checks=300704 ' in log
            row['artifacts']={str(p):sha(p) for p in (code,folder/'build.log',folder/'run.log',folder/'obj/test')}
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin,rows=rows,queries=queries,pins=pins,
        pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__':
    raise SystemExit(main())
