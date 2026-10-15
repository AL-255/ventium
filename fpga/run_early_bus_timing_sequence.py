"""Observe one specified synthesis owner, then run its read-only clock audit.

Identity-only adaptation of the qualified one-shot sequence. No synthesis,
implementation, deployment, retry, or relaxed native-completion criteria.
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
    text = text.replace('decode-bus-', 'early-bus-')
    for old, new in (
        ('26931169bdb9480fa5bc8264a68a4ed8', invocation),
        ('36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc',
         '9ec9a00dc8a73884074f6ea5e01ba9925f3725bc90425693b974d38fc061e5e7'),
        ('7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68',
         '593833e1650b5869373abbd74debcc63d15ea53eca1aa87f62e833982ead2fe9'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth-invocation', required=True)
    args = parser.parse_args()
    exec(compile(derive(args.synth_invocation), __file__, 'exec'), globals())
