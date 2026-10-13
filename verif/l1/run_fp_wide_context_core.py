"""Unchanged eight-corpus UV-fast AXI A/B for the FP-only wide-valid change.

Require exact candidate identity, complete architectural/cycle equality and
the original next-port/pair coverage. Does not waive the canonical failures.
"""
import ast

import run_payload_region_core as previous
from run_intent_ready_pairs import replace

HERE = previous.HERE
PARENT = previous.CANDIDATE
CANDIDATE = '0a6bbdb15f7ed7994641ab7ea1934a0d830b5f50d857853e5bbea29140a18e4f'


def derive():
    text = previous.derive()
    for old, new in (
        (repr(previous.__doc__), repr(__doc__)),
        ('import prepare_payload_region_hint as recipe', 'import prepare_fp_wide_context as recipe'),
        ('PARENT_MODEL = '+repr(previous.PARENT), 'PARENT_MODEL = '+repr(PARENT)),
        ("assert closed['binary_sha256'] == "+repr(previous.CANDIDATE),
         "assert closed['binary_sha256'] == "+repr(CANDIDATE)),
        ('payload_region_equality_assertion=True', 'fp_wide_context_equality_assertion=True'),
        ("HERE/'run_intent_ready_pairs.py')}",
         "HERE/'run_intent_ready_pairs.py',HERE/'run_payload_region_core.py')}"),
    ):
        text = replace(text, old, new)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
