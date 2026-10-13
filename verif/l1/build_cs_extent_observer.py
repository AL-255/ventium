"""Relink a read-only CS-request observer; never rebuild or modify the RTL.

The observed binary is diagnostic until its complete traces match the original.
Reuse only the admitted model's archive/runtime objects and matching headers.
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

from build_pair_now_observer import ANCHOR, CORE, sha

REPO = Path(__file__).resolve().parents[2]
MODEL = '73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca'
FIELDS = dict(pc='eip', state='state', held_pc='pipe_mem_eip_q',
              active='pipe_mem_active_q', load='pipe_new_load_req',
              store='pipe_new_store_req', ack='mem_ack', commit='pipe_int_commit',
              boundary='sfetch_boundary', extent_fault='cs_extent_fault',
              frontend='pipe_frontend_ready')


def instrument(source):
    assert source.count(ANCHOR) == 1
    fmt = ' '.join(k+'=%x' for k in FIELDS)
    values = ',\n                '.join('unsigned(top->rootp->'+CORE+v+')' for v in FIELDS.values())
    probe = '''        // Read only settled PRE-edge values. No writes/evals/clock changes.
        if (std::getenv("VENTIUM_CS_OBSERVE")) {
            static unsigned cs_observed = 0;
            const auto* r = top->rootp;
            if (r->ventium_top__DOT__u_core__DOT__eip == 0x8030 ||
                (r->ventium_top__DOT__u_core__DOT__pipe_mem_active_q &&
                 r->ventium_top__DOT__u_core__DOT__pipe_mem_eip_q == 0x8030)) {
                if (++cs_observed > 4096) {
                    std::fprintf(stderr, "CS-OBS-ERROR: incomplete observation\\n");
                    std::exit(2);
                }
'''
    probe += ('                std::fprintf(stderr, "[CS-OBS] cycle=%llu '+fmt+'\\n",\n'
              '                    (unsigned long long)(cycles + 1), '+values+');\n'
              '            }\n        }\n\n')
    result = source.replace(ANCHOR, probe+ANCHOR)
    assert result.replace(probe, '', 1) == source
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('model', 'out'): ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    model = args.model.resolve(strict=True); obj = model/'obj'; out = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 3*1024**3
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    closed = json.loads((model/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
    assert sha(obj/'tb_ventium') == closed['binary_sha256'] == MODEL
    log = (model/'build.log').read_text().splitlines()
    compiles = [x for x in log if ' -c -o tb_prime_cs_' in x]
    links = [x for x in log if x.startswith('g++ ') and x.endswith(' -o tb_ventium')]
    assert len(compiles) == len(links) == 1
    compile_cmd, link_cmd = map(shlex.split, (compiles[0], links[0]))
    source = Path(compile_cmd[-1]); header = obj/'Vventium_top___024root.h'
    assert all(CORE+field+';' in header.read_text() for field in FIELDS.values())
    old_object = compile_cmd[compile_cmd.index('-o')+1]
    inputs = [Path(__file__).resolve(), REPO/'verif/l1/build_pair_now_observer.py',
              source, model/'build.log', model/'build-closed.json', obj/'tb_ventium']
    inputs += list(obj.glob('*.h'))
    inputs += [obj/x for x in link_cmd if x.endswith(('.o', '.a'))]
    old_dep = (obj/old_object).with_suffix('.d')
    inputs.append(old_dep)
    dependency = old_dep.read_text().replace('\\\n', ' ')
    for path in shlex.split(dependency.split(':', 1)[1]):
        p = Path(path) if Path(path).is_absolute() else obj/path
        inputs.append(p.resolve(strict=True))
    inputs.append(Path('/usr/bin/g++').resolve(strict=True))
    pins = {str(p): sha(p) for p in inputs}
    out.mkdir()
    basename = 'tb_cs_observer_'+hashlib.sha256(str(out).encode()).hexdigest()[:12]
    newsource, newobject = out/(basename+'.cpp'), out/(basename+'.o')
    newsource.write_text(instrument(source.read_text()))
    pins[str(newsource)] = sha(newsource)
    if compile_cmd[0] == 'ccache': compile_cmd.pop(0)
    compile_cmd = ['-I'+str(obj) if x == '-I.' else x for x in compile_cmd]
    compile_cmd[compile_cmd.index('-o')+1] = str(newobject)
    compile_cmd[-1] = str(newsource)
    link_cmd = [str(newobject) if x == old_object else
                str(obj/x) if x.endswith(('.o', '.a')) else x for x in link_cmd]
    binary = out/'tb_cs_observer'
    link_cmd[link_cmd.index('-o')+1] = str(binary)
    receipt = dict(passed=False, pins=pins, commands=[compile_cmd, link_cmd],
                   invocation=os.environ['INVOCATION_ID'], model_sha256=MODEL,
                   rtl_rebuilt=False, standard_suite=False, gameplay_ipc=None)
    (out/'started.json').write_text(json.dumps(receipt, indent=2)+'\n')
    start = time.monotonic()
    try:
        with (out/'build.log').open('x') as stream:
            for command in (compile_cmd, link_cmd):
                subprocess.run(command, cwd=out, check=True, timeout=120,
                               stdout=stream, stderr=subprocess.STDOUT, pass_fds=(9,))
        dependency = newobject.with_suffix('.d').read_text().replace('\\\n', ' ')
        assert str(header) in dependency and str(obj/'Vventium_top.h') in dependency
        # Freeze every actual host include as well as every linked model input.
        paths = shlex.split(dependency.split(':', 1)[1])
        for path in paths:
            p = Path(path) if Path(path).is_absolute() else out/path
            pins[str(p.resolve(strict=True))] = sha(p)
        receipt.update(passed=True, binary_sha256=sha(binary),
                       observer_source_sha256=sha(newsource))
    finally:
        receipt.update(seconds=time.monotonic()-start,
                       pins_unchanged=all(sha(p)==h for p,h in pins.items()))
        with (out/'closed.json').open('x') as stream: json.dump(receipt, stream, indent=2)
    assert receipt['pins_unchanged']
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('pins','commands')}))


if __name__ == '__main__': main()
