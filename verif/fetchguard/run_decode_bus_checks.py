"""Preserve existing verdicts while replaying the DECODE cofactor derivative.

The adapters replace only model/source identities and the functional job-list
location. Delivery retains exact parent/candidate trace and cycle equality.
"""
import argparse
import inspect
import json
import os
from pathlib import Path
import subprocess
import sys

import build_decode_bus_core as builder
import prepare_decode_bus_payload as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/srt'))
import run_remainder_underflow_checks as prior
import run_underflow_delivery as delivery

MODEL = '30274adaf425f55835f21562d845b08bec4552d37f4e29fd35ae7d3a95cb0b25'
sha = prior.sha


def replace_exact(text, edits):
    original = text
    for old, new in edits:
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    recovered = text
    for old, new in reversed(edits):
        assert recovered.count(new) == 1, new
        recovered = recovered.replace(new, old)
    assert recovered == original
    return text


def derive(mode, parent):
    source, text, changes = prior.derive(mode, parent)
    edits = [(prior.MODEL, MODEL)]
    if mode == 'system':
        edits += [(prior.PARENT, builder.MODEL),
            ('import prepare_remainder_underflow_core as recipe', 'import prepare_decode_bus_payload as recipe'),
            ("assert all(recipe.transform((parent/'candidate'/n).read_text(),n)==(core/'candidate'/n).read_text() for n in recipe.PARENTS)",
             "assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()")]
    text = replace_exact(text, edits)
    compile(text, str(source), 'exec')
    return source, text, changes+edits


def adapt_delivery(text):
    return replace_exact(text, [
        ('range(0, len(rows), 3)', 'range(0, len(rows), 2)'),
        ('arow, brow = rows[i+1], rows[i+2]', 'arow, brow = rows[i], rows[i+1]'),
        ('len(rows) == 216', 'len(rows) == 144'),
        ('(BASE, LINK, Path(__file__), Path(tracefmt.__file__),',
         '(BASE, LINK, Path(__file__), Path(BASE_RUNNER), Path(tracefmt.__file__),')])


def validate(core):
    before, built = [json.loads((core/n).read_text()) for n in ('build-started.json', 'build-closed.json')]
    parent = Path(before['parent'])
    old = json.loads((parent/'build-started.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(core/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    assert sha(parent/'obj/tb_ventium') == before['parent_model'] == builder.MODEL
    assert before['definitions'] == old['definitions'] and len(before['definitions']) == 153
    assert 'VEN_X87_MF_STRICT' in before['definitions'] and before['changes'] == [recipe.FILE]
    files = builder.native.common.candidate_files(parent/'candidate')
    assert len(files) == 195
    assert [str(p.relative_to(parent/'candidate')) for p in files if sha(p) !=
            sha(core/'candidate'/p.relative_to(parent/'candidate'))] == [recipe.FILE]
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text()) == (core/'candidate'/recipe.FILE).read_text()
    assert all(sha(p) == digest for p, digest in before['pins'].items())
    return parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode', choices=('func', 'system', 'delivery'))
    for key in ('core', 'out'): ap.add_argument('--'+key, type=Path, required=True)
    a = ap.parse_args()
    core, out = a.core.resolve(strict=True), a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    parent = validate(core)
    if a.mode == 'delivery':
        assert parent.parent == core.parent
        namespace = dict(delivery.__dict__)
        namespace.update(__file__=str(Path(__file__).resolve()), BASE_RUNNER=delivery.__file__,
            MODELS={'parent': (parent.name, builder.MODEL), 'branch': (core.name, MODEL)})
        exec(compile(adapt_delivery(inspect.getsource(delivery.main)), str(Path(__file__).resolve()), 'exec'), namespace)
        sys.argv = [sys.argv[0], '--evidence', str(core.parent), '--out', str(out)]
        return namespace['main']()
    source, text, changes = derive(a.mode, parent)
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
        Path(builder.__file__), source, driver, core/'build-started.json', core/'build-closed.json',
        core/'obj/tb_ventium', parent/'obj/tb_ventium')}
    with out.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins, command=command, substitutions=changes, comparison_policy_unchanged=True), f, indent=2)
    env = dict(os.environ, PYTHONPATH=os.pathsep.join(str(REPO/p) for p in
        ('verif/fetchguard', 'verif/l1', 'verif/srt', 'verif/segment_extent')))
    code = subprocess.run(command, env=env, timeout=600).returncode
    stable = all(sha(p) == digest for p, digest in pins.items())
    with out.with_suffix('.driver-closed.json').open('x') as f:
        json.dump(dict(native_exit=code, pins_unchanged=stable), f, indent=2)
    assert stable
    return code


if __name__ == '__main__':
    raise SystemExit(main())
