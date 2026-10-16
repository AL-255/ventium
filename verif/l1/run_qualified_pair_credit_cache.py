"""Real L1/AXI sequential A/B for the opt-in pair-credit cofactor.

Two unchanged full P5 caches, two complete AXI masters and independent RAM
slaves receive identical requests. Only one master's opt-in parameter differs.
This is a directed integration test, not whole-core/FPGA acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time
import traceback

import prepare_qualified_pair_credit as recipe
import run_backing_pair_payload_axi as base
import run_parallel_tag_cache as miter

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sha = miter.sha


def fixture():
    original = (HERE/'tb_l1d_mem_chain.sv').read_text()
    original = recipe.once(original,
        'logic m_pair_req, m_pair_ready=0, m_pair_ack=0;',
        'logic m_pair_req, m_pair_ready=1, m_pair_ack;')
    original = recipe.once(original, '  ven_l1d dut(.*);',
        '''  wire c_payload_cacheable=cacheable;
  wire c_pair_intent=c_pair_req;
  logic c_pair_intent_ready, c_rdata_hi_uncontended;
  ven_l1d dut(.*);''')
    miter.BASE_OUTPUTS.update(c_pair_intent_ready=1, c_rdata_hi_uncontended=1)
    text = base.fixture(original)
    text = recipe.once(text, 'dut.dc_tag[s*2+w] !== control.dc_tag[s*2+w]',
        '(w==0 ? dut.dc_tag_way0[s] : dut.dc_tag_way1[s]) !== '
        '(w==0 ? control.dc_tag_way0[s] : control.dc_tag_way1[s])')
    anchor = '  ven_axi_master #(.ADDR_MASK'
    assert text.count(anchor) == 2
    text = text.replace(anchor,
        "  ven_axi_master #(.PAIR_REQ_CREDIT_QUALIFIED(1'b1),.ADDR_MASK", 1)
    text = recipe.once(text, '  `include "backing_pair_axi_leaf.svh"',
        '''  always @(posedge clk or negedge clk) begin
    #1;
    if(m_pair_ready !== shadow_m_pair_ready)
      $fatal(1,"PAIR-CREDIT-CACHE readiness mismatch");
  end
  `include "qualified_pair_credit_cache_leaf.svh"''')
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'proof', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    ap.add_argument('--drop-single-credit', action='store_true',
                    help='required-failing mutation, never a candidate')
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, proof, out = args.parent.resolve(strict=True), args.proof.resolve(strict=True), args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert out.is_relative_to(scratch) and not out.exists()
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    proven = json.loads((proof/'closed.json').read_text())
    assert proven['passed'] and proven['pins_unchanged'] and len(proven['rows']) == 8
    pins = dict(proven['pins'])
    for row in proven['rows']: pins.update(row['artifacts'])
    assert all(sha(path)==value for path,value in pins.items())
    mem = parent/'ventium/rtl/mem'
    originals = {name:(mem/name).read_text() for name in recipe.PINS}
    changed = recipe.transform(originals)
    assert all(changed[name] == (proof/name).read_text() for name in recipe.PINS)
    manifest = parent/'input-manifest.json'
    hardware_defines = json.loads(manifest.read_text())['hardware_defines']
    assert len(hardware_defines)==159 and hardware_defines.count('SYNTHESIS')==1
    # Keep all hardware feature defines. Remove only the synthesis-only
    # observer exclusion so the actual master/cache contract assertions run.
    defines = [flag for flag in hardware_defines if flag != 'SYNTHESIS']
    assert len(defines)==158 and 'VEN_AXI_CDC' not in defines and 'VEN_EN_L2' not in defines
    assert all(name in defines for name in ('VEN_P54_DUAL_STORE_PAIR',
        'VEN_P54_LOAD_STORE_PAIR','VEN_P54_WBUF_QUAD_COMBINE','VEN_P54_WBUF_ADMIT_DISPATCH'))
    out.mkdir()
    def save(name, value):
        with (out/name).open('x') as f: json.dump(value,f,indent=2)
    generated = {
        Path(__file__).name: Path(__file__).read_text(),
        'ven_axi_master.sv': changed['ven_axi_master.sv'],
        'control_l1d.sv': miter.control_source(originals['ven_l1d.sv']),
        'tb_l1d_mem_chain.sv': fixture(),
        # Unlike the original backing-payload A/B, these identical caches must
        # have identical idle hints too; require zero changes, not positive.
        'qualified_pair_credit_cache_leaf.svh': recipe.once(
            (HERE/'backing_pair_axi_leaf.svh').read_text(),
            'idle_credit_changes==0 || full_queue==0',
            'idle_credit_changes!=0 || full_queue==0'),
    }
    if args.drop_single_credit:
        master = generated['ven_axi_master.sv']
        begin = master.index('  generate if (PAIR_REQ_CREDIT_QUALIFIED)')
        end = master.index('  end else begin', begin)
        block = master[begin:end]
        broken = recipe.once(block,
            "((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release)", "1'b1")
        generated['ven_axi_master.sv'] = recipe.once(master, block, broken)
    for name, text in generated.items():
        with (out/name).open('x') as f: f.write(text)
    modules = [mem/name for name in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    for path in (Path(__file__).resolve(),Path(base.__file__).resolve(),Path(miter.__file__).resolve(),
                 HERE/'prepare_backing_pair_payload.py',HERE/'test_backing_pair_payload.py',
                 HERE/'prepare_parallel_tag_lookup.py',HERE/'backing_pair_axi_leaf.svh',
                 HERE/'tb_l1d_mem_chain.sv',HERE/'axi_slave_bfm.sv',manifest,
                 proof/'closed.json',*modules,*(out/name for name in generated),
                 REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh'):
        pins[str(path)] = sha(path)
    save('started.json',dict(pins=pins,defines=defines,hardware_defines=hardware_defines,
                             removed_observer_exclusion='SYNTHESIS',invocation=os.environ['INVOCATION_ID'],
                             affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False,errors=[],whole_cache=True,real_axi_master=True,
        expected_failure=args.drop_single_credit,
        wrapper_tested=False,whole_core=False,standard_suite=False,hardware_acceptance=False,
        gameplay_ipc=None,fmax_mhz=None)
    start = time.monotonic()
    try:
        command = [str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
            '-j','32','--output-split','20000','--output-split-cfuncs','2000',
            '-Wall','-Wno-UNUSED','-Wno-fatal',
            *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            '-I'+str(out),'--top-module','tb_l1d_mem_chain','--Mdir',str(out/'obj'),'-o','test',
            *['+define+'+flag for flag in defines],*map(str,modules),str(out/'ven_axi_master.sv'),
            str(HERE/'axi_slave_bfm.sv'),str(out/'control_l1d.sv'),str(mem/'ven_l1d.sv'),
            str(out/'tb_l1d_mem_chain.sv')]
        result['command'] = command
        with (out/'build.log').open('x') as f:
            native = subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,
                env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=180)
        result['build_exit'] = native.returncode
        assert native.returncode==0, 'native build failed; see build.log'
        assert shutil.disk_usage(scratch).free > 4*1024**3
        with (out/'run.log').open('x') as f:
            native = subprocess.run(['taskset','-c','8',str(out/'obj/test')],
                stdout=f,stderr=subprocess.STDOUT,timeout=40)
        result['native_exit'] = native.returncode
        log = (out/'run.log').read_text()
        if args.drop_single_credit:
            assert native.returncode in (1,-6,134) and any(marker in log for marker in
                ('PAIR-CREDIT: enqueue behavior changed','BACKING-AXI-MISMATCH',
                 'PARALLEL-CACHE-MISMATCH')), log
        else:
            assert native.returncode==0 and 'BACKING-AXI-OK' in log, log
            assert 'PARALLEL-CACHE-MITER' in log and 'MISMATCH' not in log and 'FATAL' not in log, log
        result['log'] = log
        result['artifacts'] = {str(p):sha(p) for p in (out/'obj/test',out/'build.log',out/'run.log')}
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins=pins,
                  pins_unchanged=all(sha(path)==value for path,value in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','command','artifacts')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
