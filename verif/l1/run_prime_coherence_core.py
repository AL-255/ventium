"""Unchanged eight-corpus A/B for no-memory prime coherence.

Retain complete architectural/cycle comparisons, real AXI and all original
coverage requirements. Canonical failures are not waived by parent equality.
"""
import ast

import run_mc_local_core as previous
from prepare_prime_coherence_cut import CHANGES
from run_intent_ready_pairs import replace

HERE=previous.HERE
PARENT=previous.CANDIDATE
CANDIDATE='ea3cde2721fd7af43bd4efdeaf8cbe154b803ff74a989a5660588233966b9c6b'


def derive():
    text=previous.derive()
    for old,new in (
        (repr(previous.__doc__),repr(__doc__)),
        ('import prepare_mc_local_commit as recipe','import prepare_prime_coherence_cut as recipe'),
        ('PARENT_MODEL = '+repr(previous.PARENT),'PARENT_MODEL = '+repr(PARENT)),
        ("assert closed['binary_sha256'] == "+repr(previous.CANDIDATE),
         "assert closed['binary_sha256'] == "+repr(CANDIDATE)),
        ("assert started['changes'] == ['rtl/core/core_mem_chain.svh']",
         "assert started['changes'] == "+repr(CHANGES)),
        ('mc_local_commit_equality_assertion=True','prime_coherence_equality_assertion=True'),
        ("HERE/'build_mc_local_core.py')}",
         "HERE/'build_mc_local_core.py',HERE/'run_mc_local_core.py',HERE/'build_prime_coherence_core.py')}"),
    ):
        text=replace(text,old,new)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
