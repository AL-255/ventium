"""Source-matched full-PC transfer of the exact response-kind mux cofactor.

Preserve UV-fast, full caches, single-fill and posted-16. No acceptance inherited.
"""
import ast
import hashlib
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_response_kind_mux as recipe


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
    substitutions = (
        ('"""'+ast.get_docstring(tree, clean=False)+'"""', repr(__doc__)),
        ('c0de36c5456d737ed38431598095f3df7d5c03f4f61da5e9462d1ddb23cd772f',
         '5eee4d74d729663ad6af4abaa3f0fdbd5cc59937a36945ca81ff46e33b891ce9'),
        ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
         'da6744ec11615ca7900a6ed132bc9e64471dd567e363d33985864e50719be6dd'),
        ("CHANGES = [env_write.FILE, 'rtl/mem/ven_l1d.sv']", "CHANGES = [recipe.FILE]"),
        ("proof / 'window-current-core-r1'", "proof / 'response-kind-core-r1'"),
        ("proof / 'soc-r1'", "proof / 'prefix-payload-soc-r1'"),
        ('window-current-regression-audit.json', 'response-kind-regression-audit.json'),
        ('sim_window_current_', 'sim_response_kind_'),
        ('Path(window.__file__), Path(env_write.__file__),', 'original, Path(recipe.__file__),'),
        ('Two-file transfer prepared;', 'One-file transfer prepared;'),
        ("    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]",
         "    affinity = command.index('taskset')\n"
         "    assert command[affinity+1:affinity+3] == ['-c', '0-9,12-31']\n"
         "    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]"),
    )
    for before, after in substitutions:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    ast.parse(text)
    return original, text


original, derived = derive()
exec(compile(derived, str(Path(__file__)), 'exec'), globals())
