"""Unchanged eight-corpus A/B for the new-memory CS-extent cofactor.

Preserve complete architectural/cycle equality, real AXI and all 4,240 probe
requirements. This is not a waiver of the still-failed canonical gate.
"""
import ast

import run_prime_coherence_core as previous
from prepare_prime_coherence_cut import CHANGES as PREVIOUS_CHANGES
from run_intent_ready_pairs import replace

HERE=previous.HERE
PARENT=previous.CANDIDATE
CANDIDATE='73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca'


def derive():
    text=previous.derive()
    for old,new in (
        (repr(previous.__doc__),repr(__doc__)),
        ('import prepare_prime_coherence_cut as recipe','import prepare_pipe_mem_cs_extent as recipe'),
        ('PARENT_MODEL = '+repr(previous.PARENT),'PARENT_MODEL = '+repr(PARENT)),
        ("assert closed['binary_sha256'] == "+repr(previous.CANDIDATE),
         "assert closed['binary_sha256'] == "+repr(CANDIDATE)),
        ("assert started['changes'] == "+repr(PREVIOUS_CHANGES),
         "assert started['changes'] == ['rtl/core/core.sv']"),
        ('prime_coherence_equality_assertion=True',
         'prime_coherence_equality_assertion=True,cs_extent_request_equality_assertion=True'),
        ("HERE/'build_prime_coherence_core.py')}",
         "HERE/'build_prime_coherence_core.py',HERE/'run_prime_coherence_core.py',"
         "HERE/'build_prime_cs_core.py')}"),
    ):
        text=replace(text,old,new)
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
