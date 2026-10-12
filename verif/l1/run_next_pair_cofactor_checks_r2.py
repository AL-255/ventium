"""Retry the same cofactor checks after isolating held-corpus GDB ports."""
from pathlib import Path

import run_next_pair_cofactor_checks as previous

text = previous.text
old = "('held','verif/l1/run_mc_address_held.py',[],120)"
assert text.count(old) == 1
text = text.replace(old,"('held','verif/l1/run_next_pair_held.py',[],120)")
anchor = "    inherited = Path(__file__).with_name('run_next_pair_probe.py')"
assert text.count(anchor) == 1
text = text.replace(anchor,"""    for name in ('run_next_pair_cofactor_checks.py','run_mc_address_held.py'):
        source = Path(__file__).with_name(name)
        pins[str(source)] = sha(source)
"""+anchor)
exec(compile(text,str(Path(__file__)),'exec'),globals())
