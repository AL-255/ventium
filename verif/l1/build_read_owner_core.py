"""Source-matched read-owner ACK core build using the qualified private harness."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('build_fp_high_valid_core.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '8decde5e455fd686dbdc0079489bd5ccd4eb12cbc82f573d2a170884e3907448'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import prepare_fp_high_valid_cofactor as recipe',
       'import prepare_read_owner_ack as recipe')
change('import run_fp_high_valid_cache as cache_gate',
       'import run_read_owner_cache as cache_gate')
change("changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}",
       "changes={'rtl/mem/ven_l1d.sv':recipe.transform((source/'rtl/mem/ven_l1d.sv').read_text())}")
assert text.count('sorted(recipe.PARENTS)') == 2
text = text.replace('sorted(recipe.PARENTS)', "['rtl/mem/ven_l1d.sv']")
change("for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),",
       "for p in (Path(__file__).resolve(),Path(__file__).with_name('build_fp_high_valid_core.py'),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),")
change("host=root/('tb_fp_high_valid_'", "host=root/('tb_read_owner_'")
change('FP-HIGH-VALID-CORE-PREPARED ', 'READ-OWNER-CORE-PREPARED ')

exec(compile(text, str(original), 'exec'), globals())
