"""Unchanged short cold controls for the backing payload-mux PC model.

Ten iterations per seed: a CRC/cycle regression check, not a duration-valid
CoreMark score or the complete standard correctness suite.
"""
from pathlib import Path

previous_driver = Path(__file__).with_name('run_pair_next_disjoint_coremark.py')
text = previous_driver.read_text()
old, new = 'ventium-pair-next-disjoint-cm10-', 'ventium-backing-payload-mux-cm10-'
assert text.count(old) == 1
text = text.replace(old, new, 1)
old = "'original,original_driver,Path(native_observation.__file__),Path(__file__).resolve(),model,'"
new = "'original,original_driver,previous_driver,Path(native_observation.__file__),Path(__file__).resolve(),model,'"
assert text.count(old) == 1
text = text.replace(old, new, 1)
exec(compile(text, str(__file__), 'exec'), globals())
