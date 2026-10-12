"""Carry the tested intent arbiter into the unchanged FPGA-matched PC model.

Reuse the closed transfer/build lifecycle, retaining exact source/profile checks
and the red canonical gate. Four hardware files plus the simulation-only probe
include differ from BACKING-PAYLOAD. No compiler starts during preparation.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('build_next_pair_cofactor_soc.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '144444cad1130e92107bf2ff001e627a24d2bea31dee59bd618486c009eaea12'
end_doc = text.index('"""',3)+3
text = repr(__doc__)+text[end_doc:]


def change(old,new):
    global text
    assert text.count(old) == 1,old
    text = text.replace(old,new)


change('import prepare_next_pair_cofactor as recipe',
       'import prepare_pair_intent as recipe\nimport build_next_pair_probe as probe')
change("CORE_MODEL = '5b8c134e4e3d4c6856025ce37d0abdf1cd3bfc424baaae837fa393130d3a541a'",
       "CORE_MODEL = 'f3fb3256fb40d9af50d73f2ac80b26bb4f5e27ff4b95d9f279172b4e0c025e41'")
change('CHANGES = [recipe.PAYLOAD]',"CHANGES = sorted([*recipe.PARENTS,probe.PAYLOAD])")
change('''    assert name == recipe.PAYLOAD
    return recipe.transform(text) + '\\n' + PROBE.read_text()''',
       '''    return probe.transform(text) if name == probe.PAYLOAD else recipe.transform(text,name)''')
change("done['request_equivalence_assertion']","done['intent_hint_nonoverlap_assertion']")
change("before['changes'] == CHANGES","before['changes'] == sorted(recipe.PARENTS)")
change("    assert transformed((source/recipe.PAYLOAD).read_text(),recipe.PAYLOAD) == (core/'candidate'/recipe.PAYLOAD).read_text()",
       "    assert all(transformed((source/name).read_text(),name) == (core/'candidate'/name).read_text() for name in CHANGES)")
change("'sim_next_pair_'","'sim_pair_intent_'")
change('Path(recipe.__file__),PROBE,Path(base.__file__),',
       'Path(recipe.__file__),Path(probe.__file__),original,PROBE,Path(base.__file__),')
change('NEXT-PAIR-SOC-PREPARED','PAIR-INTENT-SOC-PREPARED')
exec(compile(text,str(Path(__file__)),'exec'),globals())
