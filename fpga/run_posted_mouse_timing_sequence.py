"""Audit one corrected-wrapper synthesis and then its read-only timing stage.

Never retries synthesis or launches implementation/deployment. The tested,
hash-pinned sequencer supplies the unchanged process lifetime and failure path.
"""
import argparse
import hashlib
from pathlib import Path
import re


def derive(invocation):
    if not re.fullmatch('[0-9a-f]{32}', invocation):
        raise ValueError('exact synthesis invocation required')
    original = Path(__file__).with_name('run_decode_bus_timing_sequence.py')
    text = original.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == '5b76a2a35164daddae5599c70fbefd7a3974663273d4a8af1473053f45005293'
    text = text.replace('decode-bus-', 'posted-mouse-')
    for before, after, count in (
        ('26931169bdb9480fa5bc8264a68a4ed8', invocation, 1),
        ('36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc',
         'ab1c791f3f472ec72a0c36628291d3c6d2e78a6a4a1b449a71a06840800ba8e0', 1),
        ('7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68',
         'b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e', 1),
        ('oct15-r1.service', 'oct16-r1.service', 3),
        ('posted-mouse-timing-prepared.json', 'posted-mouse-timing-prepared-r1.json', 1),
    ):
        assert text.count(before) == count, before
        text = text.replace(before, after)
    compile(text, str(Path(__file__)), 'exec')
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth-invocation', required=True)
    args = parser.parse_args()
    exec(compile(derive(args.synth_invocation), str(Path(__file__)), 'exec'), globals())
