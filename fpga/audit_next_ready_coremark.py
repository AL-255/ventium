"""Replay the unchanged cold CoreMark CRC/ownership audit for this model."""
from pathlib import Path

import run_next_ready_coremark as runner
import audit_sfetch_boundary_coremark as previous

original = previous.original


def derive():
    text = previous.derive()
    old = 'for p in (original,Path(runner.__file__),'
    assert text.count(old) == 1
    return text.replace(old, 'for p in (Path(previous.__file__),original,Path(runner.__file__),')


if __name__ == '__main__': exec(compile(derive(), __file__, 'exec'), globals())
