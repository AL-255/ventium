"""Transfer the current-owner ACK into the same UV-fast full-PC platform.

Retain the native guarded build, source-closure/header checks and canonical
failure status. This prepares a timing experiment, not a qualified release.
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


change('import prepare_next_pair_cofactor as recipe', 'import prepare_read_owner_ack as recipe')
change("PARENT_MODEL = '87afedaa869e6d8a86f36e31ea7a880875e096b924389ae78e37e65d018ad466'",
       "PARENT_MODEL = 'a02884bdd6f12dd6090ac0207d26f6aa1363c5aa2647448ca21d28ed8fea8d1e'")
change("CORE_MODEL = '5b8c134e4e3d4c6856025ce37d0abdf1cd3bfc424baaae837fa393130d3a541a'",
       "CORE_MODEL = '3091744d8c87eef66ed5c598d43575a80e2e8de6d0790a478de96fb0b96cb9d2'")
change('CHANGES = [recipe.PAYLOAD]', "CHANGES = ['rtl/mem/ven_l1d.sv']")
assert text.count('recipe.PAYLOAD') == 4
text = text.replace('recipe.PAYLOAD', 'CHANGES[0]')
change("return recipe.transform(text) + '\\n' + PROBE.read_text()", 'return recipe.transform(text)')
change("done['request_equivalence_assertion']",
       "done['intent_hint_nonoverlap_assertion'] and done['original_read_ack_assertion']")
change("'sim_next_pair_'", "'sim_read_owner_'")
change('Path(recipe.__file__),PROBE,Path(base.__file__),',
       'Path(recipe.__file__),original,PROBE,Path(base.__file__),')
change('NEXT-PAIR-SOC-PREPARED', 'READ-OWNER-SOC-PREPARED')

exec(compile(text, str(Path(__file__)), 'exec'), globals())
