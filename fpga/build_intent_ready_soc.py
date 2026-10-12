"""Transfer only tested intent-ready L1/seam changes into the full PC model.

Retain all 102 shared RTL inputs, 156 defines, private harness and guarded
native build. Full FP/fault/replay results are required; canonical debt remains
explicit. This is an unqualified timing experiment, not a release.
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
change('import prepare_fp_high_valid_cofactor as recipe', 'import prepare_intent_ready_cut as recipe')
change("PARENT_MODEL='45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5'",
       "PARENT_MODEL='bb5a251dd9e5e21c54450dad145993007921f0482f7edf778a10a9c16be9eb20'")
change("CORE_MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'",
       "CORE_MODEL='6fa8f7ad89e4f84a3c484a5e8c81d933e9bda429ca6c7019bd5e2c63d3ce1b5e'")
change("'sim_fp_high_valid_'", "'sim_intent_ready_'")
change('Path(recipe.__file__),Path(base.__file__),', 'original,Path(recipe.__file__),Path(base.__file__),')
change('Prepared source-matched FP high-valid PC candidate; compiler not started.',
       'Prepared source-matched intent-ready PC candidate; compiler not started.')

exec(compile(text, str(Path(__file__)), 'exec'), globals())
