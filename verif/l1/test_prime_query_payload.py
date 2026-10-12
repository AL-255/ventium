"""Native source-equation miter for query payload ownership, not a core gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_prime_query_payload as recipe

HASHES = {
    'core_mem_chain.svh': recipe.PARENT,
    'core_raw_held_prime.svh': '032530542135f8744c332aa16fbfbf4bd36fac24230b8b1c20c4d989a0630040',
    'core_agi_resident_prime.svh': '818dbc33998087af6849f5ca3177733f7ab05de38e670b9a6e470e2fe275d092',
    'core_ref_operand_prime.svh': 'e4a31829ed91c44ccfdb5e96350c95f3953c8c6d746a97b3b25c094b5be35399',
}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def choose(source, name, contains):
    rows = re.findall(r'  assign '+name+r' = .*?;\n', source, re.S)
    rows = [row for row in rows if contains in row]
    assert len(rows) == 1, (name, len(rows))
    return rows[0]


def fixture(inputs, mutant=None):
    header = inputs['core_mem_chain.svh']
    changed = recipe.transform(header)
    body = ''
    for filename, name, contains in (
        ('core_mem_chain.svh', 'mc_fp_self_prime', 'pipe_u_eff.is_fp'),
        ('core_raw_held_prime.svh', 'mc_held_read_prime', 'mc_held_v_valid_q'),
        ('core_raw_held_prime.svh', 'mc_fresh_read_prime', 'pipe_new_load_req'),
        ('core_mem_chain.svh', 'mc_prime_base', 'mc_fp_self_prime'),
        ('core_mem_chain.svh', 'mc_offer', 'mc_valid_q'),
        ('core_mem_chain.svh', 'mc_prime_offer', 'mc_prepare_ok'),
        ('core_mem_chain.svh', 'mem_next_req', 'agi_prime_offer')):
        body += choose(inputs[filename], name, contains)
    # Over-approximate the remaining AGI/reference eligibility predicates by
    # independent bits. Preserve the selector implication from the real source.
    for kind, filename in (('agi', 'core_agi_resident_prime.svh'),
                           ('ref', 'core_ref_operand_prime.svh')):
        actual = choose(inputs[filename], kind+'_prime_offer', kind+'_prime_select')
        assert actual.startswith('  assign '+kind+'_prime_offer = '+kind+'_prime_select &&')
        body += '  assign '+kind+'_prime_offer = '+kind+'_prime_select && '+kind+'_guard;\n'
    for name, suffix in (('mem_next_addr', 'addr'), ('mem_next_wstrb', 'strb')):
        body += recipe.assignment(header, name).replace(name+' =', 'old_'+suffix+' =')
        candidate = recipe.assignment(changed, name).replace(name+' =', 'new_'+suffix+' =')
        if mutant == 'always-live':
            candidate = candidate.replace('!mc_valid_q', "1'b1")
        if mutant == 'always-retained':
            candidate = candidate.replace('!mc_valid_q', "1'b0")
        if mutant == 'wrong-query-width' and suffix == 'strb':
            candidate = candidate.replace('mc_query_u.w8', '!mc_query_u.w8')
        if mutant == 'lost-agi-width' and suffix == 'strb':
            candidate = candidate.replace('agi_prime_select ?', "1'b0 ?")
        body += candidate
    return '''`timescale 1ns/1ps
module tb;
  localparam S_PIPE=0, FK_MEM=0;
  typedef struct packed {
    logic simple,is_mem,is_store,is_stack,is_fp,is_branch,ext,w8;
    logic [3:0] len;
    logic [1:0] fp_kind;
    logic [2:0] fp_role,fp_sti,fp_aluop;
  } packet_t;
  packet_t u_d,pipe_u_eff,pipe_v_eff,pipe_mem_u_q,mc_u_q,mc_query_u;
  function automatic logic fp_is_ext_load(input packet_t u);
    return u.ext; // arbitrary conservative exclusion
  endfunction
  logic state,mc_valid_q,pipe_mem_active_q,pipe_mem_we_q,pipe_mem_pair_q;
  logic mc_held_v_valid_q,pipe_new_load_req,pipe_new_mem_req,pipe_pair_lookahead;
  logic mc_fresh_read_pair_block,mc_prime_u_branch,mc_prime_v_branch;
  logic mc_boundary_ok,mc_prepare_ok,agi_prime_select,ref_prime_select,agi_guard,ref_guard;
  logic mc_fp_self_prime,mc_held_read_prime,mc_fresh_read_prime,mc_prime_base;
  logic mc_offer,mc_prime_offer,agi_prime_offer,ref_prime_offer,mem_next_req;
  logic [31:0] mc_pc_q,pipe_commit_eip,mc_query_phys,mc_phys_q,old_addr,new_addr;
  logic [2:0] agi_prime_width;
  logic [3:0] ref_prime_strb,old_strb,new_strb;
  logic [63:0] rng=64'hfe2942cc8615017d;
  integer checks=0,idle_differences=0,retained=0,fp=0,held=0,fresh=0,ordinary=0,agi=0,refp=0;
'''+body+'''
  task automatic check;
    #1;
    checks++;
    if (mem_next_req && {old_addr,old_strb} !== {new_addr,new_strb})
      $fatal(1,"PRIME-PAYLOAD-MISMATCH n=%0d valid=%b prime=%b agi=%b ref=%b old=%h/%h new=%h/%h",
             checks,mc_valid_q,mc_prime_offer,agi_prime_offer,ref_prime_offer,
             old_addr,old_strb,new_addr,new_strb);
    if (mc_prime_offer && mc_valid_q) $fatal(1,"PRIME-PAYLOAD owner overlap");
    if (!mem_next_req && {old_addr,old_strb} !== {new_addr,new_strb}) idle_differences++;
    if (mc_offer && !agi_prime_select && !ref_prime_select) retained++;
    if (mc_prime_offer && !agi_prime_select && !ref_prime_select) begin
      if (mc_fp_self_prime) fp++;
      else if (mc_held_read_prime) held++;
      else if (mc_fresh_read_prime) fresh++;
      else ordinary++;
    end
    if (agi_prime_offer) agi++;
    if (ref_prime_offer && !agi_prime_select) refp++;
  endtask
  initial begin
    state=S_PIPE; pipe_mem_pair_q=0; mc_fresh_read_pair_block=0;
    mc_prime_u_branch=0; mc_prime_v_branch=0;
    u_d='0; pipe_u_eff='0; pipe_v_eff='0; pipe_mem_u_q='0; mc_u_q='0; mc_query_u='0;
    pipe_u_eff.simple=1; pipe_u_eff.len=3; pipe_commit_eip=0; mc_pc_q=3;
    for (integer i=0;i<65536;i++) begin
      {mc_valid_q,pipe_mem_active_q,pipe_mem_we_q,mc_held_v_valid_q,
       pipe_new_load_req,pipe_new_mem_req,pipe_u_eff.is_fp,pipe_u_eff.is_mem,
       pipe_u_eff.is_store,pipe_pair_lookahead,mc_prepare_ok,mc_boundary_ok,
       agi_prime_select,ref_prime_select,agi_guard,ref_guard}=16'(i);
      rng=rng^(rng<<13); rng=rng^(rng>>7); rng=rng^(rng<<17);
      mc_query_phys=rng[31:0]; mc_phys_q=rng[63:32];
      mc_query_u.w8=rng[0]; mc_u_q.w8=rng[1];
      agi_prime_width=rng[2]?3'd1:3'd4; ref_prime_strb=rng[6:3];
      check();
    end
    if (!idle_differences || !retained || !fp || !held || !fresh || !ordinary || !agi || !refp)
      $fatal(1,"PRIME-PAYLOAD missing ownership/idle class");
    $display("PRIME-PAYLOAD-OK checks=%0d idle_differences=%0d retained=%0d fp=%0d held=%0d fresh=%0d ordinary=%0d agi=%0d ref=%0d",
             checks,idle_differences,retained,fp,held,fresh,ordinary,agi,refp);
    $finish;
  end
endmodule
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    source = args.source.resolve(strict=True)
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert source.stat().st_dev == scratch.stat().st_dev != Path(__file__).stat().st_dev
    inputs = {}
    pins = {}
    for name, digest in HASHES.items():
        path = source/name
        assert sha(path) == digest, name
        inputs[name] = path.read_text(); pins[str(path)] = digest
    for path in (Path(__file__).resolve(), Path(recipe.__file__).resolve()):
        pins[str(path)] = sha(path)
    header = inputs['core_mem_chain.svh']
    changed = recipe.transform(header)
    assert recipe.assignment(changed, 'mem_next_req') == recipe.assignment(header, 'mem_next_req')
    assert recipe.assignment(changed, 'mem_next_commit') == recipe.assignment(header, 'mem_next_commit')
    for invalid in (header+'\n', changed):
        try: recipe.transform(invalid)
        except ValueError: pass
        else: raise AssertionError('accepted drift/reapplication')
    root.mkdir()
    result = dict(passed=False,pins=pins,rows=[],whole_core=False,formal=False,
                  gameplay_ipc=None,fmax_mhz=None,invocation=os.environ.get('INVOCATION_ID'),
                  cpu_affinity=sorted(os.sched_getaffinity(0)),
                  caveat='Extracted payload/offer equations; other AGI/reference eligibility over-approximated.')
    start = time.monotonic()
    try:
        (root/'core_mem_chain.svh').write_text(changed)
        for mutant in (None,'always-live','always-retained','wrong-query-width','lost-agi-width'):
            label = mutant or 'positive'; folder = root/label; folder.mkdir()
            sv = folder/'tb.sv'; binary = folder/'a.out'
            sv.write_text(fixture(inputs,mutant))
            with (folder/'build.log').open('x') as stream:
                build = subprocess.run(['iverilog','-g2012','-s','tb','-o',str(binary),str(sv)],
                    stdout=stream,stderr=subprocess.STDOUT,timeout=15)
            assert build.returncode == 0, label
            with (folder/'run.log').open('x') as stream:
                run = subprocess.run(['vvp',str(binary)],stdout=stream,stderr=subprocess.STDOUT,timeout=40)
            log = (folder/'run.log').read_text()
            assert (run.returncode == 1 and 'PRIME-PAYLOAD-MISMATCH' in log) if mutant else (
                run.returncode == 0 and 'PRIME-PAYLOAD-OK checks=65536 ' in log), (label,log)
            result['rows'].append(dict(label=label,native_exit=run.returncode,log=log,
                artifacts={str(p):sha(p) for p in (sv,binary,folder/'build.log',folder/'run.log')}))
        result['passed'] = True
    finally:
        result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
        result['passed'] &= result['pins_unchanged']
        (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
