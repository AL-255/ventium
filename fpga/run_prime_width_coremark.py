"""Parallel cold CRC/cycle controls for prime widths; no valid score claim."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import build_prime_width_soc as builder
import run_sfetch_interior_coremark as previous
import native_observation

original=previous.original
PARENT=previous.PARENT
TICKS=previous.TICKS
cost=previous.cost


def derive():
    text=previous.derive()
    for old,new in (
        ('ventium-sfetch-interior-cm10-','ventium-prime-width-cm10-'),
        ('for p in (Path(previous.__file__),Path(previous.previous.__file__),original,',
         'for p in (Path(previous.__file__),Path(previous.previous.__file__),Path(previous.previous.previous.__file__),original,'),
    ):
        assert text.count(old)==1,old;text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':exec(compile(derive(),__file__,'exec'),globals())
