"""Enumerate exact native admission equations; NOT a sequential AXI/core test.

Every queue count and binary control combination is covered, including
unreachable controls. Qualified mode compares only under its explicit caller
contract; the generic default compares without that assumption. A deliberate
uncredited pair and guard-removal mutants must fail. Generated artifacts are
exclusive, bounded, source-pinned and retained on failure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time
import traceback

import prepare_qualified_pair_credit as recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fixture(old, new, qualified, mutant):
    start = new.index('  generate if (PAIR_REQ_CREDIT_QUALIFIED)')
    stop = new.index('  end endgenerate', start)+len('  end endgenerate')
    changed = new[start:stop]
    if mutant in ('fatal', 'alias', 'credit'):
        branch, rest = changed.split('  end else begin', 1)
        before, after = {
            'fatal': ('!fatal_now &&', "1'b1 &&"),
            'alias': ('!alias_bad &&', "1'b1 &&"),
            'credit': ("((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release)", "1'b1"),
        }[mutant]
        branch = recipe.once(branch, before, after)
        changed = branch+'  end else begin'+rest
    changed = changed.replace('wr_enq ', 'new_enq ')
    old_eq = recipe.enqueue(old).replace('wr_enq ', 'old_enq ')
    # Both preprocessor arms terminate in semicolons: retain the complete
    # ready region, not merely the first arm's textual assignment.
    ready_start = old.index('  assign m_pair_ready =')
    ready = old[ready_start:old.index('  assign wr_enq      =', ready_start)]
    can_pair = recipe.assignment(old, 'wr_can_pair')
    body = f'''module tb;
  localparam integer WBUF_CNTW=2, P5_WBUF_DEPTH=2;
  localparam bit R_IDLE=0, PAIR_REQ_CREDIT_QUALIFIED={int(qualified)};
  reg [1:0] wq_count;
  reg rst, m_req, m_we, m_pair_req, shutdown, m_idle, fatal_now;
  reg alias_bad, wq_head_release, pair_quad_ok, rd_deliver;
  wire wr_can_pair, m_pair_ready, old_enq, new_enq;
  wire old_ack = !fatal_now && (rd_deliver || old_enq || (shutdown && m_idle && m_req));
  wire new_ack = !fatal_now && (rd_deliver || new_enq || (shutdown && m_idle && m_req));
  wire old_pair_ack = !fatal_now && ((old_enq && m_pair_req) ||
                        (shutdown && m_idle && m_req && m_we && m_pair_req));
  wire new_pair_ack = !fatal_now && ((new_enq && m_pair_req) ||
                        (shutdown && m_idle && m_req && m_we && m_pair_req));
  wire contract_ok = !(m_req && m_we && m_pair_req) || m_pair_ready;
{can_pair}
{ready}
{old_eq}
{changed}
  integer checked=0, excluded=0, violations=0, total=0;
  initial begin
    for(integer count=0; count<4; count=count+1)
      for(integer state_n=0; state_n<2; state_n=state_n+1)
        for(integer bits=0; bits<1024; bits=bits+1) begin
          wq_count=2'(count); rst=1'(state_n);
          {{m_req,m_we,m_pair_req,shutdown,m_idle,fatal_now,alias_bad,
            wq_head_release,pair_quad_ok,rd_deliver}}=10'(bits);
          #1; total++;
          if (contract_ok || !PAIR_REQ_CREDIT_QUALIFIED) begin
            checked++;
            if ({{new_enq,new_ack,new_pair_ack}} !== {{old_enq,old_ack,old_pair_ack}})
              $fatal(1,"PAIR-CREDIT-MISMATCH count=%0d state=%0d controls=%0d",count,state_n,bits);
          end else begin
            excluded++;
            if(new_enq !== old_enq) violations++;
          end
        end
    if(total!=8192 || checked==0) $fatal(1,"PAIR-CREDIT coverage");
'''
    if mutant == 'unqualified':
        body += '''    // Demonstrate why this optimization cannot be a generic default.
    wq_count=1; rst=R_IDLE; m_req=1; m_we=1; m_pair_req=1;
    shutdown=0; m_idle=0; fatal_now=0; alias_bad=0;
    wq_head_release=0; pair_quad_ok=0; rd_deliver=0;
    #1;
    if(contract_ok || old_enq || !new_enq || violations==0)
      $fatal(1,"negative control did not exercise the expected over-admission");
    $fatal(1,"PAIR-CREDIT-CONTRACT-REJECTED: one free slot cannot accept nonquad pair");
'''
    else:
        body += '''    if(PAIR_REQ_CREDIT_QUALIFIED && (excluded==0 || violations==0))
      $fatal(1,"PAIR-CREDIT assumption coverage");
    $display("PAIR-CREDIT-LEAF-OK total=%0d checked=%0d excluded=%0d unsafe=%0d",
             total,checked,excluded,violations);
    $finish;
'''
    return body+'  end\nendmodule\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    repo = Path(__file__).resolve().parents[2]
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != repo.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    source, out = args.source.resolve(strict=True), args.out.resolve()
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    paths = [source/name for name in recipe.PINS]
    originals = {p.name:p.read_text() for p in paths}
    changed = recipe.transform(originals)
    for name in recipe.PINS:
        drift = dict(originals, **{name: originals[name]+'\n'})
        try: recipe.transform(drift)
        except ValueError: pass
        else: raise AssertionError('source drift accepted')
    try: recipe.transform(changed)
    except ValueError: pass
    else: raise AssertionError('reapplication accepted')
    assert changed['ven_l1d.sv'] == originals['ven_l1d.sv']
    pins = {str(p):sha(p) for p in (*paths, Path(__file__).resolve(),
                                   Path(recipe.__file__).resolve())}
    out.mkdir()
    def save(name, data):
        with (out/name).open('x') as f: json.dump(data, f, indent=2)
    for name, text in changed.items():
        with (out/name).open('x') as f: f.write(text)
        pins[str(out/name)] = sha(out/name)
    for path in (Path(__file__).resolve(), Path(recipe.__file__).resolve()):
        with (out/path.name).open('x') as f: f.write(path.read_text())
        pins[str(out/path.name)] = sha(out/path.name)
    save('started.json', dict(pins=pins, pid=os.getpid(), affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, rows=[], errors=[], sequential_axi=False, whole_cache=False,
                  whole_core=False, standard_suite=False, hardware_acceptance=False,
                  gameplay_ipc=None, fmax_mhz=None)
    started = time.monotonic()
    try:
        cases = [(quad, qualified, 'positive') for quad in (False, True) for qualified in (False, True)]
        cases += [(True, True, mode) for mode in ('fatal', 'alias', 'credit', 'unqualified')]
        for quad, qualified, mode in cases:
            folder = out/f'quad{int(quad)}-qualified{int(qualified)}-{mode}'
            folder.mkdir()
            sv, binary = folder/'tb.sv', folder/'test.vvp'
            with sv.open('x') as f:
                f.write(fixture(originals['ven_axi_master.sv'], changed['ven_axi_master.sv'], qualified, mode))
            command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(binary)]
            if quad: command += ['-DVEN_P54_WBUF_QUAD_COMBINE']
            command += [str(sv)]
            row = dict(quad=quad, qualified=qualified, mode=mode, command=command)
            result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                built = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=15)
            row['build_exit'] = built.returncode
            assert built.returncode == 0, folder
            with (folder/'run.log').open('x') as f:
                native = subprocess.run(['/usr/bin/vvp', str(binary)], stdout=f, stderr=subprocess.STDOUT, timeout=20)
            log = (folder/'run.log').read_text()
            row.update(native_exit=native.returncode, log=log)
            expected = 0 if mode == 'positive' else 1
            marker = ('PAIR-CREDIT-LEAF-OK total=8192' if mode == 'positive' else
                      'PAIR-CREDIT-CONTRACT-REJECTED' if mode == 'unqualified' else 'PAIR-CREDIT-MISMATCH')
            assert native.returncode == expected and marker in log, (folder, native.returncode, log)
            artifacts = {str(p):sha(p) for p in (sv, binary, folder/'build.log', folder/'run.log')}
            row['artifacts'] = artifacts
            print(folder.name, log.strip(), flush=True)
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-started, pins=pins,
                  pins_unchanged=all(sha(p)==value for p,value in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','pins')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
