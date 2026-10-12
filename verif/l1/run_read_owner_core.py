"""Preserve the paired-intent whole-core corpus for read-owner ACK absorption.

Only the parent identity and one-file derivative contract change. Native
QEMU/full-state/cycle comparisons and exact pair/next-owner coverage remain.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('run_pair_intent_core.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'f2c1ac4ded95937acb51a4543b74c59b2510f2c491b86374be891c7575ef0227'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import prepare_pair_intent as recipe', 'import prepare_read_owner_ack as recipe')
change("PARENT_MODEL = '4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15'",
       "PARENT_MODEL = 'f3fb3256fb40d9af50d73f2ac80b26bb4f5e27ff4b95d9f279172b4e0c025e41'")
change("else: assert started['changes'] == sorted(recipe.PARENTS)",
       """else:
            assert started['changes'] == ['rtl/mem/ven_l1d.sv']
            assert closed['binary_sha256'] == '3091744d8c87eef66ed5c598d43575a80e2e8de6d0790a478de96fb0b96cb9d2'""")
change("REPO/'verif/l1/run_mc_address_held.py')}",
       "REPO/'verif/l1/run_mc_address_held.py',Path(__file__).with_name('run_pair_intent_core.py'))}")
change('intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=True)',
       'intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=False,original_read_ack_assertion=True)')

exec(compile(text, str(original), 'exec'), globals())
