"""Observe one exact synthesis invocation, audit closure, then audit clocks.

No synthesis retry, route or programming. This sequence starts only the
prepared read-only report stage after independent successful native closure.
"""
import argparse
from pathlib import Path

import run_pipe_wait_timing_sequence as previous


def derive(invocation):
    text = previous.derive(invocation).replace('pipe-wait-', 'v-result-carry-')
    for old, new, count in (
        ('ventium-v-result-carry-synth-oct15-r1.service',
         'ventium-v-result-carry-synth-oct15-r3.service', 1),
        ('v-result-carry-synthesis-r1/', 'v-result-carry-synthesis-r3/', 2),
        ('d655cc8bf1dcea77cc82996c7ebade06387b3da07d7e83a65c84a0ed0a6feefc',
         '716dab7ee8801e5f865699f2b8619ae881b9d442feb4d59b42399abea758c77e', 1),
        ('55e9255323354c314c102b2e7362ad3f9a5dfb1ca9c4e613a289f379936b6fce',
         'b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e', 1),
        ('v-result-carry-timing-prepared.json', 'v-result-carry-timing-prepared-r3.json', 1),
        ("pins = prepared['outputs']",
         "pins = dict(prepared['outputs'])\n"
         "    pins.update(json.loads((ROOT/'v-result-carry-clock-prepared-r1.json').read_text())['outputs'])", 1),
    ):
        assert text.count(old) == count, old
        text = text.replace(old, new)
    compile(text, str(Path(__file__)), 'exec')
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth-invocation', required=True)
    args = parser.parse_args()
    exec(compile(derive(args.synth_invocation), str(Path(__file__)), 'exec'), globals())
