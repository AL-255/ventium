#!/usr/bin/env python3
"""Actual overlap guard: masked/raw INTR A/B, strict required failure."""
import argparse,hashlib,json,os,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
for k in ('control-rtl','candidate-rtl','out'):p.add_argument('--'+k,type=Path,required=True)
a=p.parse_args();here=Path(__file__).resolve().parent;repo=here.parents[1]
scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
assert __debug__ and a.out.resolve().is_relative_to(scratch)
assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
a.out.mkdir();base=here/'tb_prefix_ex_system_guards.sv';text=base.read_text()
edits={
    '  logic clk=0,rst_n=0;':'  logic clk=0,rst_n=0;\n  logic [31:0] eflags;',
    '    eip=32\'h200;':'    eflags=32\'h202;\n    eip=32\'h200;',
    '    $display("PREFIX-EX-SYSTEM-GUARDS-OK checks=%0d",checks);':'''    // IF=0 only changes admission of maskable raw INTR, never NMI/SMI or
    // the independently resolved delivery permit. Older EXT/IMUL preserves IF.
    defaults();intr=1;eflags[9]=0;
`ifdef REQUIRE_MASKED_IRQ_PROGRESS
    #1;if(!p54_prefix_ex_take)$fatal(1,"MASKED-INTR-BLOCKED-PREFIX-OVERLAP");
    check(1);
`else
    check(0);
`endif
    intr_take=1;check(0);
    defaults();intr=1;eflags[9]=0;nmi=1;check(0);
    defaults();intr=1;eflags[9]=0;smi_pending=1;check(0);
    $display("PREFIX-EX-MASKED-IRQ-OK checks=%0d",checks);''',
}
for old,new in edits.items():
    assert text.count(old)==1,old;text=text.replace(old,new)
tb=a.out/base.name;tb.write_text(text)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
pins={str(p.resolve()):sha(p) for p in (Path(__file__),base,tb)}
result=dict(passed=False,variants=[],gameplay_ipc=None,standard_suite=False)
try:
    for name,rtl,expect,negative in (
        ('control',a.control_rtl,False,False),
        ('candidate',a.candidate_rtl,True,False),
        ('required-failure',a.control_rtl,True,True)):
        rtl=rtl.resolve(strict=True);out=a.out/name;out.mkdir()
        sources=[rtl/'ventium_pkg.sv',rtl/'core/ventium_alu_pkg.sv',rtl/'core/ventium_decode_pkg.sv',tb]
        pins.update({str(p):sha(p) for p in [*sources,rtl/'core/core_prefix_ex_chain.svh']})
        defs=['VTM_NO_DPI','VEN_P54_PREFIX_EX_CHAIN','VEN_P54_PREFIX_EX_SYSTEM',
              'VEN_P54_INT_EXEC_OCC','VEN_PIPE_SDISPATCH','VEN_PIPE_SDECODE',
              'VEN_L1_AXI','VEN_IC_BRAM','VEN_FP_PIPE','VEN_FP_PIPE2','VEN_DBG_CORE']
        if expect:defs.append('REQUIRE_MASKED_IRQ_PROGRESS')
        cmd=[str(repo/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
             '-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+x for x in
             ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
             *['+define+'+d for d in defs],'-I'+str(rtl/'core'),'--top-module',
             'tb_prefix_ex_system_guards','--Mdir',str(out/'obj'),'-j','1',*map(str,sources)]
        (out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
        with (out/'build.log').open('x') as f:
            rc=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=180,pass_fds=(9,)).returncode
        row=dict(name=name,build_exit=rc);result['variants'].append(row);assert rc==0
        with (out/'run.log').open('x') as f:
            rc=subprocess.run([out/'obj/Vtb_prefix_ex_system_guards'],stdout=f,
                              stderr=subprocess.STDOUT,timeout=30).returncode
        row['native_exit']=rc;log=(out/'run.log').read_text()
        if negative:
            assert rc in (1,-6,134) and '%Fatal:' in log and 'MASKED-INTR-BLOCKED-PREFIX-OVERLAP' in log
            row['expected_assertion']=True
        else:assert rc==0 and 'PREFIX-EX-MASKED-IRQ-OK checks=4171' in log
    result['passed']=True
finally:
    result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['passed'] &= result['inputs_unchanged']
    (a.out/'pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    (a.out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)
