#!/usr/bin/env python3
"""Sequential source-extracted fragment engine + real L1 read-piece planner.

The producer FSM, translation and response timing are test inputs; this is not
a whole-core gate. Byte-touch assertions are independent of predecessor output.
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

from prepare_bus_cancel_payload import tail
from prepare_fragment_exact_reads import (DECL_NEW, DECL_OLD, SAVE_NEW, SAVE_OLD,
    MASK_NEW, L1_START, L1_END, between, engine, transform)

MODULE = '''module fragment_exact (
 input logic clk, rst_n,
 input logic [3:0] state, cur_size, raw_strb,
 input logic [31:0] cur_lin_nat, raw_data, bus_rdata,
 input logic request, write, paging_on, fe_translatable, fx_abort_q,
 input logic xlate_miss, perm_fault, sync_access_fault, fe_xlate_pend, bus_ack,
 output wire mem_req, mem_we, mem_ack_o,
 output wire [31:0] mem_addr, mem_wdata, mem_rdata_o,
 output wire [3:0] mem_wstrb
);
 localparam logic [3:0] S_WALK=1, S_SMI_SAVE=2, S_RSM=3, S_LOAD=4, S_LOAD2=5, S_STORE=6;
 wire rep_stos_stream_preissue_block=0, rep_movs_stream_preissue_block=0;
 wire fp_async_hold=0, a20_on=1, cur_is_d=1;
 // The core's actual redirect is registered-owner based too. Translation is
 // abstracted; use discontiguous physical pages to expose page-1 overreads.
 wire [31:0] cur_lin = fx_redirect_e ? ((cur_lin_nat & 32'hfffff000)+32'h1000) : cur_lin_nat;
 logic bd_req, bd_we, mem_req_pre_sq;
 logic [31:0] bd_addr, bd_wdata, mem_addr_pre;
 logic [3:0] bd_wstrb;
 function automatic logic [31:0] mem_xlate(input logic [31:0] addr, input logic is_data);
   return {((addr[31:12] == 20'h8) ? 20'h21 : (addr[31:12] == 20'h9) ? 20'h73 : addr[31:12]),addr[11:0]};
 endfunction
 always_comb begin
   bd_req=request; bd_we=write; bd_addr=cur_lin; bd_wdata=raw_data; bd_wstrb=raw_strb;
@BUS@
 end
@ENGINE@
 wire [31:0] c_addr=mem_addr;
 wire [3:0] c_wstrb=mem_wstrb;
@PIECES@
 assign mem_ack_o=mem_ack;
 assign mem_rdata_o=mem_rdata;
endmodule
'''


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, out = args.parent.resolve(strict=True), args.out.resolve()
    here = Path(__file__).resolve().parent
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and shutil.disk_usage(scratch).free > 4*1024**3
    core, bus, l1 = parent/'core/core.sv', parent/'core/core_bus_driver.svh', parent/'mem/ven_l1d.sv'
    original, header = core.read_text(), bus.read_text()
    fixed = transform(original, header)
    out.mkdir()
    paths = [core, bus, l1, Path(__file__), here/'prepare_fragment_exact_reads.py',
        here/'prepare_fragment_read_payload.py', here/'prepare_bus_cancel_payload.py',
        here/'tb_fragment_exact_reads.sv', Path('/usr/bin/iverilog').resolve(), Path('/usr/bin/vvp').resolve()]
    pins = {str(path): sha(path) for path in paths}

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    def write(name, value):
        with (out/name).open('x') as stream:
            stream.write(value)
        pins[str(out/name)] = sha(out/name)

    def module(source):
        return MODULE.replace('@BUS@', tail(header)).replace('@ENGINE@', engine(source)).replace(
            '@PIECES@', between(l1.read_text(), L1_START, L1_END))

    variants = [('positive', fixed, 0), ('predecessor', original, 1),
        ('bad-first-mask', fixed.replace(MASK_NEW, MASK_NEW.replace('fx_read_strb &', 'bd_wstrb &')), 1),
        ('bad-saved-mask', fixed.replace(SAVE_NEW, SAVE_OLD), 1),
        ('bad-owner', fixed.replace(MASK_NEW, MASK_NEW.replace('fx_eng ?', 'fx_act ?')), 1)]
    write('candidate-core.sv', fixed)
    for name, source, status in variants:
        assert not status or source != fixed
        write(name+'.sv', module(source))
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), whole_core=False))
    rows = []; errors = []; began = time.monotonic()

    def run(label, argv, expected=0, marker=None):
        argv = list(map(str, argv)); save(label+'.command.json', argv)
        with (out/(label+'.log')).open('x') as stream:
            native = subprocess.run(argv, stdout=stream, stderr=subprocess.STDOUT, timeout=30)
        rows.append(dict(label=label, native_exit=native.returncode, log_sha256=sha(out/(label+'.log'))))
        assert native.returncode == expected, rows[-1]
        if marker:
            assert marker in (out/(label+'.log')).read_text(), rows[-1]

    try:
        for name, _, status in variants:
            run(name+'-build', ['/usr/bin/iverilog', '-g2012', '-s', 'tb_fragment_exact_reads',
                '-o', out/(name+'.vvp'), out/(name+'.sv'), here/'tb_fragment_exact_reads.sv'])
            pins[str(out/(name+'.vvp'))] = sha(out/(name+'.vvp'))
            run(name, ['/usr/bin/vvp', out/(name+'.vvp')], status,
                'FRAGMENT-EXACT-FAIL' if status else 'FRAGMENT-EXACT-OK')
    except Exception as error:
        errors.append(dict(error=repr(error), traceback=traceback.format_exc()))
    stable = all(sha(path) == digest for path, digest in pins.items())
    result = dict(passed=not errors and stable, pins=pins, pins_unchanged=stable,
        rows=rows, errors=errors, seconds=time.monotonic()-began, whole_core=False,
        standard_suite=False, gameplay_ipc=None, timing_mhz=None)
    save('closed.json', result)
    print(json.dumps({key:value for key,value in result.items() if key!='pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
