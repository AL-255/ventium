#!/usr/bin/env python3
"""Check scalar-dispatch + m64-queue integration against the pointer-only parent.

Reuse every architectural, exception, operand-owner and pairing assertion of
the ordinary m64 driver. Two explicit differences: both flags are added, and
FWAIT controls may benefit from scalar dispatch, so require nonregression
instead of identical timing. This cannot attribute gains to the queue alone.
"""
import hashlib
from pathlib import Path

BASE = Path(__file__).with_name('run-fp-mem64-queue.py')


def transform(text):
    changes = {
        "assert profiles['candidate'] == profiles['control'] | {'VEN_FP_MEM_QUEUE64'}":
        "assert profiles['candidate'] == profiles['control'] | {'VEN_FP_MEM_QUEUE64', 'VEN_FP_SCALAR_DISPATCH'}\n"
        "    assert 'VEN_FP_SCALAR_DISPATCH' not in profiles['control']",
        'for p in (Path(__file__), source, linker, qemu,':
        'for p in (Path(__file__), BASE, source, linker, qemu,',
        "                if case[1]:\n"
        "                    assert a['total_clocks'] == b['total_clocks'] and a['warm_clocks'] == b['warm_clocks']\n":
        "                # Combined scalar dispatch can accelerate drained controls.\n"
        "                # Whole-program and steady-window nonregression above still apply.\n",
    }
    for old, new in changes.items():
        if text.count(old) != 1:
            raise ValueError('combined runner anchor missing or ambiguous: '+old)
        text = text.replace(old, new)
    return text


if __name__ == '__main__':
    original = BASE.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    try:
        exec(compile(transform(original.decode()), str(BASE), 'exec'),
             {'__file__': __file__, '__name__': '__main__', 'BASE': BASE})
    finally:
        assert hashlib.sha256(BASE.read_bytes()).hexdigest() == digest
