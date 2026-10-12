#!/usr/bin/env python3
"""Transfer the proven query selector onto the measured memory-divide parent.

The closed 29.077375 MHz report traverses the exact late payload selector this
experiment removes. Reuse the reviewed builder/proofs without altering the
earlier prepared candidate, FPGA inputs, guard lifecycle, or feature profile.
This prepares/builds a private core only; it cannot synthesize or deploy.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('build_prime_query_payload_core.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == (
    '2c9dc4d236562fe6b4433266f5896b4625c63c3848c1f8125a531bda71baa18e')
changes = (
    ('exact load-ACK derivative', 'exact memory-divide derivative'),
    ('6d53d0934c9a3c6e7e89d632ccf0d677a0360b4dcb3caeeb917a1f131bd6e6cc',
     'be5375aa32db48600498fc4b2c3a610c7cd99a0fa208c5186e602c44dd9b3d10'),
    ('for path in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),',
     'for path in (Path(__file__).resolve(),'
     "Path(__file__).with_name('build_prime_query_payload_core.py').resolve(),"
     'Path(recipe.__file__).resolve(),'),
)
for before, after in changes:
    assert text.count(before) == 1, before
    text = text.replace(before, after)
exec(compile(text, str(original), 'exec'), globals())
