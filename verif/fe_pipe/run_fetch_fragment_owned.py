"""Rerun the existing 108-case candidate corpus after owned-GDB qualification.

No RTL, job, mask, cycle band, comparison or limit changes. Explicitly migrate
only the two qualified verification-tool pins, retaining their previous hashes.
"""
import ast
import hashlib
import json
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/lib'))
import prepare_owned_gdb_cache as cache_recipe

BASE = REPO/'verif/qemu-trace/c1_reference/run_func.py'
BASE_SHA = '9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'
DATA = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X')
QUAL = DATA/'owned-gdb-r4/closed.json'
MODEL = '0698ce2f2e0de10ec1952704b63b40fd70fc8cbb682171d5ed83cade6e612c6c'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def qualify_tooling(pins):
    qualified = json.loads(QUAL.read_text())
    assert qualified['passed'] and len(qualified['checks']) == 8
    for path, sha in qualified['pins'].items():
        assert digest(path) == sha, path
    worker = REPO/'verif/lib/verify_worker.sh'
    assert cache_recipe.transform(cache_recipe.original(worker.read_text())) == worker.read_text()
    changes = {}
    expected = {
        str(worker): cache_recipe.PARENT_SHA,
        str(REPO/'verif/qemu-trace/gen_trace.py'): qualified['old_producer_sha256'],
    }
    for path, old_sha in expected.items():
        assert pins[path] == old_sha, (path, pins[path], old_sha)
        changes[path] = dict(before=old_sha, after=digest(path))
        pins[path] = digest(path)
    assert all(digest(path) == sha for path, sha in pins.items())
    for path in (Path(__file__), BASE, QUAL, Path(cache_recipe.__file__),
                 REPO/'verif/qemu-trace/owned_gdb.py'):
        pins[str(path)] = digest(path)
    return changes


def derive():
    assert digest(BASE) == BASE_SHA
    text = BASE.read_text()
    substitutions = [
        ('REPO=Path(__file__).resolve().parents[3]', 'REPO=Path('+repr(str(REPO))+')'),
        ("assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'",
         'assert sha(model)=='+repr(MODEL)),
        ("jobs_file=core/'generic-work/jobs.txt'",
         'jobs_file=Path('+repr(str(DATA/'prefix-payload-core-r1/generic-work/jobs.txt'))+')'),
        ('set(range(8,12))', 'set(range(13,17))'),
        ('cpu=8+index%4', 'cpu=13+index%4'),
        ("    actual=(core/'obj/Vventium_top__verFiles.dat').read_text()",
         "    tooling_deltas=qualify_tooling(pins)\n    actual=(core/'obj/Vventium_top__verFiles.dat').read_text()"),
        ("save(root/'started.json',dict(pins=pins,jobs=jobs,invocation=os.environ['INVOCATION_ID'],",
         "save(root/'started.json',dict(pins=pins,jobs=jobs,tooling_deltas=tooling_deltas,invocation=os.environ['INVOCATION_ID'],")]
    for old, new in substitutions:
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
