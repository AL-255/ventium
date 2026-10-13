"""Source-extracted FP contextual-valid miter, with fail-closed scope checks.

The leaf deliberately over-approximates cache state. It assumes next-request
state exclusion only at the consumer; prove that separate obligation before
whole-core integration. No sequential core or hardware acceptance is claimed.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import subprocess
import time
import traceback

import prepare_fp_wide_context as recipe
from test_fp_high_valid_cofactor import renamed, sha

HERE = Path(__file__).resolve().parent
PROFILES = {
    'paired': ['VEN_PIPE_MEM_CHAIN', 'VEN_P54_DUAL_STORE_PAIR'],
    'unpaired': ['VEN_PIPE_MEM_CHAIN'],
    'no-chain': [],
}
COMMON = ['VEN_FP_LOAD_EARLY_CMD', 'VEN_PIPE_REG_LOAD_PRIME',
          'VEN_L1D_PRIME_UNDER_FILL', 'VEN_L1D_CODE_BUFFER',
          'VEN_L1D_WINDOW_REUSE', 'VEN_L1D_TWO_WINDOW_REUSE',
          'VEN_L1D_CODE_WORD_REUSE', 'VEN_L1D_HIT_STREAM', 'VEN_FP_SCALAR_LOAD_CMD']
MUTANTS = ('lost-residency', 'lost-owner', 'wrong-extent', 'lost-state',
           'lost-page-extent', 'narrow-without-ack', 'lost-route-deny')


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('wide-context leaf anchor drift: '+old[:100])
    return text.replace(old, new)


def source_scope(inputs):
    recipe.validate_sources(inputs)
    changed = {p: recipe.transform(inputs[p], p) for p in recipe.PARENTS}
    for path, new in changed.items():
        for bad in (inputs[path]+'\n', new):
            try:
                recipe.transform(bad, path)
            except ValueError:
                pass
            else:
                raise AssertionError('accepted source drift/reapplication: '+path)
    # Ordinary grants and command guards are byte-for-byte preserved.
    for path, names in (
        ('rtl/mem/ven_l1d.sv', ('c_rdata_hi_valid', 'fp_high_current_hit',
                              'fp_high_window_owned')),
        ('rtl/mem/ventium_l1_axi.sv', ('core_rdata_hi_valid', 'l1d_c_req', 'core_read_ack')),
        ('rtl/core/core.sv', ('fp_shared_load_cmd', 'fp_load64_take_before_high_valid_cut')),
    ):
        for name in names:
            if name == 'fp_high_current_hit':
                # This signal has one assignment per mutually exclusive profile.
                old = re.findall(r'^  assign '+name+r'\s*=.*?;\n', inputs[path], re.M | re.S)
                new = re.findall(r'^  assign '+name+r'\s*=.*?;\n', changed[path], re.M | re.S)
                assert old == new and len(old) == 2
            else:
                assert recipe.assignment(inputs[path], name) == recipe.assignment(changed[path], name)
    l1 = recipe.assignment(changed['rtl/mem/ven_l1d.sv'], 'c_rdata_hi_uncontended')
    assert 'c_next_req' not in l1 and 'c_pair_intent' not in l1
    assert l1 == recipe.assignment(inputs['rtl/mem/ven_l1d.sv'], 'c_rdata_hi_valid').replace(
        'c_rdata_hi_valid', 'c_rdata_hi_uncontended').replace(recipe.ARBITRATION, '')
    take = recipe.assignment(changed['rtl/core/core.sv'], 'fp_load64_take')
    assert take == recipe.assignment(inputs['rtl/core/core.sv'], 'fp_load64_take').replace(
        'bus_rdata_hi_valid', 'bus_rdata_hi_uncontended')
    return changed


def fixture(inputs, mutant=None):
    changed = source_scope(inputs)
    l1, seam, core = (inputs['rtl/'+p] for p in
                     ('mem/ven_l1d.sv', 'mem/ventium_l1_axi.sv', 'core/core.sv'))
    body = '  assign c_req = l1d_c_req;\n'
    body += recipe.assignment(l1, 'rd_match')
    body += '`ifdef VEN_PIPE_MEM_CHAIN\n'
    for name in ('mc_lookup_old', 'mc_lookup_prime', 'mc_lookup_next'):
        body += recipe.assignment(l1, name)
    body += "`else\n  assign mc_lookup_old=0, mc_lookup_prime=0, mc_lookup_next=0;\n`endif\n"
    body += '  assign hit = mc_lookup_next ? |tag_prime_hit : |tag_current_hit;\n'
    for name in ('window_reuse', 'shadow_reuse', 'fp_high_window_owned',
                 'read_ack_window_reuse', 'read_ack_shadow_reuse', 'read_ack_code_reuse'):
        body += recipe.assignment(l1, name)
    for name in ('fp_high_current_hit', 'read_ack_current_hit'):
        assignments = re.findall(r'^  assign '+name+r'\s*=.*?;\n', l1, re.M | re.S)
        assert len(assignments) == 2
        body += '`ifdef VEN_PIPE_MEM_CHAIN\n'+assignments[0]+'`else\n'+assignments[1]+'`endif\n'
    ack = re.findall(r'  always_comb begin\n    c_read_ack = .*?\n  end\n', l1, re.S)
    assert len(ack) == 1
    body += ack[0]
    body += renamed(recipe.assignment(l1, 'c_rdata_hi_valid'), {'c_rdata_hi_valid': 'old_hi'})
    wide = recipe.assignment(changed['rtl/mem/ven_l1d.sv'], 'c_rdata_hi_uncontended')
    mutations = {
        'lost-residency': (' && fp_high_current_hit', ''),
        'lost-owner': (' && fp_high_window_owned', ''),
        'wrong-extent': ("c_addr[4:0] <= 5'd24", "c_addr[4:0] <= 5'd28"),
    }
    if mutant in mutations:
        wide = once(wide, *mutations[mutant])
    body += renamed(wide, {'c_rdata_hi_uncontended': 'new_hi'})
    for name in ('l1d_c_req', 'core_read_ack'):
        body += recipe.assignment(seam, name)
    body += renamed(recipe.assignment(seam, 'core_rdata_hi_valid'), {'core_rdata_hi_valid': 'old_seam'})
    wide = recipe.assignment(changed['rtl/mem/ventium_l1_axi.sv'], 'core_rdata_hi_uncontended')
    if mutant == 'lost-route-deny':
        wide = once(wide, 'l1d_c_req', 'core_req')
        # The leaf request guard is still present: a seam-only route omission
        # cannot corrupt this expression. Deliberately break that leaf request
        # too to test that denied requests never become FP commands.
        body = once(body, '&& !core_route_deny', '')
    body += renamed(wide, {'core_rdata_hi_uncontended': 'new_seam',
                           'l1d_c_rdata_hi_uncontended': 'new_hi'})
    for name, label in (('fp_load64_take', 'take'), ('fp_shared_load_cmd', 'cmd')):
        body += renamed(recipe.assignment(core, name), {name: 'old_'+label, 'fp_load64_take': 'old_take'})
        new = recipe.assignment(changed['rtl/core/core.sv'], name)
        if mutant == 'lost-state' and label == 'take':
            new = once(new, '(state == S_FLOAD)', "1'b1")
        if mutant == 'lost-page-extent' and label == 'take':
            new = once(new, "(cur_lin_nat[11:0] <= 12'hff8)", "1'b1")
        if mutant == 'narrow-without-ack' and label == 'cmd':
            new = once(new, 'mem_read_ack &&', '')
        body += renamed(new, {name: 'new_'+label, 'fp_load64_take': 'new_take',
                              'bus_rdata_hi_uncontended': 'new_seam'})
    # Icarus lacks inside; exact binary expansion of the three constant values.
    before = 'q_fxop inside {FX_AR_I32, FX_FCOM_M32, FX_FCOM_M64}'
    assert body.count(before) == 2
    body = body.replace(before, '(q_fxop == FX_AR_I32 || q_fxop == FX_FCOM_M32 || q_fxop == FX_FCOM_M64)')
    tb = (HERE/'tb_fp_high_valid_cofactor.sv').read_text()
    tb = once(tb, 'localparam S_FLOAD=0, S_WALK=1;', 'localparam S_FLOAD=0, S_WALK=1, S_PIPE=2;')
    tb = once(tb, '  // EXTRACTED_EQUATIONS', '''  logic c_pair_intent;
  wire fp_high_current_hit, fp_high_window_owned;
  wire read_ack_current_hit, read_ack_window_reuse, read_ack_shadow_reuse, read_ack_code_reuse;
  wire code_hit=code_word_reuse, read_ack_code_fill_independent=0, fill_forward_code_hit=0;
  integer contextual_difference=0, forbidden_consumers=0;
'''+body)
    start, end = tb.index('  task automatic check;'), tb.index('  task automatic defaults;')
    tb = tb[:start]+'''  task automatic check;
    bit saved_next;
    saved_next=c_next_req;
    for (integer pair=0;pair<2;pair++) begin
      c_pair_intent=1'(pair);
      for (integer phase=0;phase<3;phase++) begin
        // A checked source/SMT obligation separately proves this core invariant.
        state=2'(phase);
        c_next_req=(state==S_PIPE) && saved_next;
        #1;
        checks++;
        if ((!c_next_req && (old_hi !== new_hi || old_seam !== new_seam)) ||
            old_take !== new_take || old_cmd !== new_cmd)
          $fatal(1,"FP-WIDE-CONTEXT-MISMATCH sample=%0d state=%0d next=%b hi=%b/%b take=%b/%b cmd=%b/%b",
                 checks,state,c_next_req,old_hi,new_hi,old_take,new_take,old_cmd,new_cmd);
        if (new_take && (!c_ack || !c_req || c_we || state!=S_FLOAD ||
                         core_smram_deny || core_route_deny || dma_drain_stall))
          $fatal(1,"FP-WIDE-CONTEXT-MISMATCH missing read owner");
        if (old_hi !== new_hi) begin
          if (state!=S_PIPE || !c_next_req || new_take || new_cmd)
            $fatal(1,"FP-WIDE-CONTEXT-MISMATCH consumed outside context");
          contextual_difference++;
        end
        if (state!=S_FLOAD) forbidden_consumers++;
        if (old_hi) begin
          high_count++;
          if (shadow_reuse) shadow_count++; else primary_count++;
        end
        if (old_take) take_count++;
        if (old_cmd && q_f_mbytes==4) narrow_count++;
        if (old_cmd && q_f_mbytes==8 && f_step==1) second_count++;
        if (mc_lookup_next && !old_hi) next_blocked++;
      end
    end
    c_next_req=saved_next;
  endtask

'''+tb[end:]
    tb = once(tb, '!narrow_count || !second_count || !next_blocked)', '''!narrow_count || !second_count || !forbidden_consumers
`ifdef VEN_PIPE_MEM_CHAIN
        || !next_blocked || !contextual_difference
`endif
       )''')
    tb = once(tb, '    $finish;', '''    $display("FP-WIDE-CONTEXT-OK checks=%0d different=%0d excluded=%0d takes=%0d",
             checks,contextual_difference,forbidden_consumers,take_count);
    $finish;''')
    return tb


def run_case(root, inputs, label, defines, mutant):
    folder = root/label
    folder.mkdir()
    sv, binary = folder/'tb.sv', folder/'test.vvp'
    sv.write_text(fixture(inputs, mutant))
    command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(binary),
               *['-D'+d for d in defines], str(sv)]
    with (folder/'build.log').open('x') as f:
        build = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=20)
    assert build.returncode == 0, (label, 'compile', (folder/'build.log').read_text())
    with (folder/'run.log').open('x') as f:
        run = subprocess.run(['/usr/bin/vvp', str(binary)], stdout=f, stderr=subprocess.STDOUT, timeout=120)
    log = (folder/'run.log').read_text()
    if mutant:
        assert run.returncode == 1 and 'FP-WIDE-CONTEXT-MISMATCH' in log, (label, log)
    else:
        assert run.returncode == 0 and 'FP-WIDE-CONTEXT-OK checks=3057600 ' in log, (label, log)
    return dict(label=label, mutant=mutant, defines=defines, build_exit=build.returncode,
                native_exit=run.returncode, command=command, log=log,
                artifacts={str(p): sha(p) for p in (sv, binary, folder/'build.log', folder/'run.log')})


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root, parent = args.out.resolve(), args.parent.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert scratch.stat().st_dev != HERE.stat().st_dev
    inputs = {p: (parent/p).read_text() for p in recipe.PARENTS | recipe.OFFER_PINS}
    source_scope(inputs)
    pins = {str(parent/p): sha(parent/p) for p in inputs}
    for p in (Path(__file__).resolve(), Path(recipe.__file__).resolve(),
              HERE/'test_fp_high_valid_cofactor.py', HERE/'tb_fp_high_valid_cofactor.sv',
              Path('/usr/bin/iverilog'), Path('/usr/bin/vvp')):
        pins[str(p)] = sha(p)
    root.mkdir()
    started = dict(pins=pins, invocation=os.environ.get('INVOCATION_ID'),
                   affinity=sorted(os.sched_getaffinity(0)))
    (root/'started.json').write_text(json.dumps(started, indent=2)+'\n')
    result = dict(passed=False, rows=[], errors=[], pins=pins, whole_core=False,
                  hardware_acceptance=False, standard_suite=False, gameplay_ipc=None,
                  fmax_mhz=None, assumes_consumer_state_exclusion=True)
    begin = time.monotonic()
    try:
        cases = [(name, COMMON+defs, None) for name, defs in PROFILES.items()]
        cases += [(name, COMMON+PROFILES['paired'], name) for name in MUTANTS]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(run_case, root, inputs, *case) for case in cases]
            for future in futures:
                row = future.result()
                result['rows'].append(row)
                print(json.dumps({k: row[k] for k in ('label', 'native_exit', 'log')}), flush=True)
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,
                  pins_unchanged=all(sha(p) == h for p, h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    (root/'closed.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('pins', 'rows')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
