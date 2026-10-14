"""Transfer the tested next-tag and compare-invalid changes to the full PC.

Keep the previous transfer's source-closure, harness, resource and evidence
checks. This experiment is not canonical-gate or FPGA acceptance.
"""
import ast
import hashlib
import importlib.util
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'verif/l1'))
import prepare_parallel_next_tag as next_tag

spec = importlib.util.spec_from_file_location('fp_compare_recipe', REPO / 'verif/fp_compare/prepare.py')
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


def transform(name, source):
    if name == 'fp_shared/ven_fp_top.sv':
        return classifier.transform(source)
    if name == 'rtl/mem/ven_l1d.sv':
        return next_tag.transform(source)
    raise ValueError('unreviewed source delta: ' + name)


def derive():
    original = Path(__file__).with_name('build_window_current_soc.py')
    text = original.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == 'ddfd33d54a5952e9168c5957a4e7e1225d00a8c364f8c8e3a310b913d90ef4e9'
    tree = ast.parse(text)
    function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'transform')
    lines = text.splitlines(keepends=True)
    text = ''.join(lines[:function.lineno-1] + lines[function.end_lineno:])
    for before, after, count in (
        ('c0de36c5456d737ed38431598095f3df7d5c03f4f61da5e9462d1ddb23cd772f',
         'da16060952d983b02d4373038e3faccc5cc8d577e7635c3ae1d104314c08098e', 1),
        ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
         '5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8', 1),
        ("CHANGES = [env_write.FILE, 'rtl/mem/ven_l1d.sv']",
         "CHANGES = ['fp_shared/ven_fp_top.sv', 'rtl/mem/ven_l1d.sv']", 1),
        ("proof / 'window-current-core-r1'", "proof / 'fp-compare-core-r1'", 1),
        ("proof / 'soc-r1'", "proof / 'window-current-soc-r1'", 1),
        ('window-current-regression-audit.json', 'fp-compare-regression-audit.json', 1),
        ('sim_window_current_', 'sim_fp_compare_', 1),
        ('Path(window.__file__), Path(env_write.__file__),',
         'original, Path(next_tag.__file__), Path(classifier.__file__),', 1),
    ):
        assert text.count(before) == count, before
        text = text.replace(before, after)
    ast.parse(text)
    return original, text


original, derived = derive()
exec(compile(derived, str(Path(__file__)), 'exec'), globals())
