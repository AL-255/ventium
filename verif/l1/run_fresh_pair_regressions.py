"""Preserve the wide-FP/fault/cycle regression plan for fresh pair capture."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('run_fp_high_valid_regressions.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'f850f47f0439d7ff0f896f12f862ef23720b8492713e90b5957b9f6730906b01'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('from build_fp_high_valid_core import MODEL as PARENT_MODEL',
       "PARENT_MODEL='3091744d8c87eef66ed5c598d43575a80e2e8de6d0790a478de96fb0b96cb9d2'")
change("\nMODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'\n",
       "\nMODEL='e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81'\n")
change("pins={str(Path(__file__).resolve()):sha(__file__)}",
       """pins={str(Path(__file__).resolve()):sha(__file__)}
    pins[str(Path(__file__).with_name('run_fp_high_valid_regressions.py'))]=sha(Path(__file__).with_name('run_fp_high_valid_regressions.py'))""")

exec(compile(text, str(original), 'exec'), globals())
