"""Build the fresh-U predicate derivative with the full UV-fast core profile."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('build_fp_high_valid_core.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '8decde5e455fd686dbdc0079489bd5ccd4eb12cbc82f573d2a170884e3907448'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import prepare_fp_high_valid_cofactor as recipe','import prepare_fresh_pair_capture as recipe')
change('import run_fp_high_valid_cache as cache_gate','import run_fresh_pair_cache as cache_gate')
change("changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}",
       "changes={'rtl/mem/ven_l1d.sv':recipe.transform((source/'rtl/mem/ven_l1d.sv').read_text())}")
assert text.count('sorted(recipe.PARENTS)') == 2
text = text.replace('sorted(recipe.PARENTS)', "['rtl/mem/ven_l1d.sv']")
change("    assert checked['rows'][0]['coverage']==[\n        'HIGH-WINDOW-PAYLOAD-OK valid=66339 shadow=42254 primary=24085 duplicate=25 blocked=152',\n        'PARALLEL-CACHE-MITER checks=737677 next=414']",
       """    coverage=checked['rows'][0]['coverage']
    assert len(coverage)==2 and coverage[0]=='HIGH-WINDOW-PAYLOAD-OK valid=66339 shadow=42254 primary=24085 duplicate=25 blocked=152'
    counts=re.fullmatch(r'PARALLEL-CACHE-MITER checks=(\\d+) next=(\\d+)',coverage[1])
    assert counts and int(counts[1])>737677 and int(counts[2])>=414
    assert (cache/'positive/run.log').read_text().count(
        'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4')==1""")
change("for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),",
       "for p in (Path(__file__).resolve(),Path(__file__).with_name('build_fp_high_valid_core.py'),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),")
change("host=root/('tb_fp_high_valid_'", "host=root/('tb_fresh_pair_'")
change('FP-HIGH-VALID-CORE-PREPARED ', 'FRESH-PAIR-CORE-PREPARED ')

exec(compile(text, str(original), 'exec'), globals())
