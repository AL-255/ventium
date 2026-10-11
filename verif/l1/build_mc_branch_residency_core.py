#!/usr/bin/env python3
"""Build one-header branch-ownership derivative after its extracted RTL miter.

Run through the shared guarded-32 build profile, after the active timing queue.
This script does not launch Vivado, change defines, or claim a correctness pass.
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

from prepare_mc_branch_residency import transform

REPO = Path(__file__).resolve().parents[2]
PARENT_MODEL = 'bdb364eb1eae5f714b35f415fdea9974ea7c517c3b15e1e132b465fd16d84c70'
HEADER = 'rtl/core/core_mem_chain.svh'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def relocate(command, parent, root, oldhost, host):
    pairs = [(str(parent/'candidate'), str(root/'candidate')),
             (str(parent/'obj'), str(root/'obj')), (str(oldhost), str(host))]
    for old, _ in pairs:
        assert any(old in arg for arg in command), ('missing build input', old)
    changed = command.copy()
    for old, new in pairs:
        changed = [arg.replace(old, new) for arg in changed]
    recovered = changed.copy()
    for old, new in reversed(pairs):
        recovered = [arg.replace(new, old) for arg in recovered]
    assert recovered == command, 'non-reversible build relocation'
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'leaf', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    parent, leaf = args.parent.resolve(strict=True), args.leaf.resolve(strict=True)
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    subprocess.run([str(REPO/'tools/build_scope.sh'), '--is-active'], pass_fds=(9,), check=True)
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    audit = load(parent.parent/'core-audit.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == audit['model_sha256'] == sha(parent/'obj/tb_ventium') == PARENT_MODEL
    assert audit['audit_complete'] and audit['directed_regressions_passed']
    assert not audit['canonical_gate_passed'], 're-review provenance if canonical status changes'
    before, checked = load(leaf/'started.json'), load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and checked['error'] is None
    assert checked['invocation'] == before['invocation']
    assert [(r['name'], r['native_exit']) for r in checked['rows']] == [
        ('positive-0', 0), ('positive-1', 0), ('lost-ownership', 1), ('wrong-line', 1)]
    assert all(r['passed'] and sha(leaf/(r['name']+'.log')) == r['log_sha256'] for r in checked['rows'])
    pins = {**old['pins'], **before['pins']}
    for filename in ('core.sv', 'core_mem_chain.svh', 'core_raw_branch_mov.svh',
                     'core_ic_residency_span.svh', 'ventium_decode_pkg.sv', 'ventium_alu_pkg.sv'):
        assert sha(parent/'candidate/rtl/core'/filename) == sha(Path(before['source'])/filename)
    replacement = transform((parent/'candidate'/HEADER).read_text())
    assert replacement == (leaf/'core_mem_chain.svh').read_text()
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)', flags)
    assert len(definitions) == len(set(definitions)) == 150
    assert {'VEN_IC_RESIDENCY_SPAN', 'VEN_RAW_BRANCH_FALLTHROUGH_PRIME', 'VEN_FE_PIPE',
            'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT', 'VEN_L1_AXI'} <= set(definitions)
    assert '--assert' in flags and 'VL_J=32' in old['command']
    assert all(sha(p) == h for p, h in pins.items())
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    (root/'candidate'/HEADER).write_text(replacement)
    files = sorted(str(p.relative_to(parent/'candidate')) for p in (parent/'candidate').rglob('*') if p.is_file())
    assert sorted(str(p.relative_to(root/'candidate')) for p in (root/'candidate').rglob('*') if p.is_file()) == files
    assert [p for p in files if sha(root/'candidate'/p) != sha(parent/'candidate'/p)] == [HEADER]
    oldhost = Path(old['host'])
    host = root/('tb_mc_branch_residency_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost, host)
    command = relocate(old['command'], parent, root, oldhost, host)
    for p in (Path(__file__).resolve(), Path(__file__).with_name('prepare_mc_branch_residency.py'),
              parent/'build-started.json', parent/'build-closed.json', parent.parent/'core-audit.json',
              parent/'obj/tb_ventium', leaf/'started.json', leaf/'closed.json', host):
        pins[str(p)] = sha(p)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in files})
    save(root/'build-started.json', dict(command=command, pins=pins, host=str(host),
        parent_model=PARENT_MODEL, changes=[HEADER], invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), canonical_gate_passed=False, gameplay_ipc=None))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, gameplay_ipc=None, standard_suite=False)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native = subprocess.run(command, env={**os.environ, 'CCACHE_DISABLE':'1'}, stdout=stream,
                stderr=subprocess.STDOUT, pass_fds=(9,), timeout=600)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj = root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
                   if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        import traceback
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()), seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
