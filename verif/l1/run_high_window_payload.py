#!/usr/bin/env python3
"""Current full-profile L1 high-word mux: public traffic, complete clock A/B."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import time

import prepare_high_window_payload as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]

def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--fixture-root', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    root, parent, fixture = [p.resolve(strict=True) for p in (a.out, a.parent, a.fixture_root)]
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    assert Path(os.environ['TMPDIR']).resolve() == root
    assert subprocess.run([REPO/'tools/build_scope.sh', '--is-active'],
        pass_fds=(9,), stdout=subprocess.DEVNULL).returncode == 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    def load(p): return json.loads(p.read_text())
    def save(n, v):
        with (root/n).open('x') as f: json.dump(v, f, indent=2)
    prior = load(parent/'build-started.json')
    built = load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == '3c3ab2151327a5a65803f6c5429cd24a9ee29c7300d16b1478547c68f0da8d99'
    assert all(sha(p) == h for p, h in prior['pins'].items())
    original = parent/'candidate'/recipe.TARGET
    assert sha(original) == 'f812ea7b5147638c03afe544f7ce76384272007069b3fa022cb9e7032bce6583'
    old_fixture = fixture/'tb_l1d_mem_chain.sv'
    assert sha(old_fixture) == '9fd552cc5dd08c29cf92a27e6d1e3f80369626b398c169af8c96a48873528831'
    assert load(fixture/'closed.json')['passed']
    text = old_fixture.read_text()
    # Extend the exact closed fixture, preserving all earlier vectors/observers.
    for before, after in (
        ('  `include "response_payload_leaf.svh"', '  `include "response_payload_leaf.svh"\n  `include "high_window_payload_leaf.svh"'),
        ('    run_response_payload();\n    $finish;', '    run_response_payload();\n    run_high_window_payload();\n    $finish;')):
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    tb = root/'tb_l1d_mem_chain.sv'
    tb.write_text(text)
    changed = recipe.transform(original.read_text())
    candidate = root/'ven_l1d.sv'; candidate.write_text(changed)
    wrong = root/'wrong_high_word.sv'
    wrong.write_text(changed.replace(recipe.NEW, recipe.NEW.replace('+: 32];', '+: 32] ^ 32\'d1;')))
    no_identity = root/'wrong_shadow_owner.sv'
    assert changed.count(recipe.SELECT) == 1
    no_identity.write_text(changed.replace(recipe.SELECT,
        recipe.SELECT.replace('(c_addr[31:5] == shadow_line_addr_q)', "1'b1")))
    flags = next(s.split('=', 1)[1].split() for s in prior['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defines = [s for s in flags if s.startswith('+define+')]
    assert '+define+VEN_L1D_RESPONSE_PAYLOAD_SELECT' in defines
    assert '+define+'+recipe.FLAG not in defines and '+define+SYNTHESIS' not in defines
    modules = [parent/'candidate/rtl/mem'/n for n in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    files = [Path(__file__), Path(recipe.__file__), original, candidate, wrong, no_identity,
        old_fixture, fixture/'closed.json', tb, *modules,
        *(HERE/n for n in ('high_window_payload_leaf.svh', 'response_payload_leaf.svh',
                          'window_write_update_leaf.svh', 'store_window_warm_leaf.svh'))]
    pins = {str(p): sha(p) for p in files}
    save('started.json', dict(pins=pins, defines=defines, parent_model=built['binary_sha256'],
        invocation=os.environ.get('INVOCATION_ID'), qualified_gameplay_ipc=None))
    begin = time.monotonic()
    result = dict(passed=False, variants=[], errors=[], gameplay_ipc=None, standard_suite=False,
        synthesis_started=False, production_changed=False)
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1')
    try:
        for name, source, enabled, negative in (
            ('control', original, False, False), ('off', candidate, False, False),
            ('on', candidate, True, False), ('wrong-word', wrong, True, True),
            ('wrong-owner', no_identity, True, True)):
            leaf = root/name; leaf.mkdir()
            command = ['timeout', '--kill-after=5s', '180s', '/tools/verilator/v5.046/bin/verilator',
                '--binary', '--timing', '-sv', '--assert', '-j', '32', '-Wno-fatal', '-Wno-UNUSED',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-I'+str(HERE), '--top-module', 'tb_l1d_mem_chain', '--Mdir', str(leaf/'obj'), '-o', 'test',
                *defines, *(['+define+'+recipe.FLAG] if enabled else []), *map(str,modules), str(source), str(tb)]
            save(name+'/command.json', command)
            with (leaf/'build.log').open('x') as f:
                build = subprocess.run(command, env=env, stdout=f, stderr=subprocess.STDOUT, pass_fds=(9,), timeout=190)
            row = dict(name=name, build_exit=build.returncode)
            result['variants'].append(row)
            assert build.returncode == 0, row
            obs = leaf/'cycles.txt'
            with (leaf/'run.log').open('x') as f:
                native = subprocess.run(['timeout','30s',leaf/'obj/test','+OBS='+str(obs)],
                    env=env, stdout=f, stderr=subprocess.STDOUT, timeout=40)
            log = (leaf/'run.log').read_text()
            row.update(native_exit=native.returncode, binary_sha256=sha(leaf/'obj/test'))
            if negative:
                assert native.returncode in (1,-6,134) and re.search('HIGH-WINDOW-(?:PAYLOAD|BACKING)',log), (row,log)
                row['required_negative_observed'] = True
            else:
                assert native.returncode == 0 and not re.search(r'%Error|%Fatal|FATAL:|Assertion failed',log), (row,log)
                for marker in ('L1D-MEM-CHAIN-OK accepted=150', 'WINDOW-WRITE-UPDATE-OK',
                    'STORE-WARM-OK', 'RESPONSE-PAYLOAD-OK', 'HIGH-WINDOW-PAYLOAD-OK'):
                    assert marker in log, (name,marker)
                row['coverage'] = re.findall(r'HIGH-WINDOW-PAYLOAD-OK.*',log)
            row['cycles_sha256'] = sha(obs)
            with obs.open('rb') as src, gzip.open(str(obs)+'.gz','xb',compresslevel=3) as dst:
                while block := src.read(1024*1024): dst.write(block)
            with gzip.open(str(obs)+'.gz','rb') as f:
                assert hashlib.file_digest(f,'sha256').hexdigest() == row['cycles_sha256']
            obs.unlink()
            print(json.dumps(row), flush=True)
        assert len({r['cycles_sha256'] for r in result['variants'][:3]}) == 1
        result.update(passed=True, all_clock_interface_observations_identical=True)
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()), seconds=time.monotonic()-begin)
        result['passed'] &= result['pins_unchanged']
        save('closed.json', result)
        print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
