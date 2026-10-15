"""Unchanged short cold controls; retry only incomplete process observation.

The failed first run is retained under coremark/. This retry has its own output
directory and requires the same CRCs, ticks, actual CPU affinity and mode.
"""
import hashlib
from pathlib import Path

import native_observation

original = Path(__file__).with_name('run_v_carry_payload_coremark.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '3993be119f225953cc0a94448cd737e898f203ad867fc0358adc6fe71b833a12'
first = '                deadline=time.monotonic()+3\n'
last = '                rc=child.wait(timeout=600)\n'
assert text.count(first) == text.count(last) == 1
text = text[:text.index(first)] + '''                observed=native_observation.observe_owned_native(
                    child,model,argv,env['AO486_BIOS_DIR'],12,parse_cmdline)
                save(work/'native-observed.json',observed)
                save(work/'native.json',observed)
''' + text[text.index(last):]
for old, new in (
    ('ventium-v-carry-cm10-', 'ventium-fetch-fragment-cm10-'),
    ("root=soc/'coremark';root.mkdir()", "root=soc/'coremark-r2';root.mkdir()"),
    ('os.sched_getaffinity(0)=={11}', 'os.sched_getaffinity(0)=={12}'),
    ('for p in (Path(__file__).resolve(),model,',
     'for p in (original,Path(native_observation.__file__),Path(__file__).resolve(),model,')):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
exec(compile(text, str(__file__), 'exec'), globals())
