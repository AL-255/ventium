"""Unchanged full FP-boundary/fault/memory/replay qualification for flag cofactor.

Preserve every native checker and the failed canonical status. This is not a
standard-suite, timing, or physical FPGA acceptance claim.
"""
import ast

import run_prime_cs_regressions as previous
from run_intent_ready_pairs import replace
from run_prime_reg_flags_core import PARENT,CANDIDATE

original=previous.original


def derive():
    text=previous.derive()
    for old,new in (
        (repr(previous.__doc__),repr(__doc__)),
        ('PARENT_MODEL = '+repr(previous.PARENT),'PARENT_MODEL = '+repr(PARENT)),
        ('\nMODEL = '+repr(previous.CANDIDATE),'\nMODEL = '+repr(CANDIDATE)),
        ("Path(__file__).with_name('run_prime_cs_core.py'))}",
         "Path(__file__).with_name('run_prime_cs_core.py'),\n"
         "        Path(__file__).with_name('run_prime_cs_regressions.py'),\n"
         "        Path(__file__).with_name('run_prime_reg_flags_core.py'))}"),
    ):
        text=replace(text,old,new)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
