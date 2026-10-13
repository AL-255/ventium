"""Unchanged wide-FP boundary/fault/replay plan for the payload-region cut.

Requires completed canonical and wide-FP runs. Preserve all original native
comparisons; existing canonical failures are not waived by this adapter.
"""
import ast
import hashlib
from pathlib import Path

from run_intent_ready_pairs import replace
from run_payload_region_core import PARENT,CANDIDATE

original=Path(__file__).with_name('run_fp_high_valid_regressions.py')


def derive():
    text=original.read_text()
    if hashlib.sha256(text.encode()).hexdigest()!='f850f47f0439d7ff0f896f12f862ef23720b8492713e90b5957b9f6730906b01':
        raise ValueError('payload-region FP regression lifecycle drift')
    text=replace(text,'"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__))
    text=replace(text,'from build_fp_high_valid_core import MODEL as PARENT_MODEL',
                 'PARENT_MODEL = '+repr(PARENT))
    text=replace(text,"MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'",
                 'MODEL = '+repr(CANDIDATE))
    text=replace(text,"pins={str(Path(__file__).resolve()):sha(__file__)}",
                 "pins={str(p):sha(p) for p in (Path(__file__).resolve(), original,\n"
                 "        Path(__file__).with_name('run_payload_region_core.py'),\n"
                 "        Path(__file__).with_name('run_intent_ready_pairs.py'))}")
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
