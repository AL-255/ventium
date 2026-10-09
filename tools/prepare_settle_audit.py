#!/usr/bin/env python3
"""Instrument a frozen TB without weakening its unchanged-input safety guard.

Generated --savable state is a diagnostic, not necessarily every scheduler bit.
No restore, architectural mutation, eval skipping, or trace alteration occurs.
"""
import argparse
import hashlib
import json
from pathlib import Path


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected one frozen harness anchor: {old[:80]!r}")
    return text.replace(old, new)


def instrument(text):
    text = replace_once(text, '#include "model_input_snapshot.h"',
                        '#include "model_input_snapshot.h"\n#include "settle_fixed_point_audit.h"')
    start = text.index('    auto same_clock_settle = [&]() {')
    end = text.index('\n    };', start) + len('\n    };')
    original = text[start:end]
    if '++skipped_settle_evals;' not in original:
        raise ValueError('unexpected settle implementation')
    text = text[:start] + '''    SettleFixedPointAudit settle_audit;
    auto same_clock_settle = [&]() {
        // Diagnostic: unchanged runtime admission, and absolutely NO eval skip.
        settle_audit.eval(*top, !top->eventsPending() && input_snapshot.matches(*top),
                          [&]() { return trace.retired(); });
        ++full_settle_evals;
        input_snapshot.capture(*top);
    };''' + text[end:]
    edge = '''        if (args.skip_unchanged_settle) {
            ++mandatory_edge_evals;
            input_snapshot.capture(*top);
        }'''
    if text.count(edge) != 2:
        raise ValueError('expected two mandatory edge observation sites')
    return text.replace(edge, '''        ++mandatory_edge_evals;
        input_snapshot.capture(*top);''')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.name != 'tb_settle_audit_oct08.cpp':
        parser.error('use the private, model-specific basename tb_settle_audit_oct08.cpp')
    source = args.source.resolve(strict=True)
    original = source.read_text()
    generated = instrument(original)
    guard_start = original.index('    if (args.skip_unchanged_settle) {')
    guard_end = original.index('    // Do this after parsing', guard_start)
    guard = original[guard_start:guard_end]
    assert guard in generated
    with args.output.open('x') as out:
        out.write(generated)
    sha = lambda data: hashlib.sha256(data).hexdigest()
    receipt = dict(source=str(source), source_sha256=sha(source.read_bytes()),
                   output=str(args.output.resolve()), output_sha256=sha(args.output.read_bytes()),
                   admission_guard_unchanged=True, evals_skipped=0,
                   sampling='first 10000 eligible settles, then every 257th')
    with args.output.with_suffix('.json').open('x') as out:
        json.dump(receipt, out, indent=2)
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
