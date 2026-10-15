"""Address-selector miter: physical owners, paging hits/misses and A20.

The six unchanged physical address calculations are abstracted as an arbitrary
32-bit value. Their exact source preservation is checked separately. The real
mem_xlate function and bus post-translation block are used without rewriting.
This is a local proof; the derivative additionally carries a complete original
driver shadow for every whole-core test.
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
import traceback

import prepare_early_bus_payload as recipe

MODES = ('positive', 'drop-physical', 'zero-linear', 'drop-translation', 'drop-a20')


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def fixture(source, core, mode):
    translation = re.search(r'  function automatic logic \[31:0\] mem_xlate\(.*?\n  endfunction', core, re.S)[0]
    post = source[source.index('    mem_addr_pre = bd_addr;'):source.index('    // =========================================================================\n    // REVIEW1_Aug2 C-01')]
    a20 = "    if (!a20_on) bd_addr[20] = 1'b0;"
    assert source.count(a20) == 1
    names = ('S_DECODE', 'S_LOAD', *recipe.PHYSICAL, 'S_HALT')
    declarations = ','.join(f'{n}={i}' for i,n in enumerate(names))
    physical = '    case (state)\n      '+','.join(recipe.PHYSICAL)+': bd_addr=physical_arm;\n      default: ;\n    endcase\n'
    def select(new):
        init = recipe.EARLY if new else recipe.INITIAL
        if new and mode == 'zero-linear': init = recipe.INITIAL
        body = init+'\n    bd_req=request;\n'
        if not (new and mode == 'drop-physical'): body += physical
        if not new: body += recipe.predecessor.NEW
        tail = post
        if new and mode == 'drop-translation':
            tail = tail.replace('if (bd_req) bd_addr = mem_xlate(bd_addr, cur_is_d);', '')
        body += tail
        if not (new and mode == 'drop-a20'): body += a20
        return body+'\n    return {bd_req,bd_addr};\n'
    funcs = ''
    for new in (False, True):
        funcs += '  function automatic [32:0] '+('candidate' if new else 'parent')+'();\n'
        funcs += '    logic bd_req,bd_we; logic [31:0] bd_addr,bd_wdata,mem_addr_pre; logic [3:0] bd_wstrb;\n'
        funcs += select(new)+'  endfunction\n'
    return '''`timescale 1ns/1ps
`define VEN_FE_PIPE
module tb;
  localparam '''+declarations+''';
  integer state;
  logic request,fe_translatable,paging_on,cur_is_d,a20_on;
  logic xlate_miss,fe_xlate_pend,perm_fault;
  logic frm_pg_hit,fe_dtlb_hit,fe_dtlb_v,fe_itlb_hit,fe_itlb_v;
  logic [19:0] frm_pg_hitphys,fe_dtlb_phys,fe_itlb_phys,fe_dtlb_page,fe_itlb_page;
  logic [31:0] cur_lin,physical_arm,seed=32'h71e05a39;
  logic [32:0] old_result,new_result;
  integer checks=0,beats=0,probes=0,physical_beats=0,idle_changes=0,translations=0;
'''+translation+funcs+'''
  initial begin
    for(state=0;state<9;state++) begin
      for(integer controls=0;controls<512;controls++) begin
        {paging_on,cur_is_d,a20_on,frm_pg_hit,fe_dtlb_hit,fe_itlb_hit,
         xlate_miss,fe_xlate_pend,perm_fault}=9'(controls);
        fe_dtlb_v=1; fe_itlb_v=1;
        for(integer i=0;i<64;i++) begin
          seed={seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};
          cur_lin=seed; physical_arm=~seed;
          frm_pg_hitphys=20'hf1abc; fe_dtlb_phys=20'h12345; fe_itlb_phys=20'hfffff;
          fe_dtlb_page=cur_lin[31:12] ^ (i[0] ? 20'd1 : 20'd0);
          fe_itlb_page=cur_lin[31:12] ^ (i[1] ? 20'd1 : 20'd0);
          fe_translatable=(state==S_LOAD) || ((state==S_DECODE) && i[2]);
          request=(state>=2 && state<=7) || ((state==S_LOAD) && i[3]);
          old_result=parent(); new_result=candidate(); #1; checks++;
          if(old_result[32]!==new_result[32]) $fatal(1,"EARLY-LEAF-REQUEST");
          if((request || fe_translatable) && old_result!==new_result)
            $fatal(1,"EARLY-LEAF-MISMATCH state=%0d controls=%0d old=%h new=%h",state,controls,old_result,new_result);
          if(old_result[32]) beats++;
          if(fe_translatable && !request) probes++;
          if(old_result[32] && state>=2 && state<=7) physical_beats++;
          if(old_result!=new_result) idle_changes++;
          if(old_result[32] && state==S_LOAD && paging_on && old_result[31:21]!=cur_lin[31:21]) translations++;
        end
      end
    end
    if(!beats || !probes || !physical_beats || !idle_changes || !translations)
      $fatal(1,"EARLY-LEAF-COVERAGE");
    $display("EARLY-LEAF-OK checks=%0d beats=%0d probes=%0d physical=%0d idle=%0d translated=%0d",
       checks,beats,probes,physical_beats,idle_changes,translations);
    $finish;
  end
endmodule
'''


def proof():
    # Arbitrary identical post-translation function preserves equal inputs.
    # Real beat => linear authority or a physical owner; physical owners never
    # assert translation authority. Whole-core shadow independently checks the
    # consumed result, including states omitted from the local abstraction.
    return '''(set-logic QF_AUFBV)
(declare-const physical Bool)
(declare-const decode Bool)
(declare-const translatable Bool)
(declare-const request Bool)
(declare-const linear (_ BitVec 32))
(declare-const physical_addr (_ BitVec 32))
(declare-fun post ((_ BitVec 32)) (_ BitVec 32))
(assert (=> physical (and (not decode) (not translatable))))
(assert (=> decode (not request)))
(assert (=> request (or physical translatable)))
(define-fun old () (_ BitVec 32)
  (ite (or translatable decode) linear (ite physical physical_addr #x00000000)))
(define-fun new () (_ BitVec 32) (ite physical physical_addr linear))
(assert (and (or request translatable) (not (= (post old) (post new)))))
(check-sat)
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'out'): ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    source, out = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == {13}
    assert shutil.disk_usage(scratch).free > 5*1024**3 and os.environ['INVOCATION_ID']
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    original = (source/recipe.FILE).read_text()
    changed = recipe.transform(original)
    core = (source/'rtl/core/core.sv').read_text()
    pins = {str(p.resolve()): sha(p) for p in (source/recipe.FILE,source/'rtl/core/core.sv',
        Path(__file__),Path(recipe.__file__),Path(recipe.predecessor.__file__),
        *(Path(shutil.which(n)) for n in ('iverilog','vvp','z3')))}
    out.mkdir()
    def save(name, value):
        with (out/name).open('x') as stream: json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cpu=13))
    (out/'core_bus_driver.svh').write_text(changed)
    begin, rows, errors = time.monotonic(), [], []
    try:
        for mode in MODES:
            sv, binary = out/(mode+'.sv'), out/(mode+'.vvp')
            sv.write_text(fixture(original,core,mode))
            results = {}
            for label,command in [('compile',['iverilog','-g2012','-s','tb','-o',binary,sv]),
                                  ('native',['vvp',binary])]:
                command = list(map(str,command))
                run = subprocess.run(command,capture_output=True,text=True,timeout=60)
                log = out/(mode+'.'+label+'.log'); log.write_text(run.stdout+run.stderr)
                results[label] = dict(command=command,native_exit=run.returncode,actual_wait=True,log_sha256=sha(log))
                if label == 'compile': assert run.returncode == 0,run.stderr
                elif mode == 'positive':
                    match = re.search(r'EARLY-LEAF-OK checks=(\d+) beats=(\d+) probes=(\d+) physical=(\d+) idle=(\d+) translated=(\d+)',run.stdout)
                    assert run.returncode == 0 and match
                    results[label]['coverage'] = dict(zip(('checks','beats','probes','physical','idle','translated'),map(int,match.groups())))
                    assert results[label]['coverage']['checks'] == 294912 and all(results[label]['coverage'].values())
                else: assert run.returncode == 1 and 'EARLY-LEAF-MISMATCH' in run.stdout
            rows.append(dict(mode=mode,results=results))
        smt = out/'proof.smt2'; smt.write_text(proof())
        run = subprocess.run(['z3',smt],capture_output=True,text=True,timeout=30)
        (out/'proof.log').write_text(run.stdout+run.stderr)
        assert run.returncode == 0 and run.stdout.strip() == 'unsat'
    except Exception as error:
        errors.append(dict(error=repr(error),traceback=traceback.format_exc()))
    stable = all(sha(p)==h for p,h in pins.items())
    result = dict(passed=stable and len(rows)==len(MODES) and not errors,rows=rows,errors=errors,
        pins_unchanged=stable,seconds=time.monotonic()-begin,whole_core=False,gameplay_ipc=None,
        artifacts={str(p):sha(p) for p in out.iterdir() if p.is_file()})
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')},indent=2),flush=True)
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
