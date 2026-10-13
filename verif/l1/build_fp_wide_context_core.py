"""Build the four-file FP contextual-valid derivative after leaf/proof/cache tests.

Preserve the complete 195-file parent closure, 152-define UV-fast profile,
32-job guarded build and unique C++ harness/header audit. Not acceptance.
"""
import ast
import hashlib
from pathlib import Path

from run_intent_ready_pairs import replace

HERE = Path(__file__).resolve().parent
BASE_SHA = '8decde5e455fd686dbdc0079489bd5ccd4eb12cbc82f573d2a170884e3907448'


def derive():
    text = (HERE/'build_fp_high_valid_core.py').read_text()
    if hashlib.sha256(text.encode()).hexdigest() != BASE_SHA:
        raise ValueError('FP contextual core build lifecycle drift')
    def change(old, new):
        nonlocal text
        text = replace(text, old, new)
    change('"""'+ast.get_docstring(ast.parse(text))+'"""', repr(__doc__))
    change('import prepare_fp_high_valid_cofactor as recipe', 'import prepare_fp_wide_context as recipe')
    change('import run_fp_high_valid_cache as cache_gate', 'import run_fp_wide_context_cache as cache_gate')
    change("        'PARALLEL-CACHE-MITER checks=737677 next=414']", """        'PARALLEL-CACHE-MITER checks=747037 next=463']
    log=(cache/'positive/run.log').read_text()
    assert log.count('FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4')==1
    counts=re.findall(r'FP-WIDE-CACHE-OK checks=(\\d+) high=(\\d+) different=(\\d+)',log)
    assert len(counts)==1 and all(int(n)>0 for n in counts[0])
    assert not checked['whole_core'] and not checked['standard_suite']
    assert not checked['hardware_acceptance']""")
    change('    changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}',
           """    assert len(recipe.PARENTS)==4 and len(recipe.OFFER_PINS)==3
    recipe.validate_sources({p:(source/p).read_text() for p in recipe.PARENTS | recipe.OFFER_PINS})
    changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}""")
    change('for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),',
           "for p in (Path(__file__).resolve(),HERE/'build_fp_high_valid_core.py',\n"
           "              HERE/'run_intent_ready_pairs.py',Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),")
    change("host=root/('tb_fp_high_valid_'", "host=root/('tb_fp_wide_context_'")
    change('FP-HIGH-VALID-CORE-PREPARED ', 'FP-WIDE-CONTEXT-CORE-PREPARED ')
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
