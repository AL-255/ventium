"""Transfer the four-file contextual-FP change to the exact PAYLOAD PC parent.

All full-FP/fault/replay and canonical-closure admission remains. Preserve 102
common RTL sources, 156 defines, original transport and private harness audit.
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


change('"""'+ast.get_docstring(ast.parse(text), clean=False)+'"""', repr(__doc__))
change('import prepare_fp_high_valid_cofactor as recipe', 'import prepare_fp_wide_context as recipe')
change("PARENT_MODEL='45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5'",
       "PARENT_MODEL='ac3de53084d2638155c0d10d78827857bae0aae7cc6578f1f35acf769c50b893'")
change("CORE_MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'",
       "CORE_MODEL='0a6bbdb15f7ed7994641ab7ea1934a0d830b5f50d857853e5bbea29140a18e4f'")
change('    for name in CHANGES:\n        assert recipe.transform',
       '    recipe.validate_sources({p:(source/p).read_text() for p in recipe.PARENTS | recipe.OFFER_PINS})\n'
       '    for name in CHANGES:\n        assert recipe.transform')
change("'sim_fp_high_valid_'", "'sim_fp_wide_context_'")
change('Path(recipe.__file__),Path(base.__file__),', 'original,Path(recipe.__file__),Path(base.__file__),')
change('Prepared source-matched FP high-valid PC candidate; compiler not started.',
       'Prepared source-matched FP contextual PC candidate; compiler not started.')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
