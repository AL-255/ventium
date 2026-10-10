#!/usr/bin/env python3
"""Factor the already-register-only system prefix admission before its EA guard.

This changes no accepted successor. The legacy profile retains its EA hazard
check. Apply only to the source-qualified system/IF-aware include, in a fresh
private output; never edit an active model's frozen inputs.
"""
import argparse
import hashlib
import json
from pathlib import Path

OLD = '''      // Only EA is captured from precommit registers. Source/destination
      // register operands are deliberately read after the old write edge.
      (!d_mem_read || (d_addr_mask_known && ((d_addr_mask & gpr_we) == 8'd0)));'''
NEW = '''`ifdef VEN_P54_PREFIX_EX_SYSTEM
      // The system profile admits register successors only (also checked at
      // take below). Do not pull current GPR writeback into this decode cone
      // through an EA hazard test that cannot affect an accepted successor.
      !d_mem_read;
`else
''' + OLD + '''
`endif'''


def transform(text):
    if text.count(OLD) != 1 or NEW in text:
        raise ValueError('missing/duplicate/already factored EA guard')
    if text.count('`ifdef VEN_P54_PREFIX_EX_SYSTEM') != 1:
        raise ValueError('expected qualified system prefix profile')
    if '    !d_mem_read && !d_mem_write && !def16 && !smm_active &&' not in text:
        raise ValueError('system register-only admission missing')
    if '!(intr && eflags[9])' not in text:
        raise ValueError('qualified IF-aware interrupt guard missing')
    if text.count('gpr_we') != 1 or text.count('p54_prefix_ex_shape_ok &&') != 2:
        raise ValueError('unexpected additional writeback/shape consumers')
    return text.replace(OLD, NEW)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    if source == out or not out.is_relative_to(scratch):
        raise ValueError('output must be a fresh private external scratch file')
    before = source.read_bytes()
    after = transform(before.decode()).encode()
    with out.open('xb') as stream:
        stream.write(after)
    if source.read_bytes() != before:
        raise ValueError('source changed during preparation')
    print(json.dumps(dict(source=str(source), output=str(out),
        source_sha256=hashlib.sha256(before).hexdigest(),
        output_sha256=hashlib.sha256(after).hexdigest(),
        qualification='UNQUALIFIED', gameplay_ipc=None)))


if __name__ == '__main__':
    main()
