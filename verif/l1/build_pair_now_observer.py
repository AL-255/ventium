"""Build a read-only pre-edge observer against the exact closed paired-load model.

No Verilator/RTL rebuild and no model state forcing. Reuse only this model's
immutable archive/runtime objects; compile the unique harness against its headers.
The resulting binary is diagnostic until its full traces match the original.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

MODEL = '66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'
ANCHOR = '        // -- clk high phase: rising edge; vtm_retire fires inside eval() --'
CORE = 'ventium_top__DOT__u_core__DOT__'
L1 = 'ventium_top__DOT__u_l1axi__DOT__'
CACHE = L1 + 'u_l1d__DOT__'
FIELDS = {
    'pc': CORE+'eip', 'state': CORE+'state',
    'req': CORE+'pipe_v_pair_request', 'accept': CORE+'pipe_v_pair_now_accept',
    'active': CORE+'pipe_mem_active_q', 'ack': CORE+'mem_ack',
    'read_ack': CORE+'mem_read_ack', 'leaf_now': L1+'pair_leaf_now_valid',
    'pair_req': 'ventium_top__DOT____Vcellinp__u_l1axi__core_pair_req_valid',
    'pair_rsp': L1+'pair_leaf_rsp_valid', 'creq': L1+'l1d_c_req',
    'cacheable': L1+'l1d_cacheable', 'cache_state': CACHE+'st',
    'window': CACHE+'window_valid_q', 'shadow': CACHE+'shadow_valid_q',
    'reuse': CACHE+'window_reuse', 'sreuse': CACHE+'shadow_reuse',
    'full': CACHE+'rd_full_line_q', 'rd_armed': CACHE+'rd_armed',
    'rd_code': CACHE+'rd_code_q', 'rd_match': CACHE+'rd_match',
    'early': CACHE+'early_armed', 'hit': CACHE+'hit',
    'lookup': CACHE+'lookup_addr', 'rd_addr': CACHE+'rd_addr_q',
    'shadow_tag': CACHE+'shadow_line_addr_q',
}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--model', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    root = Path('/home/yukidama/external/tmp').resolve(strict=True)
    model = args.model.resolve(strict=True); obj = model/'obj'; out = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == root
    assert out.is_relative_to(root) and out != root and not out.exists()
    assert shutil.disk_usage(root).free > 4*1024**3
    # The caller owns the actual shared heavyweight lock, not just an env marker.
    os.fstat(9)
    assert sha(obj/'tb_ventium') == MODEL
    log = (model/'build.log').read_text().splitlines()
    compile_lines = [x for x in log if ' -c -o tb_pair_now_read_' in x]
    link_lines = [x for x in log if x.startswith('g++ ') and x.endswith(' -o tb_ventium')]
    assert len(compile_lines) == len(link_lines) == 1
    compile_cmd = shlex.split(compile_lines[0]); link_cmd = shlex.split(link_lines[0])
    source = Path(compile_cmd[-1]); original = source.read_text()
    header = obj/'Vventium_top___024root.h'; header_text = header.read_text()
    assert original.count(ANCHOR) == 1
    assert all(field+';' in header_text for field in FIELDS.values())
    old_object = compile_cmd[compile_cmd.index('-o')+1]
    inputs = [Path(__file__).resolve(), source, model/'build.log', obj/'tb_ventium']
    inputs += list(obj.glob('*.h'))
    inputs += [obj/x for x in link_cmd if x.endswith(('.o', '.a'))]
    pins = {str(p): sha(p) for p in inputs}
    out.mkdir()
    newsource = out/'tb_pair_now_observer_66cfd2e6.cpp'
    fmt = ' '.join(k+'=%x' for k in FIELDS)
    values = ',\n                '.join('unsigned(top->rootp->'+v+')' for v in FIELDS.values())
    probe = ('        if (std::getenv("VENTIUM_PAIR_OBSERVE") &&\n'
             '            top->rootp->'+CORE+'pipe_v_pair_request) {\n'
             '            std::fprintf(stderr, "[PAIR-OBS] cycle=%llu '+fmt+'\\n",\n'
             '                (unsigned long long)(cycles + 1), '+values+');\n'
             '        }\n\n')
    newsource.write_text(original.replace(ANCHOR, probe+ANCHOR))
    if compile_cmd[0] == 'ccache': compile_cmd.pop(0)
    compile_cmd = ['-I'+str(obj) if x == '-I.' else x for x in compile_cmd]
    newobject = out/'tb_pair_now_observer_66cfd2e6.o'
    compile_cmd[compile_cmd.index('-o')+1] = str(newobject)
    compile_cmd[-1] = str(newsource)
    link_cmd = [str(newobject) if x == old_object else
                str(obj/x) if x.endswith(('.o', '.a')) else x for x in link_cmd]
    binary = out/'tb_pair_observer'
    link_cmd[link_cmd.index('-o')+1] = str(binary)
    started = time.monotonic()
    receipt = dict(passed=False, pins=pins, commands=[compile_cmd, link_cmd],
                   invocation=os.environ.get('INVOCATION_ID'), model_sha256=MODEL)
    (out/'started.json').write_text(json.dumps(receipt, indent=2)+'\n')
    try:
        with (out/'build.log').open('x') as stream:
            for command in (compile_cmd, link_cmd):
                subprocess.run(command, cwd=out, check=True, timeout=120,
                               stdout=stream, stderr=subprocess.STDOUT, pass_fds=(9,))
        dependencies = newobject.with_suffix('.d').read_text()
        assert str(header) in dependencies and str(obj/'Vventium_top.h') in dependencies
        receipt.update(passed=True, binary_sha256=sha(binary),
                       observer_source_sha256=sha(newsource))
    finally:
        receipt.update(elapsed_s=time.monotonic()-started,
                       pins_unchanged=all(sha(p)==h for p,h in pins.items()))
        (out/'closed.json').write_text(json.dumps(receipt, indent=2)+'\n')
    assert receipt['pins_unchanged']
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('pins','commands')}))


if __name__ == '__main__': main()
