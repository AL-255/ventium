"""Private repair of the frozen FPGA keyboard transmitter's inhibit handling.

Preserve the existing byte/ready interface and timings. Never edit the active
FPGA export; this source must still pass integration/timing/hardware acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil

import run_kbd_inhibit_witness as witness


def transform(source):
    assert hashlib.sha256(source.encode()).hexdigest()==witness.INJECTOR_SHA
    old='''                SEND: begin
                    if (half_count == CELL_CYCLES - 1'b1) begin'''
    new='''                SEND: begin
                    if (!host_clk_release) begin
                        // The host owns the wire: do not shift an invisible
                        // suffix and then advertise the queued byte as done.
                        // Keep the accepted byte and restart its complete frame
                        // after the original continuous-idle requirement.
                        // A stop falling edge already observed for a full
                        // synchronous clock completes the byte instead; never
                        // duplicate it merely because inhibition follows stop.
                        if (bit_idx == 4'd10 && half_count > HALF_CYCLES)
                            state <= IDLE;
                        else
                            state <= WAIT_IDLE;
                        bit_idx <= 4'd0;
                        half_count <= 0;
                        idle_count <= 0;
                    end else if (half_count == CELL_CYCLES - 1'b1) begin'''
    assert source.count(old)==1
    return source.replace(old,new)


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();out=a.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==witness.ROOT.parent
    assert out.parent.resolve(strict=True)==witness.ROOT and not out.exists()
    assert shutil.disk_usage(witness.ROOT).free>4*1024**3
    before=witness.INJECTOR.read_text();after=transform(before)
    proof=witness.ROOT/'kbd-inhibit-witness-r2'
    started=json.loads((proof/'started.json').read_text());done=json.loads((proof/'closed.json').read_text())
    assert done['witness_matrix_passed'] and not done['correctness'] and done['pins_unchanged']
    assert len(done['rows'])==46 and sum(r['expected_red'] and r['native_exit']==1 for r in done['rows'])==42
    assert sum(not r['expected_red'] and r['native_exit']==0 for r in done['rows'])==4
    pins=dict(started['pins'])
    for p in (proof/'started.json',proof/'closed.json',Path(__file__).resolve(),Path(witness.__file__).resolve()):
        pins[str(p)]=witness.sha(p)
    for r in done['rows']:pins[r['log']]=r['log_sha256']
    assert all(witness.sha(p)==h for p,h in pins.items())
    out.mkdir()
    with (out/'ven_ps2_kbd_inject.v').open('x') as stream:stream.write(after)
    result=dict(prepared_not_qualified=True,parent_sha256=witness.INJECTOR_SHA,
        candidate_sha256=witness.sha(out/'ven_ps2_kbd_inject.v'),pins=pins,
        additional_storage_bits=0,interface_changes=False,physical_fpga=False,standard_suite=False,gameplay_ipc=None)
    with (out/'prepared.json').open('x') as stream:json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}))


if __name__=='__main__':main()
