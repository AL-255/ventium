#!/usr/bin/env python3
"""Bounded, source-extracted fragment-output miter, not a whole-core gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

from prepare_bus_cancel_payload import tail
from prepare_fragment_read_payload import NEW, blocks, transform
from test_fragment_read_payload import proof

MODULE = '''module @NAME@ (
 input logic [22:0] controls,
 input logic [31:0] linear, raw_addr, raw_data, translated_d, translated_i,
 input logic [31:0] bus_data, saved_data, saved_low,
 input logic [3:0] raw_strb, saved_strb, size,
 input logic [2:0] first,
 output wire [10:0] control_out,
 output wire [159:0] payload_out,
 output wire [3:0] strobes_out
);
 localparam logic [3:0] S_WALK=4'd1, S_SMI_SAVE=4'd2, S_RSM=4'd3,
     S_LOAD=4'd4, S_LOAD2=4'd5, S_STORE=4'd6;
 wire [3:0] state=controls[3:0];
 wire fx_act=controls[4], fx_wr=controls[5];
 wire [1:0] fx_ph=controls[7:6];
 wire fx_abort_q=controls[8], paging_on=controls[9], fe_translatable=controls[10];
 wire xlate_miss=controls[13], fe_xlate_pend=controls[14], perm_fault=controls[15];
 wire sync_access_fault=controls[16], rep_stos_stream_preissue_block=controls[17];
 wire rep_movs_stream_preissue_block=controls[18], fp_async_hold=controls[19];
 wire a20_on=controls[20], cur_is_d=controls[21], bus_ack=controls[22];
 wire [31:0] cur_lin=linear, cur_lin_nat=linear;
 wire [3:0] cur_size=size, fx_wstrb_q=saved_strb;
 wire [2:0] fx_first=first;
 wire [31:0] fx_wdata_q=saved_data, fx_lo=saved_low, bus_rdata=bus_data;
 wire [31:0] fx_merged=(fx_lo & ~(32'hffffffff << ({2'd0,fx_first} << 3))) |
                           (bus_rdata << ({2'd0,fx_first} << 3));
 logic bd_req, bd_we, mem_req_pre_sq;
 logic [31:0] bd_addr, bd_wdata, mem_addr_pre;
 logic [3:0] bd_wstrb;
 wire mem_req, mem_we, fx_probing;
 wire [31:0] mem_addr, mem_wdata;
 wire [3:0] mem_wstrb;
 function automatic logic [31:0] mem_xlate(input logic [31:0] address, input logic data_access);
   return address ^ (data_access ? translated_d : translated_i);
 endfunction
 always_comb begin
   bd_req=controls[11]; bd_we=controls[12];
   bd_addr=raw_addr; bd_wdata=raw_data; bd_wstrb=raw_strb;
@BUS@
 end
@STATE@
@OUTPUT@
 assign control_out={fx_eng, fx_merge_e, fx_hold_e, fx_start, fx_probing,
                     mem_read_ack, mem_req_pre_sq, bd_req, mem_ack, mem_we, mem_req};
 assign payload_out={mem_addr_pre,mem_addr,mem_wdata,mem_rdata,bd_wdata};
 assign strobes_out=mem_wstrb;
endmodule
'''


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent=args.parent.resolve(strict=True); out=args.out.resolve()
    here=Path(__file__).resolve().parent
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>4*1024**3
    core=parent/'core.sv'; bus=parent/'core_bus_driver.svh'
    old=core.read_text(); bus_text=bus.read_text(); new=transform(old,bus_text)
    out.mkdir()
    pins={str(p):sha(p) for p in (core,bus,Path(__file__),
        here/'prepare_fragment_read_payload.py',here/'prepare_bus_cancel_payload.py',
        here/'test_fragment_read_payload.py',here/'tb_fragment_read_payload.sv',
        Path('/usr/bin/iverilog').resolve(),Path('/usr/bin/vvp').resolve(),Path('/usr/bin/z3').resolve())}

    def save(name,value):
        with (out/name).open('x') as stream:
            json.dump(value,stream,indent=2)

    def write(name,value):
        with (out/name).open('x') as stream:
            stream.write(value)
        pins[str(out/name)]=sha(out/name)

    def module(name,source):
        state,output=blocks(source)
        return MODULE.replace('@NAME@',name).replace('@BUS@',tail(bus_text)).replace(
            '@STATE@',state).replace('@OUTPUT@',output)

    write('candidate-core.sv',new)
    write('control.sv',module('fragment_read_control',old))
    variants=[('positive',new,None,0),
        ('bad-paging',new.replace(NEW,NEW.replace('fx_state_ok && paging_on &&', 'fx_state_ok &&')),'no-paging',1),
        ('bad-abort',new.replace(NEW,NEW.replace('(!fx_act || fx_abort_q)', '!fx_act')),'no-abort-replacement',1),
        ('bad-cross',new.replace(NEW,NEW.replace('&& fx_cross &&', '&&')),'no-cross',1)]
    for name,body,mutation,status in variants:
        assert status==0 or body!=new
        write(name+'.sv',module('fragment_read_candidate',body))
        write(name+'.smt2',proof(mutation))
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)),whole_core=False,
        request_producer_and_sequencer_abstracted=True,unknown_fault_controls_qualified=False))
    started=time.monotonic(); rows=[]; errors=[]

    def run(label,argv,expected=0,marker=None):
        argv=list(map(str,argv)); save(label+'.command.json',argv)
        with (out/(label+'.log')).open('x') as stream:
            result=subprocess.run(argv,stdout=stream,stderr=subprocess.STDOUT,timeout=45)
        rows.append(dict(label=label,native_exit=result.returncode,log_sha256=sha(out/(label+'.log'))))
        assert result.returncode==expected, rows[-1]
        if marker:
            assert marker in (out/(label+'.log')).read_text(), rows[-1]

    try:
        for name,_,mutation,status in variants:
            run(name+'-proof',['/usr/bin/z3','-smt2',out/(name+'.smt2')])
            assert (out/(name+'-proof.log')).read_text().strip()==('sat' if status else 'unsat')
            run(name+'-build',['/usr/bin/iverilog','-g2012','-s','tb_fragment_read_payload',
                '-o',out/(name+'.vvp'),out/'control.sv',out/(name+'.sv'),here/'tb_fragment_read_payload.sv'])
            pins[str(out/(name+'.vvp'))]=sha(out/(name+'.vvp'))
            run(name,['/usr/bin/vvp',out/(name+'.vvp')],status,
                'FRAGMENT_PAYLOAD_MISMATCH' if status else 'FRAGMENT-READ-PAYLOAD-OK checked=204800 ')
    except BaseException as error:
        errors.append(dict(error=repr(error),traceback=traceback.format_exc()))
    unchanged=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=not errors and unchanged,pins=pins,pins_unchanged=unchanged,
        rows=rows,errors=errors,seconds=time.monotonic()-started,whole_core=False,
        unknown_fault_controls_qualified=False,gameplay_ipc=None,timing_mhz=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
