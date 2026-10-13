"""Unchanged FP-boundary/fault/integer/memory/replay gates for the CS cofactor.

Parent equality does not waive the explicitly retained canonical failures.
"""
import ast
from pathlib import Path

import run_prime_coherence_regressions as previous
from run_intent_ready_pairs import replace
from run_prime_cs_core import PARENT, CANDIDATE

original = previous.original


def derive():
    text = previous.derive()
    for old, new in (
        (repr(previous.__doc__), repr(__doc__)),
        ('PARENT_MODEL = '+repr(previous.PARENT), 'PARENT_MODEL = '+repr(PARENT)),
        ('\nMODEL = '+repr(previous.CANDIDATE), '\nMODEL = '+repr(CANDIDATE)),
        ("Path(__file__).with_name('run_prime_coherence_core.py'))}",
         "Path(__file__).with_name('run_prime_coherence_core.py'),\n"
         "        Path(__file__).with_name('run_prime_coherence_regressions.py'),\n"
         "        Path(__file__).with_name('run_prime_cs_core.py'))}"),
    ):
        text = replace(text, old, new)
    ast.parse(text)
    return text


if __name__ == '__main__': exec(compile(derive(), str(__file__), 'exec'), globals())
