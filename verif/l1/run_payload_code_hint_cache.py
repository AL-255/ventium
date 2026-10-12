#!/usr/bin/env python3
"""Prepare/run a real-cache regression without touching the active FPGA input.

Preparation is light. Execution requires the exclusive guarded-32 build scope
and refuses a live Vivado. Reuse the public-traffic backing-memory oracle; add
upstream-qualified code vs downstream-denied requests and idle hint changes.
This does not qualify the core, AXI wrapper, timing, or standard suite.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
import traceback

import prepare_payload_code_hint as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
MODEL = 'eefa9d57c41c5eb5154d0319fb2e82240f90469b7ce119ae0abe36d6aada9702'
HELPERS = ('code_payload_leaf.svh', 'high_window_payload_leaf.svh',
           'response_payload_leaf.svh', 'window_write_update_leaf.svh',
           'store_window_warm_leaf.svh')
MARKERS = ('L1D-MEM-CHAIN-OK accepted=150', 'WINDOW-WRITE-UPDATE-OK',
           'STORE-WARM-OK', 'RESPONSE-PAYLOAD-OK', 'HIGH-WINDOW-PAYLOAD-OK',
           'CODE-PAYLOAD-OK', 'PAYLOAD-HINT-DENIED-OK cases=32 idle=32')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def stable(pins):
    return all(sha(path) == digest for path, digest in pins.items())


INTERFACE = '''  // c_req and c_code below represent upstream request and kind.
  // Keep upstream code qualification distinct from the wrapper's later denial.
  logic [2:0] hint_deny=0;
  wire admitted_req = c_req && !(|hint_deny);
  wire qualified_code = c_req && c_code;
  logic c_read_ack;
`ifdef VEN_L1D_PAYLOAD_CODE_HINT
  wire c_payload_code = c_code ^ $test$plusargs("BAD_HINT");
  ven_l1d dut(.c_req(admitted_req), .c_code(qualified_code), .*);
`else
  ven_l1d dut(.c_req(admitted_req), .c_code(qualified_code), .*);
`endif'''

DENIED = '''
  int hint_denied_cases=0, hint_idle_cases=0;
  task automatic run_payload_hint_denied;
    int old_backing;
    // Cover idle code hints and each wrapper denial, then demand the same
    // owner. No DUT deposits, forced hits, or address/ACK overrides.
    for (int kind=0;kind<2;kind++)
      for (int deny=1;deny<9;deny++)
        for (int resident=0;resident<2;resident++) begin
          iw_reset();
          if (resident) cp_read('h6200,1'(kind),4'hf,1);
          old_backing=backing;
          @(negedge clk); c_code=1'(kind); c_req=0; c_addr='h6200;
          c_wstrb=4'hf;
          repeat (3) begin
            @(posedge clk);
            if(c_ack || c_read_ack || m_req || m_pair_req)
              $fatal(1,"PAYLOAD-HINT-IDLE side effect");
            @(negedge clk);
          end
          hint_idle_cases++;
          // deny=8 duplicates all-denied to retain a power-of-two case count.
          hint_deny=deny==8 ? 3'b111 : 3'(deny); c_req=1;
          repeat (3) begin
            @(posedge clk);
            if(c_ack || c_read_ack || m_req || m_pair_req || backing!=old_backing)
              $fatal(1,"PAYLOAD-HINT-DENIED side effect kind=%0d deny=%0d",kind,deny);
            @(negedge clk);
          end
          c_req=0; hint_deny=0; hint_denied_cases++;
          cp_read('h6200,1'(kind),4'hf,1);
        end
    iw_reset();
    if(hint_denied_cases!=32 || hint_idle_cases!=32)
      $fatal(1,"PAYLOAD-HINT-DENIED missing coverage");
    $display("PAYLOAD-HINT-DENIED-OK cases=%0d idle=%0d",hint_denied_cases,hint_idle_cases);
  endtask
'''


def adapt_fixture(text):
    text = recipe.replace(text, '  ven_l1d dut(.*);', INTERFACE)
    text = recipe.replace(text, '    run_code_payload();\n    $finish;',
                          '    run_code_payload();\n    run_payload_hint_denied();\n    $finish;')
    # Retain the original all-clock trace; append missing public owner/extent
    # fields so equality cannot hide a changed response address or narrow size.
    extra = '''
    $fdisplay(observations,"hint %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
      admitted_req, qualified_code, c_read_ack, c_we, c_addr, c_wstrb,
      pair_rsp_owner, pair_rsp_paddr, m_rd_narrow, m_rd_size,
      m_pair_req ? m_pair_addr : 32'd0, m_pair_req ? m_pair_wstrb : 4'd0,
      pair_now_valid, pair_now_valid ? pair_now_data : 32'd0, hint_deny);'''
    # One observer process fixes record ordering independently of elaborator
    # scheduling of the control and candidate designs.
    anchor = "      m_pair_req, m_pair_req ? m_pair_wdata : 32'd0);"
    text = recipe.replace(text, anchor, anchor+extra)
    return recipe.replace(text, 'endmodule', DENIED+'endmodule')


def prepare(args, root):
    assert not root.exists()
    parent, fixture, leaf = [getattr(args, key).resolve(strict=True)
                             for key in ('parent', 'fixture', 'leaf')]
    before, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    checked, started = load(leaf/'closed.json'), load(leaf/'started.json')
    assert checked['passed'] and checked['pins_unchanged'] and stable(started['pins'])
    assert [(row['name'], row['native_exit']) for row in checked['rows']] == [
        ('positive', 0), ('wrong_kind', 1), ('early_wrong_owner', 1), ('raw_hint_control', 1)]
    assert 'PAYLOAD-HINT-OK clocks=262144 reads=2048 ' in checked['rows'][0]['log']
    pins = dict(started['pins'])
    for row in checked['rows']:
        for suffix, field in (('.sv', 'source_sha256'), ('.vvp', 'binary_sha256')):
            path = leaf/(row['name']+suffix)
            assert sha(path) == row[field]
            pins[str(path)] = row[field]
        path = leaf/(row['name']+'.log')
        assert path.read_text() == row['log']
        pins[str(path)] = sha(path)
    prior, prior_start = load(fixture/'closed.json'), load(fixture/'started.json')
    assert prior['passed'] and prior['pins_unchanged'] and prior['all_clock_interface_observations_identical']
    assert stable(prior_start['pins'])
    pins.update(prior_start['pins'])
    for row in prior['variants'][:3]:
        assert row['build_exit'] == row['native_exit'] == 0
        path = fixture/row['name']/'cycles.txt.gz'
        with gzip.open(path, 'rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == row['cycles_sha256']
        pins[str(path)] = sha(path)
    assert len({row['cycles_sha256'] for row in prior['variants'][:3]}) == 1
    originals = {name: (parent/'candidate'/name).read_text() for name in recipe.HASHES}
    changed = recipe.transform(originals)
    for name, text in changed.items():
        assert text == (leaf/'candidate'/name).read_text()
    flags = next(arg for arg in before['command'] if arg.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)', flags)
    assert len(definitions) == len(set(definitions)) == 150 and '--assert' in flags
    assert not {'SYNTHESIS', 'VEN_L1D_HIT_STREAM', 'VEN_L1D_COMB_ACK', recipe.FLAG} & set(definitions)
    assert {'VEN_FP_LOAD_EARLY_CMD', 'VEN_FP_LOAD64', 'VEN_L1D_CODE_BUFFER',
            'VEN_L1D_CODE_PAYLOAD_SELECT', 'VEN_L1D_RESPONSE_PAYLOAD_SELECT',
            'VEN_P54_DUAL_BYTE_LOAD_PAIR', 'VEN_RAW_V_READ_PRIME'} <= set(definitions)
    modules = [parent/'candidate/rtl/mem'/name for name in ('ven_p54_bank_arb.sv', 'ven_p54_hit_return.sv')]
    for path in modules:
        assert before['pins'][str(path)] == sha(path)
    files = [Path(__file__), Path(recipe.__file__), parent/'build-started.json', parent/'build-closed.json',
             parent/'obj/tb_ventium', leaf/'closed.json', leaf/'started.json',
             fixture/'closed.json', fixture/'started.json', fixture/'tb_l1d_mem_chain.sv',
             REPO/'tools/build_scope.sh', Path('/tools/verilator/v5.046/bin/verilator'), *modules]
    pins.update({str(path): sha(path) for path in files})
    assert stable(pins)
    root.mkdir()
    fixture_text = adapt_fixture((fixture/'tb_l1d_mem_chain.sv').read_text())
    (root/'tb_l1d_mem_chain.sv').write_text(fixture_text)
    for name in HELPERS:
        source = HERE/name
        assert str(source) in prior_start['pins'] and sha(source) == prior_start['pins'][str(source)]
        shutil.copyfile(source, root/name)
    for name, text in (('control.sv', originals['rtl/mem/ven_l1d.sv']),
                       ('candidate.sv', changed['rtl/mem/ven_l1d.sv'])):
        (root/name).write_text(text)
    pins.update({str(path): sha(path) for path in root.iterdir() if path.is_file()})
    save(root/'prepared.json', dict(pins=pins, definitions=definitions, parent=str(parent),
        parent_model=MODEL, modules=list(map(str, modules)), compiler_started=False,
        whole_core_verified=False, timing_verified=False, standard_suite=False, gameplay_ipc=None))
    print('PAYLOAD-HINT-CACHE-PREPARED: no compiler launched', flush=True)


def run(root):
    before = load(root/'prepared.json')
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    assert stable(before['pins']) and not (root/'started.json').exists()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    save(root/'started.json', dict(before, compiler_started=True, invocation=os.environ['INVOCATION_ID'],
                                  affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, variants=[], errors=[], whole_core_verified=False,
                  timing_verified=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    began = time.monotonic()
    try:
        for name, source, enabled in (('control', 'control.sv', False),
                                     ('off', 'candidate.sv', False), ('on', 'candidate.sv', True)):
            folder = root/name
            folder.mkdir()
            command = ['/tools/verilator/v5.046/bin/verilator', '--binary', '--timing', '-sv',
                '--assert', '-j', '32', '-Wno-fatal', '-Wno-UNUSED',
                *['-Werror-'+warning for warning in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                '-I'+str(root), '--top-module', 'tb_l1d_mem_chain', '--Mdir', str(folder/'obj'), '-o', 'test',
                *['+define+'+flag for flag in before['definitions']],
                *(['+define+'+recipe.FLAG] if enabled else []), *before['modules'],
                str(root/source), str(root/'tb_l1d_mem_chain.sv')]
            save(folder/'command.json', command)
            with (folder/'build.log').open('x') as stream:
                built = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, pass_fds=(9,),
                                       env=dict(os.environ, CCACHE_DISABLE='1'), timeout=120)
            row = dict(name=name, build_exit=built.returncode)
            result['variants'].append(row)
            assert built.returncode == 0, row
            binary = folder/'obj/test'
            for label, plusargs in [('positive', [])]+([('negative', ['+BAD_HINT'])] if enabled else []):
                log, obs = folder/(label+'.log'), folder/(label+'.cycles.txt')
                native_command = ['taskset', '-c', '14', str(binary), '+OBS='+str(obs), *plusargs]
                save(folder/(label+'.command.json'), native_command)
                with log.open('x') as stream:
                    native = subprocess.run(native_command, stdout=stream, stderr=subprocess.STDOUT, timeout=30)
                text = log.read_text()
                row[label+'_exit'] = native.returncode
                if label == 'positive':
                    assert native.returncode == 0 and all(marker in text for marker in MARKERS), (row, text)
                    row['coverage'] = [line for line in text.splitlines() if '-OK' in line]
                    row['cycles_sha256'] = sha(obs)
                else:
                    assert native.returncode in (1, -6, 134) and re.search(
                        r'PAYLOAD-CODE-HINT|L1 primary payload cut changed an acknowledged read|old-response owner/data changed', text), (row, text)
                with obs.open('rb') as stream, gzip.open(str(obs)+'.gz', 'xb', compresslevel=3) as packed:
                    shutil.copyfileobj(stream, packed)
                with gzip.open(str(obs)+'.gz', 'rb') as stream:
                    assert hashlib.file_digest(stream, 'sha256').hexdigest() == sha(obs)
                obs.unlink()  # Only the byte-verified lossless duplicate is removed.
                row[label+'_log_sha256'] = sha(log)
                row[label+'_observations_gz_sha256'] = sha(str(obs)+'.gz')
            row['binary_sha256'] = sha(binary)
            print(json.dumps(row), flush=True)
        assert len({row['cycles_sha256'] for row in result['variants']}) == 1
        result.update(passed=True, all_clock_interface_observations_identical=True)
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-began, pins_unchanged=stable(before['pins']))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'run'))
    parser.add_argument('--out', type=Path, required=True)
    for name in ('parent', 'fixture', 'leaf'):
        parser.add_argument('--'+name, type=Path)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.fixture and args.leaf
        prepare(args, root)
        return 0
    return run(root)


if __name__ == '__main__':
    raise SystemExit(main())
