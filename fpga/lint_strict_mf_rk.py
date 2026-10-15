"""Retain strict CPU-hierarchy lint with the exact 159-define hardware profile."""
from pathlib import Path

adapter = Path(__file__).with_name('lint_rem_split_rk.py')
text = adapter.read_text()
edits = [
    ('exactly the 158-define profile', 'exactly the strict-MF 159-define profile'),
    ('assert len(defs) == 158 and defs[154] == FLAG',
     "assert len(defs) == 159 and defs[154] == FLAG and defs[155] == 'VEN_X87_MF_STRICT'\n"
     '    defs = defs[:155]+defs[156:]'),
    ("'len(definitions) == len(set(definitions)) == 158 and definitions[154] == '+repr(FLAG)",
     "'len(definitions) == len(set(definitions)) == 159 and definitions[155] == \\\'VEN_X87_MF_STRICT\\\' and definitions[154] == '+repr(FLAG)"),
    ('Path(__file__),original,driver,', 'Path(__file__),adapter,original,driver,'),
]
original_text = text
for old, new in edits:
    assert text.count(old) == 1, old
    text = text.replace(old, new)
recovered = text
for old, new in reversed(edits):
    assert recovered.count(new) == 1, new
    recovered = recovered.replace(new, old)
assert recovered == original_text
exec(compile(text, str(Path(__file__)), 'exec'), globals())
