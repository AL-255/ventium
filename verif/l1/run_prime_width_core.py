"""Original eight full-state/clock corpora for the early prime-width payload.

Keep the original requests, goldens, comparison rules and coverage thresholds.
Only source/model identity changes. Historical coverage-count drift is a failure,
not permission to relax the assertion or count a partial corpus as acceptance.
"""
import ast
import hashlib
from pathlib import Path

from build_prime_width_core import MODEL as PARENT
from run_prime_width_func import MODEL as CANDIDATE

HERE = Path(__file__).resolve().parent
BASE = HERE/'run_pair_intent_core.py'
BASE_SHA = 'f2c1ac4ded95937acb51a4543b74c59b2510f2c491b86374be891c7575ef0227'


def derive():
    original = BASE.read_text()
    if hashlib.sha256(original.encode()).hexdigest() != BASE_SHA:
        raise ValueError('original eight-corpus driver drift')
    text = original
    changes = (
        ('"""'+ast.get_docstring(ast.parse(original))+'"""', repr(__doc__)),
        ('import prepare_pair_intent as recipe', 'import prepare_prime_width_payload as recipe'),
        ("PARENT_MODEL = '4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15'",
         'PARENT_MODEL = '+repr(PARENT)),
        ("REPO/'verif/l1/run_mc_address_held.py')}",
         "REPO/'verif/l1/run_mc_address_held.py',BASE,\n"
         "        HERE/'build_prime_width_core.py',HERE/'run_prime_width_func.py')}"),
        ("else: assert started['changes'] == sorted(recipe.PARENTS)",
         """else:
            assert started['changes'] == [recipe.FILE]
            assert closed['binary_sha256'] == """+repr(CANDIDATE)+"""
            assert Path(started['parent']).resolve() == parent
            parent_start = load(parent/'build-started.json')
            assert len(started['definitions']) == 153
            assert started['definitions'] == parent_start['definitions']
            assert recipe.transform((parent/'candidate'/recipe.FILE).read_text()) == (
                candidate/'candidate'/recipe.FILE).read_text()"""),
        ('intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=True)',
         'intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=False,\n'
         '        prime_width_equality_assertion=True)'),
    )
    for old, new in changes:
        if text.count(old) != 1:
            raise ValueError('eight-corpus adapter anchor drift: '+old[:100])
        text = text.replace(old, new)
    recovered = text
    for old, new in reversed(changes):
        assert recovered.count(new) == 1
        recovered = recovered.replace(new, old)
    assert recovered == original
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
