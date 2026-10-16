"""Cold short CoreMark CRC and exact-clock regression, not a valid score."""
from pathlib import Path

import build_next_ready_soc as builder
import run_sfetch_boundary_coremark as previous
import native_observation

original = previous.original
PARENT = builder.leaf.ROOT/'sfetch-boundary-soc-r1'
TICKS = {'performance':4771298, 'validation':4755366}


def cost(seed, ticks):
    assert isinstance(ticks, int) and ticks == TICKS[seed], 'readiness cofactor changed CoreMark clocks'
    return dict(parent_ticks=TICKS[seed], added_clocks=0,
                clock_cost_percent=0.0, throughput_gain_percent=0.0)


def derive():
    text = previous.derive()
    for old, new in (
        ('ventium-sfetch-boundary-cm10-', 'ventium-next-ready-cm10-'),
        ("started['changes']==builder.CHANGES and started['cycle_cost']['diagnostic_only']",
         "started['changes']==builder.CHANGES and not started['canonical_gate_passed']"),
        ('for p in (original,Path(native_observation.__file__),',
         'for p in (Path(previous.__file__),original,Path(native_observation.__file__),'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    compile(text, __file__, 'exec')
    return text


if __name__ == '__main__': exec(compile(derive(), __file__, 'exec'), globals())
