"""Eight unchanged architectural/cycle corpora for the payload-region cut.

Use exact model identities and real AXI; retain full-state comparisons and
paired-path coverage. No canonical, standard-suite or timing pass is inferred.
"""
import ast
import hashlib
from pathlib import Path

from run_intent_ready_pairs import replace

HERE=Path(__file__).resolve().parent
BASE_SHA='f2c1ac4ded95937acb51a4543b74c59b2510f2c491b86374be891c7575ef0227'
PARENT='6fa8f7ad89e4f84a3c484a5e8c81d933e9bda429ca6c7019bd5e2c63d3ce1b5e'
CANDIDATE='3a91aa88841f949855d27e0ed500064854ad9b24390c318629054de858061164'


def derive():
    text=(HERE/'run_pair_intent_core.py').read_text()
    if hashlib.sha256(text.encode()).hexdigest()!=BASE_SHA:
        raise ValueError('payload-region core regression lifecycle drift')
    def change(old,new):
        nonlocal text
        text=replace(text,old,new)
    change('"""'+ast.get_docstring(ast.parse(text))+'"""',repr(__doc__))
    change('import prepare_pair_intent as recipe','import prepare_payload_region_hint as recipe')
    change("PARENT_MODEL = '4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15'",
           'PARENT_MODEL = '+repr(PARENT))
    change("else: assert started['changes'] == sorted(recipe.PARENTS)",
           """else:
            assert started['changes'] == sorted(recipe.PARENTS)
            assert closed['binary_sha256'] == """+repr(CANDIDATE))
    change("REPO/'verif/l1/run_mc_address_held.py')}",
           "REPO/'verif/l1/run_mc_address_held.py',HERE/'run_pair_intent_core.py',\n"
           "        HERE/'run_intent_ready_pairs.py')}")
    change('intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=True)',
           'intent_hint_nonoverlap_assertion=True,arbitration_interface_changed=False,\n'
           '        payload_region_equality_assertion=True)')
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
