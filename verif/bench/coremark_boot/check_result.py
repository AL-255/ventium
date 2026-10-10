#!/usr/bin/env python3
"""Check one completed console result; never infer silicon qualification."""
import re

DURATION_ERROR = 'ERROR! Must execute for at least 10 secs for a valid result!'
FIELDS = ('seedcrc', 'crclist', 'crcmatrix', 'crcstate', 'crcfinal')


def one(pattern, text):
    matches = re.findall(pattern, text, re.M)
    if len(matches) != 1:
        raise ValueError(f'expected one result for {pattern}: {matches!r}')
    return matches[0]


def check(text, *, reference_crcs, iterations, require_valid_duration):
    """reference_crcs must come from the SAME seed/iteration QEMU run.

    QEMU contributes CRCs only, never a timing reference. Console may be QEMU
    E9 output or ONE decoded VGA screen with its `  |` prefixes removed.
    Native closure, build/mode, clock and source audits remain caller duties.
    """
    if len(reference_crcs) != 5 or iterations <= 0:
        raise ValueError('require all five reference CRCs and positive iterations')
    if int(one(r'^Iterations\s*:\s*(\d+)$', text)) != iterations:
        raise ValueError('iteration count differs')
    if one(r'^CoreMark Size\s*:\s*(\d+)$', text) != '666':
        raise ValueError('not the standard 2K data set')
    crcs = [one(r'^(?:\[0\])?' + field + r'\s*:\s*0x([0-9a-f]{4})$', text)
            for field in FIELDS]
    if crcs != list(reference_crcs):
        raise ValueError(f'CRC mismatch: {crcs}')
    ticks = int(one(r'^Total ticks\s*:\s*(\d+)$', text))
    a, b, c, d = one(r'^PORT-TSC start=([0-9a-f]{8}):([0-9a-f]{8}) '
                     r'stop=([0-9a-f]{8}):([0-9a-f]{8})$', text)
    begin, end = int(a+b, 16), int(c+d, 16)
    hi, lo = one(r'^PORT-TSC delta=([0-9a-f]{8}):([0-9a-f]{8})$', text)
    elapsed = (end-begin) % (1 << 64)
    if not 0 < elapsed < (1 << 32) or elapsed != int(hi+lo, 16) or elapsed != ticks:
        raise ValueError('TSC/total-ticks mismatch or unsupported tick width')
    seconds = int(one(r'^Total time \(secs\):\s*(\d+)$', text))
    if seconds != elapsed // 40000000:
        raise ValueError('40MHz calibration mismatch')
    one(r'^PORT-END$', text)
    errors = re.findall(r'^ERROR.*$', text, re.M)
    validated = 'Correct operation validated.' in text
    if require_valid_duration:
        if errors or seconds < 10 or not validated or 'Errors detected' in text:
            raise ValueError('not a duration-valid correctness result')
    elif errors != [DURATION_ERROR] or seconds >= 10 or validated or text.count('Errors detected') != 1:
        raise ValueError('expected ONLY the explicit short-duration failure')
    return dict(crcs=crcs,iterations=iterations,ticks=elapsed,
                diagnostic_ratio=iterations*1000000/elapsed,
                duration_valid=require_valid_duration,
                physical_board_qualified=False,standard_suite=False)
