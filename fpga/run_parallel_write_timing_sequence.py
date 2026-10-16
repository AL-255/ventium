"""Observe the existing synthesis, then its prepared read-only clock audit.

Never retries synthesis, launches implementation or programs the board. The
exact live synthesis uses Type=oneshot; its nonterminal phase is `start`, not
`running`. Require that specific type/state/owner before observing it.
"""
import argparse
import hashlib
from pathlib import Path

import run_raw_prime_storage_timing_sequence as previous
import parallel_write_timing_evidence as evidence


def derive(invocation):
    assert hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest() == \
        'ab370256d5de22a81fe0f4a3f469b47198c7360fc6bf6f5c014783285931a9dd'
    text = previous.derive(invocation)
    for old, new in (
        ('raw-prime-storage-', 'parallel-write-'),
        (previous.evidence.MANIFEST, evidence.MANIFEST),
        (previous.evidence.MODEL, evidence.MODEL),
    ):
        assert old in text
        text = text.replace(old, new)
    old = "'-p', 'MainPID', '-p', 'InvocationID', '-p', 'ExecMainStatus', '-p', 'Result']"
    new = "'-p', 'MainPID', '-p', 'InvocationID', '-p', 'ExecMainStatus', '-p', 'Result',\n" \
          "               '-p', 'Type', '-p', 'ActiveState']"
    assert text.count(old) == 1
    text = text.replace(old, new)
    old = "require(state['SubState'] == 'running', 'unexpected owner phase: ' + repr(state))"
    new = """require(state['SubState'] == 'running' or
                (unit == SYNTH and state['Type'] == 'oneshot' and
                 state['ActiveState'] == 'activating' and state['SubState'] == 'start'),
                'unexpected owner phase: ' + repr(state))"""
    assert text.count(old) == 1
    text = text.replace(old, new)
    compile(text, __file__, 'exec')
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth-invocation', required=True)
    args = parser.parse_args()
    exec(compile(derive(args.synth_invocation), __file__, 'exec'), globals())
