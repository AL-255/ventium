#!/usr/bin/env python3
"""Actual source-extracted bus-tail miter; request producer/TLB are abstracted.

This bounded Icarus/Z3 test is not a complete fragment/cache/system test.
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
from prepare_bus_cancel_payload import ACCESS_NEW, transform, tail
from test_bus_cancel_payload import proof

MODULE = '''module @NAME@ (
 input logic [15:0] controls,
 input logic [31:0] raw_addr, raw_data, linear, translated_d, translated_i,
 input logic [3:0] raw_strb,
 output logic bd_req, bd_we,
 output logic [31:0] bd_addr, bd_wdata, mem_addr_pre,
 output logic [3:0] bd_wstrb,
 output logic mem_req_pre_sq
);
 localparam logic [2:0] S_WALK=3'd1, S_SMI_SAVE=3'd2, S_RSM=3'd3;
 wire [2:0] state=controls[2:0];
 wire fe_translatable=controls[3], paging_on=controls[4], xlate_miss=controls[5];
 wire fe_xlate_pend=controls[6], perm_fault=controls[7], sync_access_fault=controls[8];
 wire rep_stos_stream_preissue_block=controls[9], rep_movs_stream_preissue_block=controls[10];
 wire a20_on=controls[11], fp_async_hold=controls[12], cur_is_d=controls[13];
 wire [31:0] cur_lin=linear;
 function automatic logic [31:0] mem_xlate(input logic [31:0] address, input logic data_access);
   return address ^ (data_access ? translated_d : translated_i);
 endfunction
 always_comb begin
   bd_req=controls[14]; bd_we=controls[15];
   bd_addr=raw_addr; bd_wdata=raw_data; bd_wstrb=raw_strb;
@BODY@
 end
endmodule
'''


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    a=ap.parse_args()
    source,out=a.source.resolve(strict=True),a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    here=Path(__file__).resolve().parent
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>4*1024**3 and os.environ.get('INVOCATION_ID')
    old=source.read_text(); new=transform(old)
    out.mkdir()
    pins={str(p):sha(p) for p in (source,Path(__file__),here/'prepare_bus_cancel_payload.py',
        here/'test_bus_cancel_payload.py',here/'tb_bus_cancel_payload.sv',
        Path('/usr/bin/iverilog').resolve(),Path('/usr/bin/vvp').resolve(),Path('/usr/bin/z3').resolve())}
    def save(n,v):
        with (out/n).open('x') as f: json.dump(v,f,indent=2)
    def write(n,v):
        with (out/n).open('x') as f: f.write(v)
        pins[str(out/n)]=sha(out/n)
    def module(name,body): return MODULE.replace('@NAME@',name).replace('@BODY@',tail(body))
    write('control.sv',module('bus_cancel_control',old))
    write('candidate-header.svh',new)
    bad_pre=new.replace('mem_req_pre_sq = bd_req && !rep_stos_stream_preissue_block &&',
                        'mem_req_pre_sq = bd_req && !sync_access_fault && !rep_stos_stream_preissue_block &&')
    variants=[('positive',new,None,0),
        ('bad-permission',new.replace('if (xlate_miss || fe_xlate_pend || perm_fault) bd_req',
                                     'if (xlate_miss || fe_xlate_pend) bd_req'),'permission',1),
        ('bad-a20',new.replace("if (!a20_on) bd_addr[20] = 1'b0;", "if (1'b0) bd_addr[20] = 1'b0;"),'a20',1),
        ('bad-pre',bad_pre,'pre',1)]
    for name,body,mutation,expected in variants:
        assert not expected or body!=new
        write(name+'.sv',module('bus_cancel_candidate',body))
        write(name+'.smt2',proof(mutation))
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)),whole_core=False,translation_abstracted=True))
    began=time.monotonic(); rows=[]; result=dict(passed=False,errors=[],gameplay_ipc=None,timing_mhz=None)
    def run(label,command,expected=0,marker=None,seconds=120):
        command=list(map(str,command)); save(label+'.command.json',command)
        with (out/(label+'.log')).open('x') as log:
            p=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=seconds)
        rows.append(dict(label=label,native_exit=p.returncode,log_sha256=sha(out/(label+'.log'))))
        assert p.returncode==expected,rows[-1]
        if marker: assert marker in (out/(label+'.log')).read_text(),rows[-1]
    try:
        for name,_,mutation,expected in variants:
            run(name+'-proof',['/usr/bin/z3','-smt2',out/(name+'.smt2')])
            assert (out/(name+'-proof.log')).read_text().strip()==('sat' if expected else 'unsat')
            run(name+'-build',['/usr/bin/iverilog','-g2012','-s','tb_bus_cancel_payload',
                '-o',out/(name+'.vvp'),out/'control.sv',out/(name+'.sv'),here/'tb_bus_cancel_payload.sv'],seconds=30)
            pins[str(out/(name+'.vvp'))]=sha(out/(name+'.vvp'))
            run(name,['/usr/bin/vvp',out/(name+'.vvp')],expected,
                marker='BUS_CANCEL_' if expected else 'BUS-CANCEL-PAYLOAD-OK checked=532480 ')
        result['passed']=True
    except BaseException as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  rows=rows,seconds=time.monotonic()-began,whole_core=False,translation_abstracted=True)
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
