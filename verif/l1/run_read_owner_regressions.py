"""Keep the wide-FP/fault/state/cycle regression plan for read-owner ACK.

Only exact model identities change. Canonical failures remain red; neither
these directed comparisons nor a same-input replay waive their acceptance.
"""
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
       "PARENT_MODEL='f3fb3256fb40d9af50d73f2ac80b26bb4f5e27ff4b95d9f279172b4e0c025e41'")
change("\nMODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'\n",
       "\nMODEL='3091744d8c87eef66ed5c598d43575a80e2e8de6d0790a478de96fb0b96cb9d2'\n")
change("pins={str(Path(__file__).resolve()):sha(__file__)}",
       """pins={str(Path(__file__).resolve()):sha(__file__)}
    pins[str(Path(__file__).with_name('run_fp_high_valid_regressions.py'))]=sha(Path(__file__).with_name('run_fp_high_valid_regressions.py'))""")

exec(compile(text, str(original), 'exec'), globals())
