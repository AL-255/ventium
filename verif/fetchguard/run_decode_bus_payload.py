"""Actual selector miter and all-address proof for the no-beat DECODE payload.

This local proof assumes the existing whole-core S_DECODE => !bd_req invariant.
It does not prove MMU/fault priority; the unmodified cold boundary corpus must
also run on the whole-core derivative before FPGA transfer.
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

import prepare_decode_bus_payload as recipe


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def selection(mode):
    text = recipe.NEW
    if mode == 'unconditional': text = text.replace('fe_translatable || state == S_DECODE', "1'b1")
    if mode == 'drop-ordinary': text = text.replace('fe_translatable || state == S_DECODE', 'state == S_DECODE')
    if mode == 'wrong-address': text = text.replace('bd_addr = cur_lin;', "bd_addr = cur_lin ^ 32'h1;")
    if mode == 'late-control': text = recipe.OLD
    return text


def fixture(parent, changed, mode):
    assert parent.count(recipe.OLD) == 1 and changed.count(recipe.NEW) == 1
    a20 = "    if (!a20_on) bd_addr[20] = 1'b0;"
    assert parent.count(a20) == changed.count(a20) == 1
    old = recipe.OLD.replace('bd_addr', 'old_addr')+a20.replace('bd_addr', 'old_addr')
    new = selection(mode).replace('bd_addr', 'new_addr')+a20.replace('bd_addr', 'new_addr')
    return '''`timescale 1ns/1ps
module tb;
  localparam S_DECODE=0;
  logic state,fe_translatable,bd_req,a20_on;
  logic [31:0] cur_lin,physical_arm,old_addr,new_addr,wanted,seed=32'h31415926;
  integer checks=0,beats=0,probes=0,physical=0,idle_changes=0;
  always_comb begin
    old_addr=physical_arm;
'''+old+'''
    new_addr=physical_arm;
'''+new+'''
    wanted=cur_lin;
    if(!a20_on) wanted[20]=0;
  end
  task automatic check;
    #1; checks++;
    if(bd_req) beats++;
    if(state==S_DECODE && fe_translatable) probes++;
    if(bd_req && !fe_translatable) physical++;
    if((bd_req || fe_translatable || state!=S_DECODE) && old_addr!==new_addr)
      $fatal(1,"DECODE-BUS-MISMATCH request=%b state=%b translate=%b old=%h new=%h",
        bd_req,state,fe_translatable,old_addr,new_addr);
    if(state==S_DECODE && new_addr!==wanted)
      $fatal(1,"DECODE-BUS-LATE-CONTROL");
    if(old_addr!==new_addr) begin
      if(bd_req || fe_translatable || state!=S_DECODE)
        $fatal(1,"DECODE-BUS-UNAUTHORIZED-DIFFERENCE");
      idle_changes++;
    end
  endtask
  initial begin
    for(integer controls=0;controls<16;controls++) begin
      {state,fe_translatable,bd_req,a20_on}=4'(controls);
      if(state==S_DECODE) bd_req=0; // independent existing core assertion
      for(integer i=0;i<4096;i++) begin
        seed={seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};
        cur_lin=seed; physical_arm=~seed ^ (32'(i)<<12);
        check();
      end
    end
    if(checks!=65536 || !beats || !probes || !physical || !idle_changes)
      $fatal(1,"DECODE-BUS-MISSING-COVERAGE");
    $display("DECODE-BUS-OK checks=%0d beats=%0d probes=%0d physical=%0d idle=%0d",
      checks,beats,probes,physical,idle_changes);
    $finish;
  end
endmodule
'''


def proof(mode):
    # Match each actual selector before translating its small Boolean grammar.
    statement = re.search(r'if \((.*?)\) bd_addr = ([^;]+);', selection(mode))
    guards = {'fe_translatable || state == S_DECODE': '(or translate decode)',
              "1'b1": 'true', 'state == S_DECODE': 'decode', 'fe_translatable': 'translate'}
    guard = guards[statement[1]]
    assert statement[2] in ('cur_lin', "cur_lin ^ 32'h1")
    payload = 'linear' if statement[2] == 'cur_lin' else '(bvxor linear #x00000001)'
    return '''(set-logic QF_BV)
(declare-const decode Bool)
(declare-const translate Bool)
(declare-const request Bool)
(declare-const a20 Bool)
(declare-const linear (_ BitVec 32))
(declare-const physical (_ BitVec 32))
(define-fun mask ((x (_ BitVec 32))) (_ BitVec 32) (ite a20 x (bvand x #xffefffff)))
(define-fun old () (_ BitVec 32) (mask (ite translate linear physical)))
(define-fun new () (_ BitVec 32) (mask (ite '''+guard+' '+payload+''' physical)))
(assert (=> decode (not request)))
; Either a real beat/probe changes, or the intended no-request DECODE
; payload still depends on the late qualification. The latter is a
; selector-independence check, not an architectural failure of the old code.
(assert (or (and (or request translate (not decode)) (not (= old new)))
            (and decode (not (= new (mask linear))))))
(check-sat)
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    source, out = a.parent.resolve(strict=True), a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == {13}
    assert shutil.disk_usage(scratch).free > 5*1024**3 and os.environ['INVOCATION_ID']
    parent = (source/recipe.FILE).read_text()
    changed = recipe.transform(parent)
    core = (source/'rtl/core/core.sv').read_text()
    assert 'if (rst_n && state == S_DECODE) begin\n    assert (!bd_req && !cur_seg_rel && !cur_is_d)' in core
    assert "cur_lin_nat = {flin[31:12] + 20'd1, 12'd0};" in core
    pins = {str(p.resolve()): sha(p) for p in (source/recipe.FILE, source/'rtl/core/core.sv',
        Path(__file__), Path(recipe.__file__), *(Path(shutil.which(n)) for n in ('iverilog', 'vvp', 'z3')))}
    out.mkdir()
    def save(p, value):
        with p.open('x') as f: json.dump(value, f, indent=2)
    save(out/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'], cpu=13,
        local_assumption='S_DECODE has no bd_req; clocked whole-core assertion must be exercised'))
    (out/'core_bus_driver.svh').write_text(changed)
    rows, errors, begin = [], [], time.monotonic()
    try:
        for mode in ('positive', 'unconditional', 'drop-ordinary', 'wrong-address', 'late-control'):
            sv, binary = out/(mode+'.sv'), out/(mode+'.vvp')
            sv.write_text(fixture(parent, changed, mode))
            cmds = [('compile', ['iverilog', '-g2012', '-s', 'tb', '-o', binary, sv]),
                    ('native', ['vvp', binary]), ('proof', ['z3', out/(mode+'.smt2')])]
            (out/(mode+'.smt2')).write_text(proof(mode))
            results = {}
            for name, command in cmds:
                command = list(map(str, command))
                run = subprocess.run(command, capture_output=True, text=True, timeout=60)
                log = out/(mode+'.'+name+'.log')
                log.write_text(run.stdout+run.stderr)
                results[name] = dict(command=command, native_exit=run.returncode, actual_wait=True, log_sha256=sha(log))
                if name == 'compile': assert run.returncode == 0, run.stderr
                elif name == 'proof':
                    assert run.returncode == 0 and run.stdout.strip() == ('unsat' if mode == 'positive' else 'sat')
                    results[name]['answer'] = run.stdout.strip()
                elif mode == 'positive':
                    m = re.search(r'DECODE-BUS-OK checks=(\d+) beats=(\d+) probes=(\d+) physical=(\d+) idle=(\d+)', run.stdout)
                    assert run.returncode == 0 and m and int(m[1]) == 65536
                    results[name]['coverage'] = dict(zip(('checks','beats','probes','physical','idle_changes'), map(int,m.groups())))
                    assert all(results[name]['coverage'].values())
                else:
                    assert run.returncode == 1 and ('DECODE-BUS-MISMATCH' in run.stdout or 'DECODE-BUS-LATE-CONTROL' in run.stdout)
            rows.append(dict(mode=mode, results=results))
    except Exception as error:
        errors.append(dict(error=repr(error), traceback=traceback.format_exc()))
    stable = all(sha(p) == digest for p, digest in pins.items())
    artifacts = {str(p): sha(p) for p in out.iterdir() if p.is_file()}
    result = dict(passed=stable and len(rows)==5 and not errors, rows=rows, errors=errors,
        pins_unchanged=stable, artifacts=artifacts, seconds=time.monotonic()-begin,
        whole_core=False, hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    save(out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')}, indent=2), flush=True)
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
