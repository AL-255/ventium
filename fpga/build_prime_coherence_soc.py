"""Transfer both commit cofactors into the source-matched UV-fast PC model.

Retain the complete prior admission, exact native identities and private C++
header audit. Additionally require the cold REP-SMC/refetch/hint regression.
Canonical failures remain failures; this is only a timing experiment.
"""
import ast
import hashlib
from pathlib import Path

original = Path(__file__).with_name('build_fp_high_valid_soc.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'b108da0a9ca84038e7e40392760f54528485541d99d44e2f7b72621d7d2bb895'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


def admit_smc(core, smc):
    before, closed = load(smc/'started.json'), load(smc/'closed.json')
    checked = load(smc/'audit.json')
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert checked['passed'] and checked['pins_unchanged']
    assert len(checked['rows']) == 24 and checked['stale_decode_negative_controls'] == 24
    assert all(r['fresh_rep_decodes'] == 2 for r in checked['rows'])
    assert before['models']['candidate'] == str(core/'obj/tb_ventium')
    pins = dict(checked['pins'])
    assert stable(pins)
    for name in ('started.json', 'closed.json', 'audit.json'):
        pins[str(smc/name)] = sha(smc/name)
    return pins


change('"""'+ast.get_docstring(ast.parse(text), clean=False)+'"""', repr(__doc__))
change('import prepare_fp_high_valid_cofactor as recipe', 'import prepare_prime_coherence_transfer as recipe')
change("PARENT_MODEL='45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5'",
       "PARENT_MODEL='0a91843cf2f9a5f050db8ab5358d4e43f24b704aacb5dd165c1e39e17d73183b'")
change("CORE_MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'",
       "CORE_MODEL='ea3cde2721fd7af43bd4efdeaf8cbe154b803ff74a989a5660588233966b9c6b'")
change('CHANGES=sorted(recipe.PARENTS)', 'CHANGES=sorted(recipe.CHILDREN)')
change('def prepare(parent,core,proof,fp,root):', 'def prepare(parent,core,proof,fp,smc,root):')
change("before['changes']==CHANGES", "before['changes']==recipe.hint.CHANGES")
change('    pins,stats=regressions(core,proof,fp)',
       '    pins,stats=regressions(core,proof,fp)\n    pins.update(admit_smc(core,smc))')
change('    for name in CHANGES:\n        assert recipe.transform',
       '    recipe.validate_sources({p:(source/p).read_text() for p in recipe.PARENTS})\n'
       '    for name in CHANGES:\n        assert recipe.transform')
change("'sim_fp_high_valid_'", "'sim_prime_coherence_'")
change('Path(recipe.__file__),Path(base.__file__),',
       'original,Path(recipe.__file__),Path(recipe.local.__file__),Path(recipe.hint.__file__),Path(base.__file__),')
change("for name in ('parent','core','proof','fp'):", "for name in ('parent','core','proof','fp','smc'):")
change('assert all((args.parent,args.core,args.proof,args.fp))',
       'assert all((args.parent,args.core,args.proof,args.fp,args.smc))')
change("for n in ('parent','core','proof','fp')),root)",
       "for n in ('parent','core','proof','fp','smc')),root)")
change('Prepared source-matched FP high-valid PC candidate; compiler not started.',
       'Prepared source-matched commit-cofactor PC candidate; compiler not started.')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
