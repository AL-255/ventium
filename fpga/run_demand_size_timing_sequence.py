"""Observe an exact synthesis invocation, audit closure, then report clocks.

No synthesis retry, routing, programming or relaxation of completion/resource
checks. The read-only clock stage runs only after the specified synthesis.
"""
import argparse
import hashlib
from pathlib import Path
import re

ORIGINAL = Path(__file__).with_name('run_decode_bus_timing_sequence.py')


def derive(invocation):
    if not re.fullmatch('[0-9a-f]{32}', invocation):
        raise ValueError('exact synthesis invocation required')
    text = ORIGINAL.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == '5b76a2a35164daddae5599c70fbefd7a3974663273d4a8af1473053f45005293'
    text = text.replace('decode-bus-', 'demand-size-')
    for old, new in (
        ('26931169bdb9480fa5bc8264a68a4ed8', invocation),
        ('36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc',
         'd35a4b77598c979affbe91bb3e245587e118d0244e271872527b9555115f5315'),
        ('7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68',
         '20cef474c2a10fca2ec27b26f09d88e9b7dc70ead963fab09ce28a6baaa4d60d'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth-invocation', required=True)
    args = parser.parse_args()
    exec(compile(derive(args.synth_invocation), __file__, 'exec'), globals())
