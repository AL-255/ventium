"""Eight unchanged architectural/cycle corpora for the intent-ready core cut.

Exact parent and candidate models, actual AXI and paired-path witnesses; no
timing-band, architectural-state or failure waiver. Not standard-suite or
FPGA acceptance.
"""
import ast
import hashlib
from pathlib import Path

from run_intent_ready_pairs import replace

HERE=Path(__file__).resolve().parent
BASE_SHA='f2c1ac4ded95937acb51a4543b74c59b2510f2c491b86374be891c7575ef0227'
PARENT='e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81'
CANDIDATE='6fa8f7ad89e4f84a3c484a5e8c81d933e9bda429ca6c7019bd5e2c63d3ce1b5e'


def derive():
    text=(HERE/'run_pair_intent_core.py').read_text()
    if hashlib.sha256(text.encode()).hexdigest()!=BASE_SHA:
        raise ValueError('intent-ready core regression lifecycle drift')
    def change(old,new):
        nonlocal text
        text=replace(text,old,new)
    change('"""'+ast.get_docstring(ast.parse(text))+'"""',repr(__doc__))
    change('import prepare_pair_intent as recipe','import prepare_intent_ready_cut as recipe')
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
           '        intent_qualified_readiness_assertion=True)')
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
