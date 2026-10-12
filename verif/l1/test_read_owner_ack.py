"""Native extracted read-owner ACK test, including actual code-fill eligibility.

Binary leaf stimuli are not a sequential cache proof or hardware acceptance.
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

import prepare_read_owner_ack as recipe

HERE = Path(__file__).resolve().parent


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fixture(source, mode):
    body = ''
    for name in ('code_access', 'code_hit', 'rd_match', 'mc_lookup_old',
                 'mc_lookup_prime', 'mc_lookup_next', 'window_reuse',
                 'shadow_reuse', 'code_word_reuse', 'set_c', 'xline'):
        body += recipe.assignment(source, name)
    # This assignment has semicolons in mutually exclusive preprocessor
    # branches. A first-semicolon extractor would truncate its `ifdef tree.
    start = source.index('  logic fill_independent_hit;\n') + len('  logic fill_independent_hit;\n')
    end = source.index('  // A critical word can be returned', start)
    fill_block = source[start:end]
    assert fill_block.startswith('`ifdef VEN_L1D_HIT_UNDER_FILL\n')
    assert fill_block.endswith('`endif\n')
    body += fill_block
    for name in ('lookup_addr', 'lookup_wstrb'):
        rows = re.findall(r'  assign ' + name + r'\s*=.*?;\n', source, re.S)
        assert len(rows) == 2 and 'mc_lookup_next ?' in rows[0]
        body += rows[0]  # All leaf profiles enable VEN_PIPE_MEM_CHAIN.
    extent = re.findall(r'  always_comb begin\n    c_x_hi = .*?\n  end\n', source, re.S)
    assert len(extent) == 1
    body += extent[0]
    body += recipe.ack_block(source).replace('c_read_ack', 'old_ack')
    new = recipe.helpers(source) + recipe.ack_block(recipe.transform(source))
    mutations = {
        'lost-owner': ('(rd_match && !flush_all && !snoop_inv_valid',
                       "(1'b0 && !flush_all && !snoop_inv_valid"),
        'lost-residency': ('assign read_ack_current_hit = |tag_current_hit;',
                           "assign read_ack_current_hit = 1'b1;"),
        'lost-code-fill-exclusion': ('!bypass_q && !code_fill_q;',
                                    "!bypass_q && 1'b1;"),
    }
    if mode in mutations:
        new = recipe.replace(new, *mutations[mode])
    elif mode == 'lost-cache':
        old = '&& !(BYPASS_RD_EN && !cacheable)'
        assert new.count(old) == 2
        new = new.replace(old, '')
    elif mode == 'lost-flush':
        new = new.replace('!flush_all', "1'b1")
    else:
        assert mode.startswith('positive')
    body += new.replace('c_read_ack', 'new_ack')
    template = (HERE/'tb_read_ack_absorption.sv').read_text()
    template = recipe.replace(template,
        '  reg code_valid_q,fill_independent_hit,fill_forward_code_hit;',
        '''  reg code_valid_q,fill_forward_code_hit,c_pair_intent;
  wire fill_independent_hit;
  wire [31:0] lookup_addr;
  wire [3:0] lookup_wstrb;
  reg [3:0] c_next_wstrb;
  wire [6:0] set_c;
  reg [2:0] c_x_hi;
  wire xline;''')
    template = recipe.replace(template,
        'code_valid_q,fill_independent_hit,fill_forward_code_hit,',
        'code_valid_q,c_pair_intent,fill_forward_code_hit,')
    template = recipe.replace(template,
        'random_q=next_random(random_q);c_next_addr=random_q;',
        'random_q=next_random(random_q);c_next_addr=random_q;c_next_wstrb=random_q[3:0];')
    template = recipe.replace(template,
        '    if(lookahead_checks==0 || window_checks==0 || shadow_checks==0 || code_checks==0)',
        '''    // An instruction staging line may serve during a data fill,
    // never by borrowing the D port during a code fill. Check the original
    // selected-address extent calculation, not a free eligibility input.
    for(shape=0;shape<4096;shape=shape+1) begin
      randomize_inputs();
      rst_n=1;c_req=1;c_we=0;golden=0;stream_path=0;st=L1_FILL;
      c_addr=32'h1234001c;rd_addr_q=c_addr;c_wstrb=4'hf;
      c_next_addr=32'h1234003f;c_next_wstrb=4'hf;
      shadow_line_addr_q=c_addr[31:5];code_line_tag_q=c_addr[31:5];
      early_match=0;byp_match=0;fill_forward_code_hit=0;
      {code_fill_q,bypass_q,c_next_req,c_pair_intent,rd_armed,rd_code_q,
       c_code,code_valid_q,early_armed,flush_all,snoop_inv_valid,cacheable}=shape[11:0];
      check();
    end
    if(lookahead_checks==0 || window_checks==0 || shadow_checks==0 || code_checks==0)''')
    return recipe.replace(template, '  // EXTRACTED_EQUATIONS', body)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    source_path = args.source.resolve(strict=True)
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert scratch.stat().st_dev != HERE.stat().st_dev
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert os.sched_getaffinity(0) == {12} and os.environ.get('INVOCATION_ID')
    source = source_path.read_text()
    derivative = recipe.transform(source)
    for bad in (source+'\n', derivative):
        try: recipe.transform(bad)
        except ValueError: pass
        else: raise AssertionError('accepted drift/reapplication')
    # General read ACK is changed too; data selection stays byte-identical.
    assert derivative.count('read_ack_window_reuse || read_ack_shadow_reuse') == 2
    assert derivative.count('logic c_ack_before_read_owner_cut;') == 1
    pins = {str(p):sha(p) for p in (source_path, Path(__file__).resolve(),
        Path(recipe.__file__).resolve(), Path(recipe.base.__file__).resolve(),
        HERE/'tb_read_ack_absorption.sv')}
    definitions = ['VEN_FP_LOAD_EARLY_CMD','VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME',
        'VEN_L1D_PRIME_UNDER_FILL','VEN_L1D_CODE_BUFFER','VEN_L1D_WINDOW_REUSE',
        'VEN_L1D_TWO_WINDOW_REUSE','VEN_L1D_CODE_WORD_REUSE','VEN_L1D_HIT_STREAM',
        'VEN_P54_DUAL_STORE_PAIR']
    modes = [('positive-base',['VEN_L1D_HIT_UNDER_FILL']),
        ('positive-datafill',['VEN_L1D_HIT_UNDER_FILL','VEN_L1D_DATA_UNDER_IFILL']),
        ('positive-no-fill',[])]
    modes += [(name,['VEN_L1D_HIT_UNDER_FILL']) for name in
        ('lost-owner','lost-residency','lost-cache','lost-flush','lost-code-fill-exclusion')]
    root.mkdir()
    def save(name, value):
        with (root/name).open('x') as stream: json.dump(value, stream, indent=2)
    save('started.json', dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
                             affinity=sorted(os.sched_getaffinity(0))))
    (root/'ven_l1d.sv').write_text(derivative)
    begin = time.monotonic()
    rows, errors = [], []
    try:
        for mode, extra in modes:
            folder = root/mode; folder.mkdir()
            sv, binary = folder/'tb.sv', folder/'test.vvp'
            sv.write_text(fixture(source,mode))
            command = ['/usr/bin/iverilog','-g2012','-s','tb','-o',str(binary),
                       *['-D'+d for d in definitions+extra],str(sv)]
            built = subprocess.run(command,text=True,capture_output=True,timeout=15)
            (folder/'build.log').write_text(built.stdout+built.stderr)
            assert built.returncode == 0, (mode,built.stderr)
            ran = subprocess.run(['/usr/bin/vvp',str(binary)],text=True,capture_output=True,timeout=40)
            log = ran.stdout+ran.stderr
            (folder/'run.log').write_text(log)
            positive = mode.startswith('positive')
            marker = ('READ-ACK-ABSORPTION-OK checks=220480' if positive else
                      'READ-ACK-ABSORPTION-MISMATCH')
            row = dict(mode=mode,command=command,compile_exit=built.returncode,
                native_exit=ran.returncode,expected_failure=not positive,
                artifacts={str(p):sha(p) for p in (sv,binary,folder/'build.log',folder/'run.log')})
            rows.append(row)
            assert ran.returncode == (0 if positive else 1) and marker in log, (mode,log)
            print(mode,log.strip(),flush=True)
    except Exception as exc:
        errors.append(repr(exc))
    stable = all(sha(p)==h for p,h in pins.items())
    result = dict(passed=not errors and stable and len(rows)==8,pins_unchanged=stable,
        rows=rows,errors=errors,seconds=time.monotonic()-begin,
        derivative_sha256=sha(root/'ven_l1d.sv'),sequential_cache=False,
        whole_core=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
