"""Unchanged eight-corpus state/cycle A/B for register-only branch flags.

Preserve all 4,240 probe checks, real AXI, and the existing QEMU comparisons.
"""
import ast

import run_prime_cs_core as previous
from run_intent_ready_pairs import replace

HERE=previous.HERE
PARENT=previous.CANDIDATE
CANDIDATE='0070aec34169c368f11fb723f33aaeb8f60f0617d9e2f33948e2cd347567c143'


def derive():
    text=previous.derive()
    for old,new in (
        (repr(previous.__doc__),repr(__doc__)),
        ('import prepare_pipe_mem_cs_extent as recipe','import prepare_prime_reg_flags as recipe'),
        ('PARENT_MODEL = '+repr(previous.PARENT),'PARENT_MODEL = '+repr(PARENT)),
        ("assert closed['binary_sha256'] == "+repr(previous.CANDIDATE),
         "assert closed['binary_sha256'] == "+repr(CANDIDATE)),
        ("assert started['changes'] == ['rtl/core/core.sv']",
         "assert started['changes'] == ['rtl/core/core_mem_chain.svh']"),
        ('cs_extent_request_equality_assertion=True',
         'cs_extent_request_equality_assertion=True,reg_branch_flags_commit_equality_assertion=True'),
        ("HERE/'build_prime_cs_core.py')}",
         "HERE/'build_prime_cs_core.py',HERE/'run_prime_cs_core.py',HERE/'build_prime_reg_flags_core.py')}"),
    ):
        text=replace(text,old,new)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
