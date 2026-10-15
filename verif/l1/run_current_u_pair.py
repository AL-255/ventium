"""Actual full-cache comparison for generic and current-U-only clients.

Specialized DUT is compared with the original cache behind an explicit input
contract filter. That is NOT unconditional old/new equivalence: no-U and
standalone requests are rejected intentionally. No FPGA run is launched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

import prepare_current_u_pair as recipe
import run_l1_legacy_capture_cut as original

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DATA = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve()
sha = original.sha


def fixture(ports, special):
    source = (HERE/'tb_l1d_mem_chain.sv').read_text()
    source = recipe.once(source, '  int ticks=0, accepted=0, backing=0;',
                         '  logic hold_ack=0;\n  int ticks=0, accepted=0, backing=0;')
    source = recipe.once(source, 'assign m_ack=m_req && ((ticks%3)==0);',
                         'assign m_ack=m_req && !hold_ack && ((ticks%3)==0);')
    missing = '''  logic c_read_ack, c_rdata_hi_uncontended, c_pair_intent_ready;
  wire c_payload_code=c_code;
  wire c_payload_cacheable=cacheable;
  wire c_pair_intent=c_pair_req;
'''
    observe = original.observer(ports)
    if special:
        observe = recipe.once(observe, '.pair_req_valid(pair_req_valid)',
                               '.pair_req_valid(contract_pair_valid)')
        observe = recipe.once(observe,
            "if((1'b1) && pair_bank_conflict!==ref_pair_bank_conflict)",
            'if((pair_req_valid == contract_pair_valid) && pair_bank_conflict!==ref_pair_bank_conflict)')
    controls = '''  wire [1:0] contract_pair_valid =
      (c_req && !c_we && pair_req_valid == 2'b10) ? pair_req_valid : 2'b00;
'''
    source = recipe.once(source, '  ven_l1d dut(.*);', missing + controls +
        f'  ven_l1d #(.PAIR_CURRENT_U_ONLY(1\'b{int(special)})) dut(.*);\n' + observe)
    # The original fixture's complete memory-chain tests stay intact. Append
    # all bank/size/hint/held/invalidation tests, changing only explicit client
    # contract expectations for standalone requests in the specialized mode.
    leaf = (HERE/'l1_legacy_capture_cut_leaf.svh').read_text()
    if special:
        leaf = recipe.once(leaf, "if(pair_req_ready!=2'b11)", "if(pair_req_ready!=2'b00)")
        leaf = recipe.once(leaf, '''      if(pair_rsp_valid!=2'b11 || pair_rsp_owner!=pair_owner ||
         pair_rsp_data[0]!=word_at(pair_paddr[0]) ||
         pair_rsp_data[1]!=word_at(pair_paddr[1]))''', "      if(pair_rsp_valid!=2'b00)")
        leaf = recipe.once(leaf, "if(pair_rsp_valid!=0 || pair_rsp_cancel!=2'b11)",
                           "if(pair_rsp_valid!=0 || pair_rsp_cancel!=2'b00)")
    marker = "    // Every bank combination, byte/dword size, and irrelevant next COMMIT.\n"
    orphan = f'''    // Empty-slot, no-U request: this is admitted by the general interface
    // and deliberately rejected by the specialized current-U contract.
    pair_req_valid=2'b10; pair_rsp_ready=0;
    pair_paddr[1]='h2024; pair_size_log2[1]=2'd2;
    #1;
    if (c_req || pair_req_ready != 2'd{0 if special else 2})
      $fatal(1,"CURRENT-U-EMPTY-SLOT admission wrong");
    @(posedge clk); #1;
    if (pair_rsp_valid != 2'd{0 if special else 2})
      $fatal(1,"CURRENT-U-EMPTY-SLOT response wrong");
    cut_idle();
'''
    leaf = recipe.once(leaf, marker, orphan + marker)
    source = recipe.once(source, '  initial begin\n    for(int i=0;i<65536;i++)',
                          leaf + '\n  initial begin\n    for(int i=0;i<65536;i++)')
    source = recipe.once(source, '    $finish;',
        '    run_legacy_capture_cut();\n    $display("CURRENT-U-MITER-OK edges=%0d",cut_miter_edges);\n    $finish;')
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == set(range(32))
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == original.VL
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'], check=True, timeout=10)
    parent = DATA/'prefix-payload-core-r1'
    prior = json.loads((parent/'build-started.json').read_text())
    source_path = parent/'candidate/rtl/mem/ven_l1d.sv'
    source = source_path.read_text()
    candidate = recipe.transform(source, 'rtl/mem/ven_l1d.sv')
    definitions = set(prior['definitions'])
    assert len(definitions) == 152
    assert not {'SYNTHESIS','VEN_P54_DUAL_LOAD_PRIME','VEN_P54_STORE_LOAD_PAIR','VEN_L1D_COMB_ACK'} & definitions
    modules = [source_path.with_name(name) for name in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    inputs = [source_path, parent/'build-started.json', Path(__file__).resolve(),
              Path(recipe.__file__).resolve(), Path(original.__file__).resolve(),
              HERE/'tb_l1d_mem_chain.sv', HERE/'l1_legacy_capture_cut_leaf.svh',
              REPO/'tools/build_scope.sh', REPO/'tools/verilator_serial.sh', *modules]
    assert all(sha(p) == prior['pins'][str(p)] for p in [source_path,*modules])
    pins = {str(p):sha(p) for p in inputs}
    root.mkdir()
    def save(name, value):
        with (root/name).open('x') as stream: json.dump(value, stream, indent=2)
    native_rows = []
    def run(label, command, seconds):
        command = list(map(str, command))
        started = time.monotonic()
        with (root/(label+'.log')).open('x') as stream:
            child = subprocess.run(['timeout','--kill-after=5s',str(seconds)+'s',*command],
                stdout=stream,stderr=subprocess.STDOUT,pass_fds=(9,))
        native_rows.append(dict(label=label,command=command,native_exit=child.returncode,
            actual_wait=True,seconds=time.monotonic()-started,log_sha256=sha(root/(label+'.log'))))
        return child.returncode,(root/(label+'.log')).read_text()
    save('started.json', dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
                             definitions=sorted(definitions),affinity=sorted(os.sched_getaffinity(0))))
    rows, errors = [], []
    began = time.monotonic()
    try:
        for label,special,extra,mutant in (
                ('generic',False,set(),False),('current-u',True,set(),False),
                ('current-u-lutram-two-window',True,{'VEN_L1D_TAG_LUTRAM','VEN_L1D_TWO_WINDOW_REUSE'},False),
                ('mutant-unowned',True,set(),True)):
            folder = root/label; folder.mkdir()
            changed = candidate
            if mutant:
                changed = recipe.once(changed,'PAIR_CURRENT_U_ONLY ? pair_legacy_capture :',
                    'PAIR_CURRENT_U_ONLY ? (pair_legacy_capture || (!c_req && !rd_armed)) :')
            (folder/'ven_l1d.sv').write_text(changed)
            (folder/'parent_l1d.sv').write_text(source.replace('module ven_l1d #(', 'module parent_l1d #(')
                .replace('endmodule : ven_l1d','endmodule : parent_l1d'))
            defs = sorted(definitions|extra)
            rc, pp = run(label+'-preprocess',[original.VL,'-E',*['+define+'+d for d in defs],folder/'ven_l1d.sv'],20)
            assert rc == 0
            (folder/'tb_l1d_mem_chain.sv').write_text(fixture(original.ports(pp),special))
            for path in folder.iterdir(): pins[str(path)] = sha(path)
            command = [REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv','-Wall',
                '-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in defs], '--top-module','tb_l1d_mem_chain',
                '--Mdir',folder/'obj','-j','32',*modules,folder/'parent_l1d.sv',
                folder/'ven_l1d.sv',folder/'tb_l1d_mem_chain.sv']
            rc, log = run(label+'-build',command,180)
            assert rc == 0,(label,'build',log[-3000:])
            model = folder/'obj/Vtb_l1d_mem_chain'
            rc,log = run(label+'-run',['taskset','-c','12',model],30)
            if mutant:
                assert rc != 0 and ('CURRENT-U-EMPTY-SLOT' in log or 'CUT_EQUIV' in log or 'CURRENT-U-PAIR' in log),log
            else:
                assert rc == 0 and 'CURRENT-U-MITER-OK' in log and 'L1D-MEM-CHAIN-OK accepted=150' in log,log
                assert 'checks=538 fresh=448 same_bank=64 held=1536' in log,log
            rows.append(dict(label=label,native_exit=rc,binary_sha256=sha(model),
                mutant=mutant,coverage=re.findall(r'^(?:L1.*OK|CURRENT-U-MITER-OK).*$',log,re.M)))
    except Exception as exc:
        errors.append(dict(error=repr(exc),traceback=traceback.format_exc()))
    stable = all(sha(path)==digest for path,digest in pins.items())
    save('closed.json',dict(passed=not errors and stable and len(rows)==4,errors=errors,rows=rows,
        native=native_rows,pins=pins,pins_unchanged=stable,seconds=time.monotonic()-began,
        contract_filter='c_req && !c_we && pair_req_valid == 2b10',
        unconditional_equivalence=False,whole_core=False,hardware_acceptance=False,gameplay_ipc=None))
    print(json.dumps(dict(rows=rows,errors=errors,pins_unchanged=stable)),flush=True)
    return 0 if not errors and stable and len(rows)==4 else 1


if __name__ == '__main__': raise SystemExit(main())
