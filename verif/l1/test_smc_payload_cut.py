"""Native source-equation SMC miter and all-bit owner-contract proof.

This does not prove the whole core maintains the assumed ownership contract.
It deliberately exercises physical aliases, address wrap, sparse byte masks,
both U-write and U-read/V-store pairs, and overlapping copies of U's snoop.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_smc_payload_cut as recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def assign(source, name, contains):
    rows = [row for row in re.findall(r'  assign '+name+r'\s*=.*?;[^\n]*\n', source, re.S)
            if contains in row]
    assert len(rows) == 1, (name, len(rows))
    return rows[0]


def fixture(l1, core, mode):
    changed_l1 = recipe.transform('rtl/mem/ventium_l1_axi.sv', l1)
    changed_core = recipe.transform('rtl/core/core.sv', core)
    body = assign(l1, 'smc_xline', 'core_we')
    body += assign(l1, 'icache_snoop_valid2', 'core_store_pair_req')
    body += assign(core, 'smc_v2', 'smc_v1')
    body += assign(core, 'smc_a2', 'mem_addr')
    body += assign(core, 'icsnp_v2', 'ic_snoop_valid2')
    # Both sides use extracted RTL equations. Arithmetic producing LAST is
    # also copied from the exact source, not restated in the miter.
    start = l1.index('  always_comb begin\n    logic [2:0] hi;', l1.index('logic [31:0] smc_last_lin;'))
    end = l1.index('  assign smc_xline', start)
    body += l1[start:end]
    body += assign(l1, 'icache_snoop_addr2', 'core_store_pair_req').replace('icache_snoop_addr2', 'old_l1')
    new = assign(changed_l1, 'icache_snoop_addr2', 'core_addr[1:0]').replace('icache_snoop_addr2', 'new_l1')
    if mode == 'always-v':
        new = new.replace("(core_addr[1:0] == 2'd0)", "1'b1")
    elif mode == 'always-u':
        new = new.replace("(core_addr[1:0] == 2'd0)", "1'b0")
    body += new
    body += assign(core, 'icsnp_a2', 'ic_snoop_valid2').replace('icsnp_a2', 'old_core').replace('ic_snoop_addr2', 'old_l1')
    new = assign(changed_core, 'icsnp_a2', 'smc_v2 ?').replace('icsnp_a2', 'new_core').replace('ic_snoop_addr2', 'new_l1')
    if mode == 'drop-own':
        new = new.replace('smc_v2 ?', "1'b0 ?")
    body += new
    return '''`timescale 1ns/1ps
module tb;
  logic [31:0] core_addr,core_lin,core_store_pair_addr,mem_addr;
  logic [31:0] smc_last_lin,smc_last_phys,smc_a2,old_l1,new_l1,old_core,new_core;
  logic [3:0] core_wstrb,cur_size;
  logic core_we,core_store_pair_req,smc_xline,smc_v1,smc_v2;
  logic icache_snoop_valid2,ic_snoop_valid2,icsnp_v2;
  integer checks=0,paired_reads=0,paired_writes=0,crossing=0,own_only=0,overlap=0,idle_diff=0;
  assign mem_addr=core_addr;
  assign ic_snoop_valid2=icache_snoop_valid2;
'''+body+'''
  task automatic check;
    #1;
    checks++;
    if (icache_snoop_valid2 && old_l1 !== new_l1)
      $fatal(1,"SMC-PAYLOAD-MISMATCH l1 check=%0d U=%h V=%h mask=%h pair=%b",checks,core_addr,core_store_pair_addr,core_wstrb,core_store_pair_req);
    if (icsnp_v2 && old_core[31:5] !== new_core[31:5])
      $fatal(1,"SMC-PAYLOAD-MISMATCH core check=%0d old=%h new=%h",checks,old_core,new_core);
    if (core_store_pair_req && core_we) paired_writes++;
    if (core_store_pair_req && !core_we) paired_reads++;
    if (smc_xline) crossing++;
    if (smc_v2 && !ic_snoop_valid2) own_only++;
    if (smc_v2 && ic_snoop_valid2) overlap++;
    if (!icsnp_v2 && old_core != new_core) idle_diff++;
  endtask
  initial begin
    // Exhaust low offsets/masks/sizes and independent valid sources. High
    // addresses select ordinary RAM, unrelated linear aliases, and wrap.
    for (integer highsel=0;highsel<3;highsel++)
      for (integer off=0;off<32;off++)
        for (integer mask=0;mask<16;mask++)
          for (integer size=1;size<=4;size++)
            for (integer flags=0;flags<8;flags++) begin
              core_addr=(highsel==0 ? 32'h12345000 : highsel==1 ? 32'habcdffe0 : 32'hffffffe0)+32'(off);
              core_lin=32'h76543000+32'(off);
              core_store_pair_addr=32'h45238004;
              core_wstrb=4'(mask); cur_size=4'(size);
              core_we=flags[0]; smc_v1=flags[1];
              core_store_pair_req=flags[2] && off%4==0;
              check();
            end
    if (!paired_reads || !paired_writes || !crossing || !own_only || !overlap || !idle_diff)
      $fatal(1,"SMC-PAYLOAD missing class");
    $display("SMC-PAYLOAD-OK checks=%0d paired_reads=%0d paired_writes=%0d crossing=%0d own_only=%0d overlap=%0d idle_diff=%0d",
      checks,paired_reads,paired_writes,crossing,own_only,overlap,idle_diff);
    $finish;
  end
endmodule
'''


def query(mode):
    text = '(set-logic QF_BV)\n'
    for name in ('pair','we','own'):
        text += f'(declare-const {name} Bool)\n'
    for name,width in (('phys',32),('lin',32),('vaddr',32),('mask',4),('size',4)):
        text += f'(declare-const {name} (_ BitVec {width}))\n'
    terms = [
        ('hi','(_ BitVec 32)','(ite (= ((_ extract 3 3) mask) #b1) #x00000003 (ite (= ((_ extract 2 2) mask) #b1) #x00000002 (ite (= ((_ extract 1 1) mask) #b1) #x00000001 #x00000000)))'),
        ('last','(_ BitVec 32)','(bvadd phys hi)'),
        ('aligned','Bool','(= ((_ extract 1 0) phys) #b00)'),
        ('cross','Bool','(and we (not (= ((_ extract 31 5) (bvadd lin hi)) ((_ extract 31 5) lin))))'),
        ('ext','Bool','(or cross pair)'),
        ('own_cross','Bool','(and own (bvugt (bvadd ((_ zero_extend 1) ((_ extract 4 0) phys)) ((_ zero_extend 2) size)) #b100000))'),
        ('own_addr','(_ BitVec 32)','(bvadd (concat ((_ extract 31 5) phys) #b00000) #x00000020)'),
        ('old_l1','(_ BitVec 32)','(ite pair vaddr last)'),
        ('new_l1','(_ BitVec 32)','(ite aligned vaddr last)'),
        ('old_core','(_ BitVec 32)','(ite ext old_l1 own_addr)'),
        ('new_core','(_ BitVec 32)','(ite own_cross own_addr new_l1)'),
    ]
    for name,kind,expression in terms:
        text += f'(define-fun {name} () {kind} {expression})\n'
    if mode != 'unaligned-pair': text += '(assert (=> pair aligned))\n'
    if mode != 'offset-mismatch': text += '(assert (= ((_ extract 4 0) lin) ((_ extract 4 0) phys)))\n'
    if mode != 'oversized-beat': text += '(assert (bvule size #x4))\n'
    text += '(assert (bvuge size #x1))\n'
    mismatch = '(or (and ext (not (= old_l1 new_l1))) (and (or ext own_cross) (not (= ((_ extract 31 5) old_core) ((_ extract 31 5) new_core)))))'
    if mode == 'idle-difference':
        mismatch = '(and (not (or ext own_cross)) (not (= old_core new_core)))'
    return text+'(assert '+mismatch+')\n(check-sat)\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    source = args.source.resolve(strict=True); out = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert os.access(scratch, os.W_OK) and scratch.stat().st_dev != Path(__file__).stat().st_dev
    assert sorted(os.sched_getaffinity(0)) == [12]
    inputs = {}; pins = {}
    for rel,digest in recipe.PARENTS.items():
        path = source/rel
        assert sha(path) == digest, rel
        inputs[rel] = path.read_text(); pins[str(path)] = digest
        transformed = recipe.transform(rel, inputs[rel])
        old,new = (recipe.OLD_L1,recipe.NEW_L1) if rel.endswith('ventium_l1_axi.sv') else (recipe.OLD_CORE,recipe.NEW_CORE)
        assert transformed.count(new) == 1 and transformed.replace(new,old) == inputs[rel]
        for invalid in (inputs[rel]+'\n', transformed):
            try: recipe.transform(rel, invalid)
            except ValueError: pass
            else: raise AssertionError('accepted source drift/reapplication')
    for path in (Path(__file__).resolve(), Path(recipe.__file__).resolve()): pins[str(path)] = sha(path)
    out.mkdir()
    result = dict(passed=False,pins=pins,rows=[],proofs=[],whole_core=False,fmax_mhz=None,
                  gameplay_ipc=None,invocation=os.environ.get('INVOCATION_ID'),
                  cpu_affinity=sorted(os.sched_getaffinity(0)))
    started = time.monotonic()
    try:
        for mode in ('positive','always-v','always-u','drop-own'):
            folder = out/mode; folder.mkdir()
            sv=folder/'tb.sv'; binary=folder/'a.out'
            sv.write_text(fixture(inputs['rtl/mem/ventium_l1_axi.sv'],inputs['rtl/core/core.sv'],mode))
            with (folder/'build.log').open('x') as log:
                build = subprocess.run(['iverilog','-g2012','-s','tb','-o',str(binary),str(sv)],stdout=log,stderr=subprocess.STDOUT,timeout=15)
            assert build.returncode == 0, mode
            with (folder/'run.log').open('x') as log:
                run = subprocess.run(['vvp',str(binary)],stdout=log,stderr=subprocess.STDOUT,timeout=30)
            text = (folder/'run.log').read_text()
            assert (run.returncode == 0 and 'SMC-PAYLOAD-OK checks=49152 ' in text) if mode == 'positive' else (
                run.returncode == 1 and 'SMC-PAYLOAD-MISMATCH' in text), (mode,text)
            result['rows'].append(dict(mode=mode,native_exit=run.returncode,log=text,
                artifacts={str(p):sha(p) for p in (sv,binary,folder/'build.log',folder/'run.log')}))
        for mode in ('positive','unaligned-pair','offset-mismatch','oversized-beat','idle-difference'):
            path=out/(mode+'.smt2'); path.write_text(query(mode))
            proc=subprocess.run(['z3',str(path)],text=True,capture_output=True,timeout=15)
            log=out/(mode+'.log'); log.write_text(proc.stdout+proc.stderr)
            expected='unsat' if mode == 'positive' else 'sat'
            assert proc.returncode == 0 and proc.stdout.strip() == expected, (mode,proc.stdout,proc.stderr)
            result['proofs'].append(dict(mode=mode,native_exit=proc.returncode,answer=expected,
                artifacts={str(p):sha(p) for p in (path,log)}))
        result['passed']=True
    finally:
        result['elapsed_seconds']=time.monotonic()-started
        result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
        (out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    assert result['pins_unchanged']
    print(json.dumps({k:v for k,v in result.items() if k != 'pins'}),flush=True)


if __name__ == '__main__': main()
