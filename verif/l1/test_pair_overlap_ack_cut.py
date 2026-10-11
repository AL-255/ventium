#!/usr/bin/env python3
"""Bounded proof of the guarded ACK cut, not whole-cache qualification.

Z3 checks all binary predicate values. Icarus executes source-extracted ACK,
overlap and lookup logic, including mutation controls. No Verilator/Vivado
build is started; the small proof can run beside the existing synthesis.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time

import prepare_pair_overlap_ack_cut as patch


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def formal(mutant=None):
    flags = ('req we rd cache idle armed next early stream flush snoop golden '
             'legacy prime store comb dual stream_feature bypass other_read '
             'byp_ack write_ack stream_ack').split()
    text = '(set-logic QF_BV)\n'
    for name in flags:
        text += f'(declare-const {name} Bool)\n'
    text += '(declare-const lanes (_ BitVec 2))\n'
    terms = {
        'ack_read': '(or other_read byp_ack (and rd (not flush) (not snoop) '
                    '(or (not bypass) cache)))',
        'ack': '(ite (and stream_feature stream) stream_ack '
               '(and req (ite we write_ack ack_read)))',
        'owned': '(and (not comb) req (not we) rd cache '
                 '(or (not dual) (not (= lanes #b10))))',
        'old_overlap': '(and owned ack)',
        'common': '(and (not (= lanes #b00)) idle (not early) (not stream) '
                  '(not flush) (not snoop) (not golden))',
        'other': '(or (and (not req) (not armed) (not next)) legacy prime store)',
        'old': '(and common (or other (and old_overlap (not next))))',
        'new_owned': '(and (not comb) req (not we) rd cache '
                     '(or (not dual) (not (= lanes #b10))))',
        'new_common': 'common',
        'new': '(and new_common (or other (and new_owned (not next))))',
    }
    if mutant == 'orphan-v':
        terms['new_owned'] = '(and (not comb) req (not we) rd cache)'
    elif mutant == 'unowned-read':
        terms['new_owned'] = terms['new_owned'].replace(' rd ', ' ')
    elif mutant == 'snoop':
        terms['new_common'] = terms['common'].replace('(not snoop)', 'true')
    for name, body in terms.items():
        text += f'(define-fun {name} () Bool {body})\n'
    return text + '(assert (not (= old new)))\n(check-sat)\n'


def fixture(source, mutant=None):
    # Keep the actual registered ACK branches, including store, bypass and
    # stream overrides. Unrelated data selection is not part of this proof.
    ack_start = source.rindex("    c_ack   = 1'b0;\n")
    ack_end = source.index('  end\n\n`ifndef SYNTHESIS\n`ifndef VEN_L1D_COMB_ACK', ack_start)
    ack = source[ack_start:ack_end]
    boundary = '`endif\n`ifdef VEN_L1D_HIT_STREAM'
    if ack.count(boundary) != 1:
        raise ValueError('registered response branch boundary drift')
    ack = ack.replace(boundary, '`ifdef VEN_L1D_HIT_STREAM')
    data_line = "      c_rdata = rd_window_q[{1'b0,rd_addr_q[4:0],3'b000} +: 32];\n"
    if ack.count(data_line) != 1:
        raise ValueError('stream response data anchor drift')
    ack = ack.replace(data_line, '')
    overlap = source[source.index(patch.OVERLAP_START):source.index(patch.OVERLAP_END)]
    original = patch.extract_lookup(source)
    changed = patch.extract_lookup(patch.transform(source))
    owned = patch.OWNED
    if mutant == 'orphan-v':
        owned = owned.replace("&& (pair_req_valid != 2'b10)", "&& 1'b1")
    elif mutant == 'unowned-read':
        owned = owned.replace('&& rd_match', '')
    elif mutant == 'snoop':
        changed = changed.replace('!snoop_inv_valid', "1'b1")
    prefix = '''`timescale 1ns/1ps
module tb;
  localparam L1_IDLE=0, L1_FILL=1, L1_BYP=2;
`ifdef TEST_BYPASS
  localparam BYPASS_RD_EN=1;
`else
  localparam BYPASS_RD_EN=0;
`endif
  logic c_req, c_we, rd_match, cacheable, rd_armed, mc_lookup_next;
  logic early_armed, stream_path, flush_all, snoop_inv_valid, golden;
  logic pair_legacy_capture, pair_prime_capture, pair_store_read_capture;
  logic window_reuse, shadow_reuse, code_word_reuse, early_match, byp_match;
  logic m_ack, m_pair_ack, c_pair_req, c_pair_ready;
  logic c_hit_stream, c_rsp_valid, c_rsp_ready, c_ack;
  logic [1:0] pair_req_valid, st;
  logic pair_legacy_overlap, old_lookup, new_lookup;
  integer checks=0, overlap_checks=0;
  logic [63:0] rng=64'h6f9ac31d95b20e47;
  always_comb begin
'''
    middle = ('  end\n' + overlap + owned +
              original.replace('pair_lookup_active =', 'old_lookup =') +
              changed.replace('pair_lookup_active =', 'new_lookup ='))
    suffix = '''
  task automatic check;
    #1;
    if (old_lookup !== new_lookup)
      $fatal(1,"PAIR-OVERLAP-MISMATCH case=%0d lanes=%b req=%b we=%b rd=%b flush=%b snoop=%b old=%b new=%b",
             checks,pair_req_valid,c_req,c_we,rd_match,flush_all,snoop_inv_valid,old_lookup,new_lookup);
    checks++;
    if (old_lookup && pair_legacy_overlap) overlap_checks++;
  endtask
  task automatic set_bits(input logic [31:0] bits);
    {st,pair_req_valid,c_req,c_we,rd_match,cacheable,rd_armed,mc_lookup_next,
     early_armed,stream_path,flush_all,snoop_inv_valid,golden,
     pair_legacy_capture,pair_prime_capture,pair_store_read_capture,
     window_reuse,shadow_reuse,code_word_reuse,early_match,byp_match,
     m_ack,m_pair_ack,c_pair_req,c_pair_ready,c_hit_stream,c_rsp_valid,c_rsp_ready}
       = bits[29:0];
  endtask
  initial begin
    // Directed owned/unowned, cancellation, orphan-V, all ACK-store inputs.
    for (integer i=0; i<256; i++) begin
      set_bits(0);
      st=L1_IDLE; c_req=1; c_we=0; cacheable=1;
      {pair_req_valid,rd_match,flush_all,snoop_inv_valid,m_ack,m_pair_ack,c_pair_req}=8'(i);
      c_pair_ready=1;
      check();
    end
    // Deterministic broad combinations; symbolic proof supplies exhaustiveness.
    for (integer i=0; i<65536; i++) begin
      rng=rng^(rng<<13); rng=rng^(rng>>7); rng=rng^(rng<<17);
      set_bits(rng[31:0]);
      check();
    end
`ifndef VEN_L1D_COMB_ACK
    if (!overlap_checks) $fatal(1,"no owned-overlap coverage");
`endif
    $display("PAIR-OVERLAP-LEAF-OK samples=%0d overlaps=%0d",checks,overlap_checks);
    $finish;
  end
endmodule
'''
    return prefix + ack + middle + suffix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    repo = Path(__file__).resolve().parents[2]
    if (root == scratch or not root.is_relative_to(scratch) or root.exists() or
            Path(os.environ['TMPDIR']).resolve() != scratch or
            scratch.stat().st_dev == repo.stat().st_dev or
            shutil.disk_usage(scratch).free < 5*1024**3):
        raise ValueError('fresh mounted external output and disk reserve required')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    source = args.parent.read_text()
    candidate = patch.transform(source)
    original = patch.extract_lookup(source)
    replacement = (patch.OWNED + original.replace('pair_legacy_overlap', 'pair_legacy_bank_owned')
                   + patch.witness(original))
    assert candidate.replace(replacement, original) == source
    for bad in (source+'\n', candidate, source.replace('!snoop_inv_valid', "1'b1", 1)):
        try:
            patch.transform(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('accepted source drift')
    root.mkdir()
    pins = {str(p.resolve()):sha(p) for p in
            (args.parent, Path(__file__), Path(patch.__file__),
             Path('/usr/bin/iverilog'), Path('/usr/bin/vvp'), Path('/usr/bin/z3'))}
    result = dict(passed=False, candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest(),
                  native_rows=[], symbolic=[], pins=pins, whole_cache=False,
                  whole_core=False, gameplay_ipc=None, fmax_mhz=None, standard_suite=False)
    started = time.monotonic()
    def save(name, value):
        with (root/name).open('x') as f:
            json.dump(value, f, indent=2)
    save('started.json', dict(pins=pins, affinity=sorted(os.sched_getaffinity(0)),
                             invocation=os.environ.get('INVOCATION_ID')))
    (root/'ven_l1d.sv').write_text(candidate)
    try:
        for mutant in (None, 'orphan-v', 'unowned-read', 'snoop'):
            label = mutant or 'equivalent'
            problem = formal(mutant)
            (root/(label+'.smt2')).write_text(problem)
            child = subprocess.run(['/usr/bin/z3', '-in', '-smt2'], input=problem,
                                   text=True, capture_output=True, timeout=15)
            (root/(label+'.proof.log')).write_text(child.stdout+child.stderr)
            expected = 'sat' if mutant else 'unsat'
            assert child.returncode == 0 and child.stdout.strip() == expected, label
            result['symbolic'].append(dict(label=label, result=expected))
        # Registered profiles vary the actual compile-time response features.
        profiles = []
        for dual, stream, code, bypass in itertools.product((0,1), repeat=4):
            defs = ['VEN_P54_DUAL_STORE_PAIR']
            defs += [d for v,d in ((dual,'VEN_P54_DUAL_LOAD_PAIR'),
                     (stream,'VEN_L1D_HIT_STREAM'),(code,'VEN_L1D_CODE_WORD_REUSE'),
                     (bypass,'TEST_BYPASS')) if v]
            profiles.append((f'reg-{dual}{stream}{code}{bypass}',defs,None))
        profiles += [('comb-disabled', ['VEN_L1D_COMB_ACK','VEN_P54_DUAL_LOAD_PAIR'],None)]
        profiles += [(m,['VEN_P54_DUAL_LOAD_PAIR','VEN_P54_DUAL_STORE_PAIR',
                         'VEN_L1D_HIT_STREAM','VEN_L1D_CODE_WORD_REUSE','TEST_BYPASS'],m)
                     for m in ('orphan-v','unowned-read','snoop')]
        for label, defs, mutant in profiles:
            folder=root/label
            folder.mkdir()
            tb=folder/'tb.sv'
            tb.write_text(fixture(source, mutant))
            command=['/usr/bin/iverilog','-g2012','-s','tb',
                     *['-D'+d for d in defs],'-o',str(folder/'a.out'),str(tb)]
            with (folder/'build.log').open('x') as log:
                child=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=15)
            assert child.returncode == 0, label
            with (folder/'run.log').open('x') as log:
                child=subprocess.run(['/usr/bin/vvp',str(folder/'a.out')],stdout=log,
                                     stderr=subprocess.STDOUT,timeout=30)
            log=(folder/'run.log').read_text()
            if mutant:
                assert child.returncode != 0 and 'PAIR-OVERLAP-MISMATCH' in log, label
            else:
                assert child.returncode == 0 and 'PAIR-OVERLAP-LEAF-OK samples=65792' in log, label
            row=dict(label=label,defs=defs,mutant=mutant,native_exit=child.returncode,
                     log=log.strip(),tb_sha256=sha(tb),binary_sha256=sha(folder/'a.out'))
            result['native_rows'].append(row)
            print(json.dumps(row),flush=True)
        result['passed']=True
    finally:
        result.update(seconds=time.monotonic()-started,
                      pins_unchanged=all(sha(p)==h for p,h in pins.items()))
        result['passed'] &= result['pins_unchanged']
        save('closed.json', result)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
