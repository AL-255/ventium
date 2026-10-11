#!/usr/bin/env python3
"""Compare the real checked raw descriptor with the early address-field payload.

Real producer predicates and descriptor functions are extracted from pinned
RTL. Cache-return ownership is a mocked table. This is not a whole-core gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_mc_address_payload import OLD, NEW, transform, raw_descriptor, assignment


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    source,out=args.core.resolve(strict=True),args.out.resolve()
    repo=Path(__file__).resolve().parents[2]
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>4*1024**3
    assert subprocess.run([str(repo/'tools/build_scope.sh'),'--is-active'],pass_fds=(9,)).returncode==0
    header=source/'core_mem_chain.svh'
    original=header.read_text(); changed=transform(original)
    held=(source/'core_raw_held_prime.svh').read_text()
    raw_mov=(source/'core_raw_branch_mov.svh').read_text()
    assert sha(source/'core_raw_held_prime.svh')=='032530542135f8744c332aa16fbfbf4bd36fac24230b8b1c20c4d989a0630040'
    assert sha(source/'core_raw_branch_mov.svh')=='b23f76398f176248ac537e8a7b8d9101914a3a538623a779a9d51cb921f27d04'
    out.mkdir()
    pins={str(p):sha(p) for p in (header,source/'core_raw_held_prime.svh',source/'core_raw_branch_mov.svh',
        source/'ventium_decode_pkg.sv',source/'ventium_alu_pkg.sv',Path(__file__),
        Path(__file__).with_name('prepare_mc_address_payload.py'),Path(__file__).with_name('mc_address_payload_stim.svh'),
        repo/'tools/build_scope.sh',Path('/usr/bin/iverilog').resolve(),Path('/usr/bin/vvp').resolve())}
    def save(name,value):
        with (out/name).open('x') as f:json.dump(value,f,indent=2)
    pkg=(source/'ventium_decode_pkg.sv').read_text()
    begin=pkg.index('  typedef struct packed {')
    struct=pkg[begin:pkg.index('  } fpd_t;',begin)+len('  } fpd_t;')]
    branch=original.split('`elsif VEN_RAW_BRANCH_FALLTHROUGH_PRIME\n',1)[1].split('`else\n',1)[0]
    fp=original.split('  assign mc_fp_self_prime =',1)[1].split(';',1)[0]
    hp=held.split('  assign mc_held_read_prime =',1)[1].split(';',1)[0]
    selection=assignment(branch,'mc_prime_v_branch')+'\nassign mc_fp_self_prime ='+fp+';\nassign mc_held_read_prime ='+hp+';\n'
    assert "ALU_ADD = 5'd0" in (source/'ventium_alu_pkg.sv').read_text()
    assert "FK_NONE   = 3'd0" in pkg and 'FK_MEM    = FK_NONE' in pkg
    declaration='''module tb;
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
    expected=OLD.replace('assign mc_query_seg','assign old_seg').replace('assign mc_query_ea','assign old_ea')
    stimulus=Path(__file__).with_name('mc_address_payload_stim.svh').read_text()
    mutated=[('positive',NEW,0),
        ('wrong-held',NEW.replace('if (mc_held_read_prime) mc_address_payload = pipe_mem_v_q;',
                                 'if (mc_held_read_prime) mc_address_payload = pipe_u_eff;'),1),
        ('wrong-default',NEW.replace('mc_address_payload = v_d;','mc_address_payload = pipe_u_eff;'),1)]
    for name,payload,_ in mutated:
        if name!='positive':assert payload!=NEW
        p=out/(name+'.sv')
        with p.open('x') as f:f.write(declaration+raw_mov+'\n'+raw_descriptor(original)+'\n'+selection+expected+payload+stimulus+'endmodule\n')
        pins[str(p)]=sha(p)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    runs,error,start=[],None,time.monotonic()
    try:
        for name,_,expected_exit in mutated:
            commands=[('build-'+name,['/usr/bin/iverilog','-g2012','-s','tb','-DVEN_RAW_V_READ_PRIME',
                '-DVEN_RAW_BRANCH_FALLTHROUGH_PRIME','-DVEN_FAST_XCHG_R','-o',str(out/(name+'.vvp')),str(out/(name+'.sv'))],0),
                (name,['/usr/bin/vvp',str(out/(name+'.vvp'))],expected_exit)]
            for label,command,code in commands:
                save(label+'.command.json',command)
                with (out/(label+'.log')).open('x') as f:
                    p=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=90)
                runs.append(dict(label=label,native_exit=p.returncode,log_sha256=sha(out/(label+'.log'))))
                assert p.returncode==code,runs[-1]
            text=(out/(name+'.log')).read_text()
            assert ('MC-ADDRESS-PAYLOAD-OK samples=65536' if not expected_exit else 'MC_ADDRESS_PAYLOAD_MISMATCH') in text
            pins[str(out/(name+'.vvp'))]=sha(out/(name+'.vvp'))
    except BaseException as exc:
        import traceback
        error=dict(error=repr(exc),traceback=traceback.format_exc())
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=error is None and stable,pins=pins,pins_unchanged=stable,runs=runs,error=error,
        seconds=time.monotonic()-start,full_core=False,real_cache=False,timing_mhz=None,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
