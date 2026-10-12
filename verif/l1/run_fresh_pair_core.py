"""Retain the eight UV-fast full-state/cycle corpora for fresh pair capture."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('run_pair_intent_core.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'f2c1ac4ded95937acb51a4543b74c59b2510f2c491b86374be891c7575ef0227'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import prepare_pair_intent as recipe','import prepare_fresh_pair_capture as recipe')
change("PARENT_MODEL = '4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15'",
       "PARENT_MODEL = '3091744d8c87eef66ed5c598d43575a80e2e8de6d0790a478de96fb0b96cb9d2'")
change("else: assert started['changes'] == sorted(recipe.PARENTS)",
       """else:
            assert started['changes'] == ['rtl/mem/ven_l1d.sv']
            assert closed['binary_sha256'] == 'e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81'""")
change("REPO/'verif/l1/run_mc_address_held.py')}",
       "REPO/'verif/l1/run_mc_address_held.py',Path(__file__).with_name('run_pair_intent_core.py'))}")
change('intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=True)',
       'intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=False,original_fresh_capture_assertion=True)')

exec(compile(text, str(original), 'exec'), globals())
