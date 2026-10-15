"""Fresh short cold-PC CRC controls for the four-file composition.

No duration-valid score or full-seed correctness claim is made by these runs.
"""
from pathlib import Path

previous_driver = Path(__file__).with_name('run_pair_next_disjoint_coremark.py')
text = previous_driver.read_text()
old, new = 'ventium-pair-next-disjoint-cm10-', 'ventium-fetch-pair-next-cm10-'
assert text.count(old) == 1
text = text.replace(old, new)
old = "'original,original_driver,Path(native_observation.__file__),Path(__file__).resolve(),model,'"
new = "'original,original_driver,previous_driver,Path(native_observation.__file__),Path(__file__).resolve(),model,'"
assert text.count(old) == 1
text = text.replace(old, new)
exec(compile(text, str(__file__), 'exec'), globals())
