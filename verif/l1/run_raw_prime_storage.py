"""Source-linked retained-storage invariant tests; not whole-core acceptance.

The leaf extracts the real ten-register state machine and fpd_t type. Its
prepare input abstracts all other eligibility conjuncts; the hash-pinned
source audit proves RAW preparation implies prime_base. Z3 checks induction
under precisely that implication, with reset and nonzero capture witnesses.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import prepare_raw_prime_storage as recipe

JOBS = ((True, 'positive'), (False, 'positive'), (True, 'drop-raw-guard'),
        (True, 'capture-with-base'), (True, 'wrong-constant'), (False, 'omit-legacy-owner'))


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def fixture(source, raw, mode):
    text = (source/'core_mem_chain.svh').read_text()
    old, new = recipe.check_guard(text), recipe.replacement(text)
    package = (source/'ventium_decode_pkg.sv').read_text()
    typedef = re.search(r'  typedef struct packed \{.*?\} fpd_t;', package, re.S).group()
    if mode == 'capture-with-base':
        old = old.replace('mc_prepare_ok && !mc_prime_base', 'mc_prepare_ok && mc_prime_base')
    if mode == 'wrong-constant':
        new = new.replace("assign mc_pair_q = '0;", "assign mc_pair_q = 1'b1;")
    if mode == 'omit-legacy-owner':
        new = new.replace('mc_valid_q <= mc_prepare_ok && !mc_prime_base;', "mc_valid_q <= 1'b0;")
    ports = '''(input logic clk, input logic [12:0] controls,
      input logic [2*$bits(fpd_t)+132:0] payload,
      output logic [2*$bits(fpd_t)+133:0] observed);
  wire rst_n=controls[0],mc_boundary_ok=controls[1],tlb_flush=controls[2];
  wire tlb_fill_en=controls[3],pipe_mem_abort_now=controls[4],mc_prime_accept=controls[5];
  wire pipe_v_pair_now_accept=controls[6],pipe_int_commit=controls[7],mc_any_accept=controls[8];
  wire mc_prime_base=controls[9],prepare_other=controls[10],sys_mode=controls[11],sys_allow=controls[12];
  wire mc_prepare_ok = PREPARE && (!sys_mode || sys_allow);
  wire mc_query_pair,mc_lookup_dirty;
  wire [31:0] mc_query_pc,mc_query_ea,mc_query_lin,mc_query_phys;
  wire [2:0] mc_query_seg;
  fpd_t mc_query_u,mc_query_v;
  assign {mc_query_pair,mc_lookup_dirty,mc_query_pc,mc_query_ea,mc_query_lin,
          mc_query_phys,mc_query_seg,mc_query_u,mc_query_v}=payload;
  logic mc_valid_q,mc_pair_q,mc_dirty_q;
  logic [31:0] mc_pc_q,mc_ea_q,mc_lin_q,mc_phys_q;
  logic [2:0] mc_seg_q;
  fpd_t mc_u_q,mc_v_q;
  assign observed={mc_valid_q,mc_pair_q,mc_dirty_q,mc_pc_q,mc_ea_q,
                   mc_lin_q,mc_phys_q,mc_seg_q,mc_u_q,mc_v_q};
'''
    prepare = 'prepare_other && mc_prime_base' if raw and mode != 'drop-raw-guard' else 'prepare_other'
    ports = ports.replace('PREPARE', prepare)
    result = 'package storage_types;\n'+typedef+'\nendpackage\nimport storage_types::*;\n'
    for name, body in (('old_owner', old), ('new_owner', new)):
        result += 'module '+name+ports+body+'\nendmodule\n'
    result += '''module tb;
  logic clk=0;
  logic [12:0] controls=0;
  logic [2*$bits(fpd_t)+132:0] payload=0;
  wire [2*$bits(fpd_t)+133:0] old_state,new_state;
  integer checks=0,valid_seen=0,prepare_seen=0,resets=0;
  old_owner old_dut(.*,.observed(old_state));
  new_owner new_dut(.*,.observed(new_state));
  initial begin
    // Reset first; then enumerate all control combinations twice. Payloads
    // change on every edge, including nonzero words in every descriptor bit.
    for(integer n=0;n<16385;n=n+1) begin
      clk=0;
      controls=n==0 ? 13'b0 : 13'(n-1);
      for(integer b=0;b<$bits(payload);b=b+1) payload[b]=((b+n)%3)!=0;
      #1;clk=1;#1;
      if(old_state !== new_state) $fatal(1,"RAW-STORAGE-LEAF mismatch n=%0d",n);
      checks++;
      if(!controls[0]) resets++;
      if(old_dut.mc_prepare_ok) prepare_seen++;
      if(old_dut.mc_valid_q) valid_seen++;
    end
    if(checks!=16385 || resets==0 || prepare_seen==0) $fatal(1,"RAW-STORAGE-VACUOUS");
`ifdef VEN_RAW_V_READ_PRIME
    if(valid_seen!=0) $fatal(1,"RAW-STORAGE-RETAINED");
`else
    if(valid_seen==0) $fatal(1,"RAW-STORAGE-LEGACY-VACUOUS");
`endif
    $display("RAW-STORAGE-OK checks=%0d resets=%0d prepare=%0d retained=%0d bits=%0d",
             checks,resets,prepare_seen,valid_seen,$bits(old_state));
    $finish;
  end
endmodule
'''
    return result


def proof():
    # Abstract the other prepare conjuncts, but not the audited RAW guard or
    # original capture. Reset makes the complete vector zero. Without capture
    # only valid is assigned zero; every payload field holds its reset value.
    return '''(set-logic QF_BV)
(declare-fun base () Bool)
(declare-fun rest () Bool)
(declare-fun clear () Bool)
(declare-fun rst () Bool)
(declare-fun old () (_ BitVec 1024))
(declare-fun payload () (_ BitVec 1024))
(define-fun prep () Bool (and base rest))
(define-fun capture () Bool (and prep (not base)))
(define-fun next () (_ BitVec 1024) (ite (not rst) (_ bv0 1024)
    (ite clear (_ bv0 1024) (ite capture payload old))))
(push)
(assert (= old (_ bv0 1024)))
(assert (not (= next (_ bv0 1024))))
(check-sat)
(pop)
; Positive eligibility is reachable: the proof is not all preparation false.
(push)
(assert prep)
(check-sat)
(pop)
; Removing RAW's guard makes retained capture reachable from reset.
(push)
(assert (and rest (not base)))
(check-sat)
(pop)
; Dropping the capture's !base has the same counterexample obligation.
(assert (and prep base))
(check-sat)
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args(); source=args.source.resolve(strict=True); out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert scratch.stat().st_dev!=Path(__file__).stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0)=={18,19,20,21}
    cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((cg/'memory.max').read_text())<=1024**3 and (cg/'memory.swap.max').read_text().strip()=='0'
    files=[Path(__file__),Path(recipe.__file__),source/'core_mem_chain.svh',
           source/'ventium_decode_pkg.sv',Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'),Path('/usr/bin/z3')]
    pins={str(p.resolve()):sha(p) for p in files}
    out.mkdir(mode=0o700)
    def save(name, data):
        with (out/name).open('x') as f:json.dump(data,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],jobs=JOBS))
    (out/'core_mem_chain.svh').write_text(recipe.transform((source/'core_mem_chain.svh').read_text()))
    (out/'invariant.smt2').write_text(proof())
    begin=time.monotonic();rows=[];errors=[]
    def execute(job):
        raw,mode=job;work=out/(('raw-' if raw else 'legacy-')+mode);work.mkdir()
        (work/'tb.sv').write_text(fixture(source,raw,mode))
        command=['/usr/bin/iverilog','-g2012','-Wall','-s','tb','-DVEN_FAST_XCHG_R',
                 '-DVEN_P54_DUAL_BYTE_LOAD_PAIR',*(['-DVEN_RAW_V_READ_PRIME'] if raw else []),
                 '-o',str(work/'test.vvp'),str(work/'tb.sv')]
        with (work/'build.log').open('x') as f:
            built=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=30)
        assert built.returncode==0,(mode,'compile')
        with (work/'native.log').open('x') as f:
            child=subprocess.Popen(['/usr/bin/vvp',str(work/'test.vvp')],stdout=f,stderr=subprocess.STDOUT)
            try:affinity=sorted(os.sched_getaffinity(child.pid));code=child.wait(timeout=30)
            except BaseException:child.kill();child.wait();raise
        log=(work/'native.log').read_text()
        passed=(code==0 and 'RAW-STORAGE-OK checks=16385' in log and 'FATAL' not in log) if mode=='positive' else (
            code==1 and ('RAW-STORAGE-LEAF mismatch' in log or 'RAW-PRIME-STORAGE:' in log))
        return dict(raw=raw,mode=mode,passed=passed,compile_exit=built.returncode,native_exit=code,
                    argv=command,affinity=affinity,pid=child.pid,actual_wait=True,
                    proc_gone=not Path('/proc',str(child.pid)).exists())
    try:
        with (out/'proof.log').open('x') as f:
            result=subprocess.run(['/usr/bin/z3',str(out/'invariant.smt2')],stdout=f,stderr=subprocess.STDOUT,timeout=15)
        assert result.returncode==0 and (out/'proof.log').read_text().split()==['unsat','sat','sat','sat']
        with ThreadPoolExecutor(max_workers=4) as pool:rows=list(pool.map(execute,JOBS))
    except Exception as exc:errors.append(repr(exc))
    events={k:int(v) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines())}
    unchanged=all(sha(p)==h for p,h in pins.items())
    passed=unchanged and not errors and len(rows)==len(JOBS) and all(r['passed'] and r['proc_gone'] and r['affinity']==[18,19,20,21] for r in rows)
    passed &= not any(events[k] for k in ('oom','oom_kill','oom_group_kill'))
    done=dict(passed=passed,pins_unchanged=unchanged,rows=rows,errors=errors,memory_events=events,
              memory_peak=int((cg/'memory.peak').read_text()),seconds=time.monotonic()-begin,
              artifacts={str(p):sha(p) for p in out.rglob('*') if p.is_file()},
              whole_core=False,standard_suite=False,physical_fpga=False,gameplay_ipc=None)
    save('closed.json',done)
    print(json.dumps({k:v for k,v in done.items() if k not in ('artifacts','rows')}),flush=True)
    return 0 if passed else 1


if __name__=='__main__':raise SystemExit(main())
