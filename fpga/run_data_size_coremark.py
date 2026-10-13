"""Use the unchanged short CoreMark controls on CPU12, leaving OS CPUs alone."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('run_v_carry_payload_coremark.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '3993be119f225953cc0a94448cd737e898f203ad867fc0358adc6fe71b833a12'
for before, after in (
    ('ventium-v-carry-cm10-', 'ventium-data-size-cm10-'),
    ('os.sched_getaffinity(0)=={11}', 'os.sched_getaffinity(0)=={12}'),
    ("observed['affinity']==[11]", "observed['affinity']==[12]"),
    ('for p in (Path(__file__).resolve(),model,', 'for p in (original,Path(__file__).resolve(),model,')):
    assert text.count(before) == 1
    text = text.replace(before, after)
exec(compile(text, str(Path(__file__)), 'exec'), globals())
