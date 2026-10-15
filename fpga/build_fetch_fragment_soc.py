"""Transfer the proved boundary-fetch extent cofactor into the full PC model.

Keep the 102-source equality audit, 156 definitions, UV-fast/full caches,
single-fill/posted16 and the existing resource-bounded compiler lifecycle.
Only the native-qualified owned-GDB/cache tool pins are deliberately migrated.
Canonical and hardware acceptance remain open.
"""
import ast
import hashlib
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/fe_pipe'))
import prepare_fetch_fragment_extent as recipe
import run_fetch_fragment_owned as tooling


def transform(name, source):
    if name == recipe.FILE:
        return recipe.transform(source)
    raise ValueError('unreviewed source delta: '+name)


def derive():
    original = Path(__file__).with_name('build_window_current_soc.py')
    text = original.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == 'ddfd33d54a5952e9168c5957a4e7e1225d00a8c364f8c8e3a310b913d90ef4e9'
    tree = ast.parse(text)
    function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'transform')
    lines = text.splitlines(keepends=True)
    text = ''.join(lines[:function.lineno-1]+lines[function.end_lineno:])
    replacements = (
        ('"""'+ast.get_docstring(tree, clean=False)+'"""', repr(__doc__)),
        ('c0de36c5456d737ed38431598095f3df7d5c03f4f61da5e9462d1ddb23cd772f',
         '5eee4d74d729663ad6af4abaa3f0fdbd5cc59937a36945ca81ff46e33b891ce9'),
        ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7', tooling.MODEL),
        ("CHANGES = [env_write.FILE, 'rtl/mem/ven_l1d.sv']", 'CHANGES = [recipe.FILE]'),
        ("proof / 'window-current-core-r1'", "proof / 'fetch-fragment-core-r1'"),
        ("proof / 'soc-r1'", "proof / 'prefix-payload-soc-r1'"),
        ('window-current-regression-audit.json', 'fetch-fragment-regression-audit.json'),
        ('sim_window_current_', 'sim_fetch_fragment_'),
        ('    pins.update(before[\'pins\'])',
         "    pins.update(before['pins'])\n    tooling_deltas = tooling.qualify_tooling(pins)"),
        ('Path(window.__file__), Path(env_write.__file__),',
         'original, Path(recipe.__file__), Path(tooling.__file__),'),
        ('parent_model=PARENT_MODEL, directed_model=CORE_MODEL, functional_corpus_passed=True,',
         'parent_model=PARENT_MODEL, directed_model=CORE_MODEL, functional_corpus_passed=True,\n'
         '        tooling_deltas=tooling_deltas,'),
        ('Two-file transfer prepared;', 'One-file transfer prepared;'),
        ("    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]",
         "    affinity = command.index('taskset')\n"
         "    assert command[affinity+1:affinity+3] == ['-c', '0-9,12-31']\n"
         "    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]"))
    for old, new in replacements:
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    ast.parse(text)
    return original, text


original, derived = derive()
exec(compile(derived, str(Path(__file__)), 'exec'), globals())
