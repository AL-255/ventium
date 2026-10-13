"""Unchanged FP-boundary/fault/integer/memory/replay gates for the hint cofactor.

Both models use identical UV-fast profiles. Require the full FP matrix and
closed canonical evidence; preserve and report canonical failures explicitly.
"""
import ast
from pathlib import Path

import run_fp_wide_context_regressions as previous
from run_intent_ready_pairs import replace
from run_prime_coherence_core import PARENT,CANDIDATE

original=previous.original


def derive():
    text=previous.derive()
    for old,new in (
        (repr(previous.__doc__),repr(__doc__)),
        ('PARENT_MODEL = '+repr(previous.PARENT),'PARENT_MODEL = '+repr(PARENT)),
        ('MODEL = '+repr(previous.CANDIDATE),'MODEL = '+repr(CANDIDATE)),
        ("Path(__file__).with_name('run_intent_ready_pairs.py'))}",
         "Path(__file__).with_name('run_intent_ready_pairs.py'),\n"
         "        Path(__file__).with_name('run_fp_wide_context_regressions.py'),\n"
         "        Path(__file__).with_name('run_prime_coherence_core.py'))}"),
    ):
        text=replace(text,old,new)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
