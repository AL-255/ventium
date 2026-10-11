#!/usr/bin/env python3
"""Paired-readiness proof and actual full-size cache A/B microbenchmarks.

Retain the original store/coherence fixtures and add a real primed-read
lookahead-conflict transaction. No cache state is injected. The independent
predecessor observes the same inputs; compare outputs and all cache arrays.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
import traceback

import prepare_pair_ready_cofactor as patch
import run_parallel_tag_pairs as pair
from run_parallel_tag_cache import control_source, sha


EXTRA = '''
`ifdef VEN_P54_LOAD_STORE_PAIR
    $display("[cofactor] a real primed U read rejects simultaneous next lookup/V store");
    read_word(32'h40, mem[16]);
    wait_idle();
    @(negedge clk);
    c_req <= 1'b0; c_pair_req <= 1'b0; c_we <= 1'b0;
    next_hint <= 1'b1; next_commit <= 1'b1; next_address <= 32'h40;
    #1;
    if (!dut.mc_lookup_prime || !dut.c_next_ready)
      fail("cofactor prime setup not ready");
    @(posedge clk); #1;
    if (!dut.rd_armed || dut.rd_addr_q != 32'h40)
      fail("cofactor prime did not create a real U response owner");
    @(negedge clk);
    next_commit <= 1'b0;
    c_req <= 1'b1; c_addr <= 32'h40; c_wstrb <= 4'hf;
    c_pair_req <= 1'b1; c_pair_addr <= 32'h44;
    c_pair_wstrb <= 4'hf; c_pair_wdata <= 32'h31415926;
    next_address <= 32'h64;
    #1;
    if (!dut.rd_match || !dut.mc_lookup_old || c_pair_ready || m_req || !c_ack)
      fail("next lookup did not exclude the younger store with U response intact");
    cofactor_next_conflicts++;
    // Same cycle: withdrawing the unused lookahead must restore readiness,
    // not introduce another pipeline/register bubble.
    next_hint = 1'b0;
    #1;
    if (!c_pair_ready || !c_pair_ack || !m_req || !c_ack)
      fail("withdrawing next hint did not restore same-cycle paired readiness");
    load_store_write_base = writes;
    @(posedge clk);
    @(negedge clk); c_req <= 1'b0; c_pair_req <= 1'b0;
    if (writes != load_store_write_base + 1 || mem[17] != 32'h31415926)
      fail("cofactor V store was missing or duplicated");
    read_word(32'h44, 32'h31415926);
    if (cofactor_next_conflicts != 1) fail("missing next conflict coverage");
    $display("PAIR-READY-NEXT-CONFLICT-OK cases=%0d",cofactor_next_conflicts);
`endif
'''


def fixture(source, flat):
    result = pair.fixture(source, flat)
    result = result.replace('.c_next_req(c_we), .c_next_commit(1\'b1)',
                            '.c_next_req(c_we || next_hint), .c_next_commit(next_commit)')
    result = result.replace(".c_next_addr(c_addr ^ 32'h12345020)",
                            ".c_next_addr(next_hint ? next_address : (c_addr ^ 32'h12345020))")
    anchor = '  logic clk = 1\'b0, rst_n = 1\'b0;'
    assert result.count(anchor) == 1
    result = result.replace(anchor, anchor+'''
  logic next_hint=0, next_commit=0;
  logic [31:0] next_address=0;
  integer cofactor_next_conflicts=0;
''')
    anchor = '    if (errors == 0) $display("L1D-PAIR-STORE-GATE-OK");'
    assert result.count(anchor) == 1
    result = result.replace(anchor, EXTRA+anchor)
    # The historical fixture prints FAIL then calls $finish (native exit 0).
    # Preserve every check, but make its accumulated error count authoritative
    # for both real defects and mutation tests, including sub-cycle checks.
    anchor = '    $finish;'
    assert result.count(anchor) == 1
    return result.replace(anchor, '    if (errors != 0) $fatal(1,"PAIR-READY-COFACTOR-GATE-FAIL");\n'+anchor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    root, parent = args.out.resolve(), args.parent.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != repo.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    subprocess.run([repo/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    source = parent.read_text()
    candidate = patch.transform(source)
    root.mkdir()
    (root/'ven_l1d.sv').write_text(candidate)
    (root/'control_l1d.sv').write_text(control_source(source))
    pins = {str(p):sha(p) for p in (parent, Path(__file__), Path(patch.__file__),
        Path(pair.__file__), Path(__file__).with_name('run_parallel_tag_cache.py'),
        Path(__file__).with_name('tb_l1d_pair_store.sv'),
        Path(__file__).with_name('test_pair_ready_cofactor.py'),
        root/'ven_l1d.sv', root/'control_l1d.sv')}
    def save(name, value):
        with (root/name).open('x') as f:
            json.dump(value, f, indent=2)
    started = time.monotonic()
    result = dict(passed=False, rows=[], errors=[], whole_core=False,
                  gameplay_ipc=None, standard_suite=False, fmax_mhz=None)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
                             affinity=sorted(os.sched_getaffinity(0))))
    try:
        env = dict(os.environ, PAIR_READY_PARENT=str(parent),
                   PAIR_READY_PROOF_OUT=str(root/'symbolic'))
        command = ['/usr/bin/python3', '-B', str(Path(__file__).with_name('test_pair_ready_cofactor.py'))]
        with (root/'proof.log').open('x') as f:
            proof = subprocess.run(command, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=120)
        result['proof_exit'] = proof.returncode
        assert proof.returncode == 0
        result['proof_log_sha256'] = sha(root/'proof.log')
        # Different physical tag organizations and 0/1/2 saved read windows.
        for mutant, flat, windows in [(False,f,w) for f in (False,True) for w in range(3)] + [(True,True,2)]:
            label = f'{"wrong" if mutant else "positive"}-lut{int(flat)}-windows{windows}'
            folder = root/label
            folder.mkdir()
            sv = candidate
            if mutant:
                sv = sv.replace('&& !(c_next_req && rd_match)', "&& 1'b1")
            (folder/'ven_l1d.sv').write_text(sv)
            tb = folder/'tb_l1d_pair_store.sv'
            tb.write_text(fixture(Path(__file__).with_name(tb.name).read_text(), flat))
            pins.update({str(p):sha(p) for p in (folder/'ven_l1d.sv', tb)})
            flags = pair.FLAGS + (['VEN_L1D_TAG_LUTRAM'] if flat else [])
            if windows:
                flags += ['VEN_L1D_WINDOW_REUSE', 'VEN_L1D_WINDOW_KEEP_STORE']
            if windows == 2:
                flags += ['VEN_L1D_TWO_WINDOW_REUSE', 'VEN_L1D_TWO_WINDOW_KEEP_STORE']
            command = [str(repo/'tools/verilator_serial.sh'), '--binary', '--assert', '-sv',
                '--top-module', 'tb_l1d_pair_store', '--Mdir', str(folder/'obj'), '-j','32',
                '--output-split','20000','--output-split-cfuncs','2000',
                '-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in flags], str(root/'control_l1d.sv'),
                str(folder/'ven_l1d.sv'), str(tb)]
            row = dict(label=label, command=command, mutant=mutant, definitions=flags)
            result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                child = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT,
                    env=dict(os.environ, CCACHE_DISABLE='1'), pass_fds=(9,), timeout=180)
            row['build_exit'] = child.returncode
            assert child.returncode == 0, label
            binary = folder/'obj/Vtb_l1d_pair_store'
            with (folder/'run.log').open('x') as f:
                child = subprocess.run([binary], stdout=f, stderr=subprocess.STDOUT, timeout=30)
            row.update(native_exit=child.returncode, binary_sha256=sha(binary),
                log_sha256=sha(folder/'run.log'), build_log_sha256=sha(folder/'build.log'))
            log = (folder/'run.log').read_text()
            if mutant:
                assert child.returncode != 0 and ('MISMATCH' in log or 'PAIR-READY-COFACTOR' in log), label
            else:
                assert child.returncode == 0 and 'L1D-PAIR-STORE-GATE-OK' in log, label
                assert not re.search(r'FAIL|%Error|%Fatal|MISMATCH', log), label
                assert 'PAIR-READY-NEXT-CONFLICT-OK cases=1' in log, label
                counts = re.findall(r'PARALLEL-PAIR-MITER checks=(\d+) pairs=(\d+) rejected_store_hints=(\d+)', log)
                assert len(counts) == 1 and all(int(v) > 10 for v in counts[0])
                row.update(zip(('samples','pairs','rejected_store_hints'),map(int,counts[0])))
            save(label+'/closed.json', row)
            print(json.dumps({k:v for k,v in row.items() if k!='command'}), flush=True)
        result['passed'] = True
    except BaseException as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins=pins, pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  seconds=time.monotonic()-started)
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
