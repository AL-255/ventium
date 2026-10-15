"""Extract real raw descriptor/selector equations and check the early shape.

Over-approximate packet fields with arbitrary data, constrained only by the
core's actual live/held mux and branch-not-memory/FP decoder invariant. Cache
ownership is a mocked returned-byte mask, not a complete cache simulation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

import prepare_branch_address_shape as recipe
from prepare_mc_address_payload import OLD, NEW, raw_descriptor, assignment


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f: json.dump(value, f, indent=2)


def fixture(source, mutant=None):
    header = (source/'core_mem_chain.svh').read_text()
    recipe.transform(header)
    pkg = (source/'ventium_decode_pkg.sv').read_text()
    begin = pkg.index('  typedef struct packed {')
    struct = pkg[begin:pkg.index('  } fpd_t;',begin)+len('  } fpd_t;')]
    held = (source/'core_raw_held_prime.svh').read_text()
    branch = header.split('`elsif VEN_RAW_BRANCH_FALLTHROUGH_PRIME\n',1)[1].split('`else\n',1)[0]
    fp = header.split('  assign mc_fp_self_prime =',1)[1].split(';',1)[0]
    hp = held.split('  assign mc_held_read_prime =',1)[1].split(';',1)[0]
    selection = assignment(branch,'mc_prime_v_branch')+'\nassign mc_fp_self_prime ='+fp+';\nassign mc_held_read_prime ='+hp+';\n'
    declaration = '''module tb;
  localparam int SG_CS=0, SG_SS=1, SG_DS=2, S_PIPE=1;
  localparam logic [4:0] ALU_ADD=0;
  localparam logic [2:0] FK_MEM=0;
'''+struct+'''
  fpd_t pipe_u_eff,pipe_v_eff,v_d,u_d,pipe_mem_u_q,pipe_mem_v_q,mc_query_u;
  logic mc_prime_v_branch,mc_fp_self_prime,mc_held_read_prime;
  logic pipe_mem_active_q,mc_valid_q,pipe_pair_lookahead,v_bytes_ok;
  logic u_pred_taken,v_pred_taken,mc_held_v_valid_q,pipe_mem_we_q,pipe_mem_pair_q;
  logic agi_prime_select,ref_prime_select;
  int state;
  logic [31:0] eip,pipe_mem_eip_q,mc_query_pc,returned_mask,flin;
  logic [31:0] seg_base[6],seg_limit[6],gpr_o[8];
  logic [7:0] ic_front_bytes[16];
  logic [31:0] pipe_load_addr,d_ea,old_ea,mc_query_ea;
  logic [2:0] pipe_mem_seg,d_seg,old_seg,mc_query_seg;
  assign flin=seg_base[SG_CS]+eip;
  function automatic logic ic_buffered(input logic [31:0] address);
    return returned_mask[address[4:0]];
  endfunction
'''
    payload = NEW.replace(recipe.PAYLOAD,recipe.PAYLOAD_NEW)
    if mutant == 'drop-held':
        payload = recipe.once(payload,'if (mc_held_read_prime) mc_address_payload = pipe_mem_v_q;', '')
    elif mutant == 'drop-fp':
        payload = recipe.once(payload,'if (mc_fp_self_prime) mc_address_payload = pipe_u_eff;', '')
    elif mutant == 'never-branch': payload = recipe.once(payload,'if (v_d.is_branch) begin',"if (1'b0) begin")
    elif mutant == 'always-branch': payload = recipe.once(payload,'if (v_d.is_branch) begin',"if (1'b1) begin")
    elif mutant is not None: raise ValueError(mutant)
    stimulus = Path(__file__).with_name('mc_address_payload_stim.svh').read_text()
    # The old stimulus over-approximated the live V mux as independent packets.
    # Preserve real source identity and the decoder invariant explicitly here.
    stimulus = recipe.once(stimulus,'      u_d=pipe_u_eff;', '''      if (pipe_v_eff.is_branch) begin
        pipe_v_eff.is_mem=0; pipe_v_eff.is_fp=0;
      end
      v_d=pipe_v_eff;
      if (pipe_mem_active_q) begin
        pipe_u_eff=pipe_mem_u_q; pipe_v_eff=pipe_mem_v_q;
      end
      u_d=pipe_u_eff;''')
    stimulus = recipe.once(stimulus,'if(mc_query_u.len!=0 || agi_prime_select || ref_prime_select)',
        'if((mc_query_u.len!=0 && (mc_query_u.is_mem || mc_query_u.is_fp)) || agi_prime_select || ref_prime_select)')
    expected = OLD.replace('assign mc_query_seg','assign old_seg').replace('assign mc_query_ea','assign old_ea')
    return declaration+(source/'core_raw_branch_mov.svh').read_text()+'\n'+raw_descriptor(header)+'\n'+selection+expected+payload+stimulus+'endmodule\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('source','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); source=a.source.resolve(strict=True); root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    repo=Path(__file__).resolve().parents[2]
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>4*1024**3
    subprocess.run([repo/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    pins={str(p.resolve()):sha(p) for p in (Path(__file__),Path(recipe.__file__),
        Path(__file__).with_name('prepare_mc_address_payload.py'),
        Path(__file__).with_name('mc_address_payload_stim.svh'),
        *[source/n for n in ('core.sv','core_mem_chain.svh','core_raw_held_prime.svh',
          'core_raw_branch_mov.svh','ventium_decode_pkg.sv','ventium_alu_pkg.sv')])}
    assert 'assign pipe_v_eff    = pipe_mem_active_q ? pipe_mem_v_q    : v_d;' in (source/'core.sv').read_text()
    root.mkdir(); (root/'core_mem_chain.svh').write_text(recipe.transform((source/'core_mem_chain.svh').read_text()))
    save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID']))
    result=dict(passed=False,rows=[],errors=[],whole_core=False,gameplay_ipc=None,fmax_mhz=None)
    begin=time.monotonic()
    try:
        for mutant in (None,'drop-held','drop-fp','never-branch','always-branch'):
            name=mutant or 'positive'; sv=root/(name+'.sv'); binary=root/(name+'.vvp')
            sv.write_text(fixture(source,mutant))
            build=['iverilog','-g2012','-s','tb','-DVEN_RAW_V_READ_PRIME',
                   '-DVEN_RAW_BRANCH_FALLTHROUGH_PRIME','-DVEN_FAST_XCHG_R','-o',str(binary),str(sv)]
            with (root/(name+'-build.log')).open('x') as f:
                code=subprocess.run(build,stdout=f,stderr=subprocess.STDOUT,timeout=20).returncode
            assert code==0
            with (root/(name+'.log')).open('x') as f:
                code=subprocess.run(['vvp',str(binary)],stdout=f,stderr=subprocess.STDOUT,timeout=60).returncode
            output=(root/(name+'.log')).read_text()
            assert code==(1 if mutant else 0), (name,output)
            assert ('MC_ADDRESS_PAYLOAD_MISMATCH' if mutant else 'MC-ADDRESS-PAYLOAD-OK samples=65536') in output
            result['rows'].append(dict(name=name,native_exit=code,source_sha256=sha(sv),log_sha256=sha(root/(name+'.log'))))
        result['passed']=True
    except Exception as e: result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']; save(root/'closed.json',result)
    print(json.dumps(result,indent=2),flush=True); return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
