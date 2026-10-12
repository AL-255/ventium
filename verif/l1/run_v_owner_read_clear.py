#!/usr/bin/env python3
"""Native extracted U/V transitions for read-specific V clearing, not a core gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import prepare_v_owner_read_clear as patch
import test_pair_response_read_commit as base


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def fixture(source, mutant=None):
    candidate = patch.transform(source)
    # The old fixture checks read-specific response consumption too. Its
    # extractor expects one canonical response assignment, so reduce only this
    # already-qualified observation block in the input given to that extractor.
    # Actual request, U-owner and V-owner sequencer fragments are untouched.
    start=source.index('`ifdef VEN_RAW_V_READ_PRIME\n`ifndef VEN_P54_DUAL_LOAD_PRIME\n  // In this profile')
    end=source.index('`ifndef SYNTHESIS\n  always_ff @(posedge clk) if (rst_n && pipe_v_pair_accept)',start)
    canonical='''  assign mem_pair_rsp_ready = {mem_pair_rsp_valid[1] &&
                               (!pipe_mem_v_hit_q || pipe_int_commit), 1'b0};
'''
    compatible=source[:start]+canonical+source[end:]
    original=base.fixture(compatible)
    start_token='`ifdef VEN_P54_DUAL_LOAD_PAIR\n'
    begin=candidate.index(patch.WITNESS)
    end=candidate.index('`ifndef SYNTHESIS\n      if (smi_apic_store_commit',begin)
    fragment=candidate[begin:end]
    assert fragment.startswith(start_token)
    # Independent V registers consume the same extracted U-owner/request
    # history. Compare every edge; do not deposit any register state.
    fragment=fragment.replace('pipe_mem_v_hit_q','candidate_v_q').replace('pipe_mem_v_phys_q','candidate_phys_q')
    if mutant=='raw-fragment-ack':
        fragment=fragment.replace('mem_read_ack','bus_read_ack')
    elif mutant=='missing-read-ack':
        fragment=fragment.replace('                   mem_read_ack) ||',"                   1'b1) ||")
    fault="      if (take_fault) candidate_v_q <= 1'b0;\n"
    if mutant=='lost-fault-clear': fault=''
    addon='''  logic candidate_v_q;
  logic [31:0] candidate_phys_q;
  always @(posedge clk) begin
    if (!rst_n) candidate_v_q <= 1'b0;
    else begin
'''+fragment+fault+'''    end
  end
'''
    original=original.replace('  task automatic defaults;',addon+'\n  task automatic defaults;')
    anchor='''      if (old_ready !== new_ready)
'''
    assert original.count(anchor)==1
    original=original.replace(anchor,'''      if (pipe_mem_v_hit_q !== candidate_v_q ||
          (pipe_mem_v_hit_q && pipe_mem_v_phys_q !== candidate_phys_q))
        $fatal(1,"V-CLEAR-STATE-MISMATCH n=%0d",checks);
'''+anchor)
    return original


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    args=ap.parse_args(); core=args.core.resolve(strict=True); out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert shutil.disk_usage(scratch).free>4*1024**3
    assert os.sched_getaffinity(0)=={12}
    source=core.read_text(); changed=patch.transform(source)
    pins={str(p.resolve()):sha(p) for p in (core,Path(__file__),Path(patch.__file__),
        Path(base.__file__),Path(base.__file__).with_name('prove_pair_response_read_commit.py'),
        Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'))}
    out.mkdir(); (out/'core.sv').write_text(changed); pins[str(out/'core.sv')]=sha(out/'core.sv')
    def save(name,d):
        with (out/name).open('x') as f:json.dump(d,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cpu_affinity=[12]))
    begin=time.monotonic(); result=dict(passed=False,rows=[])
    try:
        for label in ('positive','raw-fragment-ack','missing-read-ack','lost-fault-clear'):
            folder=out/label; folder.mkdir()
            path=folder/'tb.sv'; path.write_text(fixture(source,None if label=='positive' else label))
            binary=folder/'tb.vvp'
            command=['iverilog','-g2012','-DVEN_FP_PIPE','-DVEN_PIPE_MEM_CHAIN',
                '-DVEN_PIPE_REG_LOAD_PRIME','-DVEN_RAW_V_READ_PRIME',
                '-DVEN_P54_DUAL_LOAD_PAIR','-s','tb','-o',str(binary),str(path)]
            row=dict(label=label,command=command); result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                r=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=15)
            row['build_exit']=r.returncode; assert r.returncode==0,(label,'build')
            with (folder/'run.log').open('x') as f:
                r=subprocess.run(['vvp',str(binary)],stdout=f,stderr=subprocess.STDOUT,timeout=30)
            row.update(native_exit=r.returncode,log=(folder/'run.log').read_text(),
                artifacts={str(p):sha(p) for p in (path,binary,folder/'build.log',folder/'run.log')})
            if label=='positive':
                assert r.returncode==0 and 'PAIR-RESPONSE-LEAF-OK' in row['log'],row
            else:
                assert r.returncode!=0 and ('V-CLEAR-' in row['log']),row
        result['passed']=True
    except BaseException as exc:
        import traceback
        result.update(error=repr(exc),traceback=traceback.format_exc())
    finally:
        result.update(pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
            seconds=time.monotonic()-begin,whole_core=False,full_cache=False,
            other_priming_profiles=False,fmax_mhz=None,gameplay_ipc=None)
        result['passed'] &= result['pins_unchanged']
        save('closed.json',result)
        print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
