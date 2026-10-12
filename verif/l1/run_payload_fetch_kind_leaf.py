#!/usr/bin/env python3
"""Check a possible stronger S_PIPE payload-kind cut; do not modify RTL.

Source-extracted request logic, exhaustive Boolean guard classes, native Icarus.
Residency/hazards are independent inputs; downstream squashes are abstracted as
arbitrary request cancellation. This is neither whole-core nor timing proof.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import traceback

import prepare_payload_code_hint as parent_recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def assignment(source, name):
    matches = re.findall(r'^    '+name+r'\s*=.*?;', source, re.M | re.S)
    if len(matches) != 1:
        raise ValueError('ambiguous source assignment: '+name)
    return matches[0]


def extract(core, bus):
    start = core.index('    pipe_frontend_ready = pipe_bytes_ok && !pipe_fetch_checked_handoff;')
    end = core.index('\n  end', start)
    frontend = core[start:end]
    names = ('pf_miss', 'pipe_new_load_req', 'pipe_new_store_req', 'pipe_load_req', 'pipe_store_req')
    requests = '\n'.join(assignment(core, name) for name in names)
    start = bus.index('      S_PIPE:  begin')
    end = bus.index('\n      S_LOAD: begin', start)
    # Keep the full actual branch, including payload writes. Dummy payload
    # types/function cannot feed request classification and are never observed.
    branch = bus[start:end]
    return frontend, requests, branch


WRAPPER = '''module request_kind(input wire [19:0] bits,
  output wire issued, output wire write_kind, output wire original_code,
  output wire proposed_code, output wire miss, output wire held);
  localparam S_PIPE=1;
  wire [2:0] state=S_PIPE;
  wire exec_issue_ok=bits[0], pipe_bytes_ok=bits[1], pipe_fetch_checked_handoff=bits[2];
  wire ic_fetch_ready=bits[3], uop_hit=bits[4], cycle_mode=bits[5];
  wire pipe_mem_active_q=bits[6],pipe_mem_we_q=bits[7],fp_issue_block=bits[8];
  wire [6:0] stall_cnt={6'd0,bits[9]},pending_mem_pen={6'd0,bits[10]};
  wire fp_sys_bail=bits[11],cs_extent_fault=bits[12],pipe_agi=bits[15];
  wire [2:0] mispred_bubbles={2'd0,bits[16]};
  wire fp_pipe_rd_haz=bits[17];
  typedef struct packed {logic is_mem;logic is_store;} decoded_t;
  wire decoded_t u_d={bits[13],bits[14]};
  typedef struct packed {logic w8;} effective_t;
  wire effective_t pipe_u_eff='0;
  wire [31:0] pipe_store_data=32'h12345678;
  function automatic [3:0] fp_mem_read_strobe(input effective_t value);
    fp_mem_read_strobe=value.w8 ? 4'h1 : 4'hf;
  endfunction
  reg pipe_frontend_ready,pf_miss,pipe_new_load_req,pipe_new_store_req,pipe_load_req,pipe_store_req;
  reg bd_req,bd_we;
  reg [3:0] bd_wstrb;
  reg [31:0] bd_wdata;
  always @* begin
FRONTEND
REQUESTS
    bd_req=0;bd_we=0;bd_wstrb=0;bd_wdata=0;
    case (state)
BRANCH
    endcase
  end
  // Translation/permission/fault/fragment guards can cancel, never create a
  // S_PIPE beat. Enumerate independent post-driver and fragment cancellations.
  assign issued=bd_req && bits[18] && !bits[19];
  assign write_kind=bd_we;
  assign original_code=issued && !(pipe_load_req || pipe_store_req);
  assign proposed_code=HINT;
  assign miss=pf_miss;
  assign held=pipe_mem_active_q;
endmodule
module tb;
  reg [19:0] bits;
  wire issued,write_kind,original_code,proposed_code,miss,held;
  request_kind dut(.*);
  integer active=0,fetches=0,reads=0,stores=0,held_reads=0,held_stores=0,idle_changes=0;
  initial begin
    for(integer i=0;i<1048576;i=i+1) begin
      bits=20'(i); #1;
      if(issued) begin
        active++;
        if(original_code!==proposed_code)
          $fatal(1,"PAYLOAD-FETCH-KIND-MISMATCH vector=%05x held=%b miss=%b old=%b new=%b",
                 bits,held,miss,original_code,proposed_code);
        if(original_code) fetches++;
        else if(write_kind) begin stores++; if(held) held_stores++; end
        else begin reads++; if(held) held_reads++; end
      end else if(original_code!==proposed_code) idle_changes++;
    end
    if(!(active>0 && fetches>0 && reads>0 && stores>0 && held_reads>0 && held_stores>0 && idle_changes>0))
      $fatal(1,"PAYLOAD-FETCH-KIND-VACUOUS");
    $display("PAYLOAD-FETCH-KIND-OK vectors=1048576 active=%0d fetch=%0d read=%0d store=%0d held_read=%0d held_store=%0d idle_changed=%0d",
        active,fetches,reads,stores,held_reads,held_stores,idle_changes);
    $finish;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    parent, root = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root != scratch and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    core, bus = [parent/'candidate/rtl/core'/name for name in ('core.sv', 'core_bus_driver.svh')]
    started = json.loads((parent/'build-started.json').read_text())
    assert sha(core) == parent_recipe.HASHES['rtl/core/core.sv'] == started['pins'][str(core)]
    assert sha(bus) == started['pins'][str(bus)]
    frontend, requests, branch = extract(core.read_text(), bus.read_text())
    flags = next(arg for arg in started['command'] if arg.startswith('VL_EXTRA_DEFINES='))
    defines = set(re.findall(r'\+define\+(\w+)', flags))
    assert len(defines) == 150 and {'VEN_IC_BRAM', 'VEN_FP_PIPE'} <= defines
    assert 'VEN_UOPCACHE' not in defines
    pins = {str(path): sha(path) for path in (Path(__file__), Path(parent_recipe.__file__),
            core, bus, parent/'build-started.json', Path('/usr/bin/iverilog'), Path('/usr/bin/vvp'))}
    root.mkdir()

    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    save('started.json', dict(pins=pins, profile_defines=sorted(defines),
        assumptions=['S_PIPE only; other states unchanged',
                     'each downstream cancellation is independent and cannot create a request',
                     'nonzero stall/penalty classes represented by one'],
        source_extract=dict(frontend=frontend, requests=requests, branch=branch),
        affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], rows=[], source_extracted=True, whole_core=False,
                  timing_verified=False, rtl_modified=False, gameplay_ipc=None)
    began = time.monotonic()
    try:
        for label, hint in (('positive', 'pf_miss'), ('lost_held_owner', '!pipe_bytes_ok'),
                            ('wrong_resident_kind', 'pf_miss || pipe_bytes_ok')):
            text = WRAPPER.replace('FRONTEND', frontend).replace('REQUESTS', requests).replace('BRANCH', branch).replace('HINT', hint)
            source, binary = root/(label+'.sv'), root/(label+'.vvp')
            source.write_text(text)
            command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(binary),
                       '-DVEN_IC_BRAM', '-DVEN_FP_PIPE', str(source)]
            save(label+'-command.json', command)
            with (root/(label+'-build.log')).open('x') as stream:
                built = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=20)
            assert built.returncode == 0, (label, 'build', built.returncode)
            with (root/(label+'.log')).open('x') as stream:
                native = subprocess.run(['/usr/bin/vvp', str(binary)], stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=50)
            log = (root/(label+'.log')).read_text()
            result['rows'].append(dict(label=label, native_exit=native.returncode, log=log,
                source_sha256=sha(source), binary_sha256=sha(binary)))
            assert ((native.returncode == 0 and 'PAYLOAD-FETCH-KIND-OK vectors=1048576 ' in log)
                    if label == 'positive' else
                    (native.returncode == 1 and 'PAYLOAD-FETCH-KIND-MISMATCH' in log)), (label, log)
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(path) == digest for path, digest in pins.items()),
                  seconds=time.monotonic()-began)
    result['passed'] = not result['errors'] and result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
