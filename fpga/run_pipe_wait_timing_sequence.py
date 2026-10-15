"""Observe one exact wait-cofactor synthesis, audit it, then report clocks.

No synthesis retry, route or programming. The existing owner, completion and
resource checks are unchanged; an observation deadline never restarts work.
"""
import argparse
from pathlib import Path

import run_demand_size_timing_sequence as previous


def derive(invocation):
    text = previous.derive(invocation)
    text = text.replace('demand-size-', 'pipe-wait-')
    for old, new in (
        ('d35a4b77598c979affbe91bb3e245587e118d0244e271872527b9555115f5315',
         'd655cc8bf1dcea77cc82996c7ebade06387b3da07d7e83a65c84a0ed0a6feefc'),
        ('20cef474c2a10fca2ec27b26f09d88e9b7dc70ead963fab09ce28a6baaa4d60d',
         '55e9255323354c314c102b2e7362ad3f9a5dfb1ca9c4e613a289f379936b6fce'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth-invocation', required=True)
    args = parser.parse_args()
    exec(compile(derive(args.synth_invocation), str(Path(__file__)), 'exec'), globals())
