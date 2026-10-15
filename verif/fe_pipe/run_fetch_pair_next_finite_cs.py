"""Run original finite-CS RTL diagnostics on the composed timing model.

The reference QEMU discrepancy remains open. This preserves the self-checks,
complete A/B traces, native process receipts and latency 0/7/31 controls.
"""
import ast
from pathlib import Path

driver_source = Path(__file__).with_name('run_fetch_fragment_finite_cs.py')
text = driver_source.read_text()
for old, new in (
    ("('fetch-fragment-core-r1', '0698ce2f2e0de10ec1952704b63b40fd70fc8cbb682171d5ed83cade6e612c6c')",
     "('fetch-pair-next-core-r1', '8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1')"),
    ('for path in (Path(__file__), Path(native_observation.__file__),',
     'for path in (Path(__file__), driver_source, Path(native_observation.__file__),'),
):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
ast.parse(text)
if __name__ == '__main__':
    exec(compile(text, str(__file__), 'exec'), globals())
