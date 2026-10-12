"""Transfer fresh U/V admission into the unchanged UV-fast full-PC platform.

Retain the guarded build, complete source-closure checks and explicit canonical
failure status. A compiled timing experiment is not a qualified release.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('build_next_pair_cofactor_soc.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '144444cad1130e92107bf2ff001e627a24d2bea31dee59bd618486c009eaea12'
end_doc = text.index('"""', 3) + 3
text = repr(__doc__) + text[end_doc:]


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import prepare_next_pair_cofactor as recipe','import prepare_fresh_pair_capture as recipe')
change("PARENT_MODEL = '87afedaa869e6d8a86f36e31ea7a880875e096b924389ae78e37e65d018ad466'",
       "PARENT_MODEL = 'ab2a70233aebf761de2e81019c16459d86805ac7a2f2b9730bcabcc918534440'")
change("CORE_MODEL = '5b8c134e4e3d4c6856025ce37d0abdf1cd3bfc424baaae837fa393130d3a541a'",
       "CORE_MODEL = 'e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81'")
change('CHANGES = [recipe.PAYLOAD]', "CHANGES = ['rtl/mem/ven_l1d.sv']")
assert text.count('recipe.PAYLOAD') == 4
text = text.replace('recipe.PAYLOAD', 'CHANGES[0]')
change("return recipe.transform(text) + '\\n' + PROBE.read_text()", 'return recipe.transform(text)')
change("done['request_equivalence_assertion']",
       "done['intent_hint_nonoverlap_assertion'] and done['original_fresh_capture_assertion']")
change("'sim_next_pair_'", "'sim_fresh_pair_'")
change('Path(recipe.__file__),PROBE,Path(base.__file__),',
       'Path(recipe.__file__),original,PROBE,Path(base.__file__),')
change('NEXT-PAIR-SOC-PREPARED', 'FRESH-PAIR-SOC-PREPARED')

exec(compile(text, str(Path(__file__)), 'exec'), globals())
