"""Unchanged full-state/clock eight-corpus A/B for local successor commit.

Keep real AXI, UV-fast, all original fixtures and coverage counts. This
comparison is not canonical correctness, timing or FPGA acceptance.
"""
import ast

import run_fp_wide_context_core as previous
from run_intent_ready_pairs import replace

HERE = previous.HERE
PARENT = previous.CANDIDATE
CANDIDATE = '2c54f961e87147003dd75909a361f1f9213f6453bbe6f1bce8ed512cb3fa94e4'


def derive():
    text = previous.derive()
    for old, new in (
        (repr(previous.__doc__), repr(__doc__)),
        ('import prepare_fp_wide_context as recipe', 'import prepare_mc_local_commit as recipe'),
        ('PARENT_MODEL = '+repr(previous.PARENT), 'PARENT_MODEL = '+repr(PARENT)),
        ("assert closed['binary_sha256'] == "+repr(previous.CANDIDATE),
         "assert closed['binary_sha256'] == "+repr(CANDIDATE)),
        ("assert started['changes'] == sorted(recipe.PARENTS)",
         "assert started['changes'] == ['rtl/core/core_mem_chain.svh']"),
        ('fp_wide_context_equality_assertion=True', 'mc_local_commit_equality_assertion=True'),
        ("HERE/'run_payload_region_core.py')}",
         "HERE/'run_payload_region_core.py',HERE/'run_fp_wide_context_core.py',"
         "HERE/'build_mc_local_core.py')}"),
    ):
        text = replace(text, old, new)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
