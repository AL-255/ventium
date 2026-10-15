"""Unmodified functional/system comparisons for the one-define strict repair."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import build_strict_mf_core as recipe
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
import run_branch_address_checks as prior
sha = prior.sha


def derive(mode, parent, model):
    source, text, changes = prior.derive(mode, parent)
    edits = [(prior.MODEL, model)]
    if mode == 'system':
        edits += [(prior.PARENT, recipe.MODEL),
            ('import prepare_branch_address_shape as recipe', 'import build_strict_mf_core as recipe'),
            ("assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()",
             "assert all(sha(p)==sha(core/'candidate'/p.relative_to(parent/'candidate')) for p in recipe.native.common.candidate_files(parent/'candidate'))")]
    original = text
    for old, new in edits:
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    recovered = text
    for old, new in reversed(edits):
        assert recovered.count(new) == 1, new
        recovered = recovered.replace(new, old)
    assert recovered == original
    compile(text, str(source), 'exec')
    return source, text, changes+edits


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode', choices=('func', 'system'))
    for key in ('core', 'out'): ap.add_argument('--'+key, type=Path, required=True)
    a = ap.parse_args()
    core, out = a.core.resolve(strict=True), a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    started, built = [json.loads((core/n).read_text()) for n in ('build-started.json', 'build-closed.json')]
    parent = Path(started['parent'])
    old = json.loads((parent/'build-started.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    model = sha(core/'obj/tb_ventium')
    assert model == built['binary_sha256'] and sha(parent/'obj/tb_ventium') == recipe.MODEL
    assert started['changes'] == [] and started['added_define'] == recipe.FLAG
    assert started['definitions'] == old['definitions']+[recipe.FLAG]
    assert len(started['definitions']) == 153
    files = recipe.native.common.candidate_files(parent/'candidate')
    assert len(files) == 195
    assert all(sha(p) == sha(core/'candidate'/p.relative_to(parent/'candidate')) for p in files)
    assert all(sha(p) == digest for p, digest in started['pins'].items())
    source, text, changes = derive(a.mode, parent, model)
    driver = out.with_suffix('.driver.py')
    with driver.open('x') as f: f.write(text)
    evidence = scratch/'ventium-fprem-sequence.iSZ9BAj4'
    tail = ['--core', core, '--out', out]
    if a.mode == 'func':
        tail += ['--build', evidence/'build-underflow-r1', '--probe', evidence/'srt-underflow-r2']
    else:
        tail += ['--parent', parent]
    command = list(map(str, [sys.executable, '-B', driver, *tail]))
    pins = {str(p.resolve()): sha(p) for p in (Path(__file__), Path(recipe.__file__), Path(prior.__file__),
        source, driver, core/'build-started.json', core/'build-closed.json', core/'obj/tb_ventium', parent/'obj/tb_ventium')}
    with out.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins, command=command, substitutions=changes, comparison_policy_unchanged=True), f, indent=2)
    env = dict(os.environ, PYTHONPATH=os.pathsep.join(str(REPO/p) for p in
        ('verif/sys', 'verif/l1', 'verif/srt', 'verif/segment_extent')))
    code = subprocess.run(command, env=env, timeout=600).returncode
    stable = all(sha(p) == digest for p, digest in pins.items())
    with out.with_suffix('.driver-closed.json').open('x') as f:
        json.dump(dict(native_exit=code, pins_unchanged=stable), f, indent=2)
    assert stable
    return code


if __name__ == '__main__':
    raise SystemExit(main())
