"""Native source-linked payload check and all-address page arithmetic proof.

Not a full-core proof: translation/side effects need the whole-core regressions.
Decoder endpoint range is checked against its exact source assignment guards.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import extract_predicates
import prepare_probe_payload as recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def decoder_range(source):
    assignments = re.findall(r'(?m)^\s*d_fetch_fault_len\s*=([^;]+);', source)
    assert assignments == ["5'd16", 'ea_shape_end', 'fetch_first_imm_end', 'd_fetch_len']
    for condition, value in (("fetch_ea_shape && ea_shape_end>5'd15", 'ea_shape_end'),
                             ("fetch_first_imm_end>5'd15", 'fetch_first_imm_end'),
                             ("d_fetch_len>5'd15", 'd_fetch_len')):
        assert len(re.findall(r'if\s*\('+re.escape(condition)+r'\)\s*'
                              r'd_fetch_fault_len='+value+';', source)) == 1


def fixture(source, mutation):
    guards = '\n'.join('assign '+name+' = '+extract_predicates.extract(source, name)+';'
                       for name in ('fetch_fault_linear', 'fetch_fault_page', 'fetch_overlength_probe'))
    # Use the actual case-arm bodies, with names renamed only for the miter.
    old = recipe.OLD_ADDRESS.split('begin\n',1)[1].rsplit('      end\n',1)[0]
    new = recipe.NEW_ADDRESS.split('begin\n',1)[1].rsplit('      end\n',1)[0]
    old = old.replace('cur_lin_nat', 'old_addr').replace('cur_size', 'old_size')
    new = new.replace('cur_lin_nat', 'new_addr').replace('cur_size', 'new_size')
    kind = re.search(r'S_DECODE: cur_is_d = ([^;]+);', recipe.NEW_KIND)[1]
    if mutation == 'previous-page': new = new.replace("+ 20'd1", "+ 20'd0")
    if mutation == 'wrong-extent': new = new.replace("4'd1", "4'd4")
    if mutation == 'data-side': kind = "1'b1"
    if mutation == 'lost-wrap': new = new.replace("flin[31:12] + 20'd1", "flin[31:12] == 20'hfffff ? 20'hfffff : flin[31:12] + 20'd1")
    return '''`timescale 1ns/1ps
module tb;
  localparam S_DECODE=0;
  logic state=0,sys_mode,paging_on,d_fetch_overlong;
  logic sfetch_early_nm,sfetch_early_gp,dbg_block_issue;
  logic smi_pending,smm_active,dbg_step_active,nmi_take,intr_take;
  logic [1:0] sfetch_header_fault_q;
  logic [31:0] flin,fetch_fault_linear,fetch_fault_page,old_addr,new_addr;
  logic [4:0] d_fetch_fault_len;
  logic [3:0] old_size,new_size;
  logic fetch_overlength_probe,old_kind,new_kind;
  integer checks=0,probes=0,idle_changes=0,wraps=0,blocked=0;
'''+guards+'''
  always_comb begin
    old_addr=0; old_size=4;
'''+old+'''
    new_addr=0; new_size=4;
'''+new+'''
    old_kind=!fetch_overlength_probe;
    new_kind='''+kind+''';
  end
  task automatic check;
    #1;
    checks++;
    if (fetch_overlength_probe) begin
      probes++;
      if (new_addr==0) wraps++;
      if ({old_addr,old_size,old_kind} !== {new_addr,new_size,new_kind})
        $fatal(1,"FETCH-PROBE-MISMATCH n=%0d linear=%h len=%0d old=%h/%h/%b new=%h/%h/%b",
               checks,flin,d_fetch_fault_len,old_addr,old_size,old_kind,new_addr,new_size,new_kind);
    end else begin
      if (fetch_fault_page[31:12]!=flin[31:12]) blocked++;
      if ({old_addr,old_size,old_kind} !== {new_addr,new_size,new_kind}) idle_changes++;
    end
  endtask
  initial begin
    {sys_mode,paging_on,d_fetch_overlong}=3'b111;
    {sfetch_header_fault_q,sfetch_early_nm,sfetch_early_gp,dbg_block_issue,
     smi_pending,smm_active,dbg_step_active,nmi_take,intr_take}=0;
    for (integer page=0;page<4;page++)
      for (integer off=0;off<4096;off++)
        for (integer len=16;len<32;len++) begin
          case(page)
            0: flin={20'h00000,12'(off)};
            1: flin={20'h00001,12'(off)};
            2: flin={20'h7ffff,12'(off)};
            3: flin={20'hfffff,12'(off)};
          endcase
          d_fetch_fault_len=5'(len); check();
        end
    flin=32'hfffffff1; d_fetch_fault_len=17;
    for (integer controls=0;controls<16384;controls++) begin
      {state,sys_mode,paging_on,d_fetch_overlong,sfetch_header_fault_q,
       sfetch_early_nm,sfetch_early_gp,dbg_block_issue,smi_pending,smm_active,
       dbg_step_active,nmi_take,intr_take}=14'(controls);
      check();
    end
    if (!probes || !wraps || !blocked || !idle_changes)
      $fatal(1,"FETCH-PROBE-MISSING-COVERAGE");
    $display("FETCH-PROBE-PAYLOAD-OK checks=%0d probes=%0d wrap=%0d blocked=%0d idle_changes=%0d",
             checks,probes,wraps,blocked,idle_changes);
    $finish;
  end
endmodule
'''


def proof(mutation):
    new = '(bvand (bvadd a #x00001000) #xfffff000)'
    if mutation == 'previous-page': new = '(bvand a #xfffff000)'
    if mutation == 'lost-wrap': new = '(ite (= (bvand a #xfffff000) #xfffff000) #xfffff000 '+new+')'
    return '''(set-logic QF_BV)
(declare-const a (_ BitVec 32))
(declare-const len (_ BitVec 5))
(define-fun endpoint () (_ BitVec 32) (bvsub (bvadd a ((_ zero_extend 27) len)) #x00000001))
(define-fun oldpage () (_ BitVec 32) (bvand endpoint #xfffff000))
(assert (bvuge len #b10000))
(assert (not (= oldpage (bvand a #xfffff000))))
(assert (not (= oldpage '''+new+''')))
(check-sat)
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    parent = args.parent.resolve(strict=True); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=Path(__file__).stat().st_dev
    assert shutil.disk_usage(scratch).free>4*1024**3
    source = (parent/recipe.PAYLOAD).read_text()
    changed = recipe.transform(source)
    decoder = parent/'rtl/core/decode_stages.sv'
    decoder_range(decoder.read_text())
    pins = {str(p.resolve()):sha(p) for p in (parent/recipe.PAYLOAD,decoder,Path(__file__),
        Path(recipe.__file__),Path(extract_predicates.__file__))}
    for executable in ('iverilog','vvp','z3'):
        executable = Path(shutil.which(executable)).resolve(); pins[str(executable)]=sha(executable)
    root.mkdir(); (root/'core.sv').write_text(changed)
    rows=[]; queries=[]; begin=time.monotonic()
    for mode in ('positive','previous-page','wrong-extent','data-side','lost-wrap'):
        sv=root/(mode+'.sv'); sv.write_text(fixture(source,mode))
        binary=root/(mode+'.vvp'); log=root/(mode+'.log')
        compiled=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(binary),str(sv)],
                                capture_output=True,text=True,timeout=30)
        (root/(mode+'.compile.log')).write_text(compiled.stdout+compiled.stderr)
        assert compiled.returncode==0, (mode,compiled.stderr)
        proc=subprocess.run(['vvp',str(binary)],capture_output=True,text=True,timeout=60)
        log.write_text(proc.stdout+proc.stderr)
        if mode=='positive':
            match=re.search(r'FETCH-PROBE-PAYLOAD-OK checks=(\d+) probes=(\d+) wrap=(\d+) blocked=(\d+) idle_changes=(\d+)',proc.stdout)
            assert proc.returncode==0 and match and int(match[1])==278528
            coverage=dict(zip(('checks','probes','wraps','blocked','idle_changes'),map(int,match.groups())))
            assert all(coverage.values())
        else:
            assert proc.returncode==1 and 'FETCH-PROBE-MISMATCH' in proc.stdout
        artifacts={str(p):sha(p) for p in (sv,binary,log,root/(mode+'.compile.log'))}
        rows.append(dict(mode=mode,native_exit=proc.returncode,artifacts=artifacts))
    for mode in ('positive','previous-page','lost-wrap'):
        query=root/(mode+'.smt2'); query.write_text(proof(mode))
        proc=subprocess.run(['z3',str(query)],capture_output=True,text=True,timeout=20)
        log=root/(mode+'.proof.log'); log.write_text(proc.stdout+proc.stderr)
        expected='unsat' if mode=='positive' else 'sat'
        assert proc.returncode==0 and proc.stdout.strip()==expected
        queries.append(dict(mode=mode,answer=expected,native_exit=proc.returncode,
                            artifacts={str(p):sha(p) for p in (query,log)}))
    assert all(sha(p)==h for p,h in pins.items())
    pins[str(root/'core.sv')]=sha(root/'core.sv')
    result=dict(passed=True,pins=pins,pins_unchanged=True,rows=rows,queries=queries,
        coverage=coverage,seconds=time.monotonic()-begin,invocation=os.environ.get('INVOCATION_ID'),
        affinity=sorted(os.sched_getaffinity(0)),whole_core=False,gameplay_ipc=None,fmax_mhz=None)
    (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows','queries')}),flush=True)


if __name__=='__main__': main()
