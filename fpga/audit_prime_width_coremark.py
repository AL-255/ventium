"""Independent original CRC/native closure and exact-parent cycle audit."""
from pathlib import Path

import run_prime_width_coremark as runner
import audit_sfetch_interior_coremark as previous

original=previous.original


def derive():
    text=previous.derive()
    old='for p in (Path(previous.__file__),Path(previous.previous.__file__),original,'
    assert text.count(old)==1
    return text.replace(old,'for p in (Path(previous.__file__),Path(previous.previous.__file__),Path(previous.previous.previous.__file__),original,')


if __name__=='__main__':exec(compile(derive(),__file__,'exec'),globals())
