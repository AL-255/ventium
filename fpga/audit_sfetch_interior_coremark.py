"""Regrade unchanged CRCs and zero cycle delta with per-seed native affinity."""
from pathlib import Path

import run_sfetch_interior_coremark as runner
import audit_next_ready_coremark as previous

original=previous.original


def derive():
    text=previous.derive()
    old="native['affinity'] == [12]"
    assert text.count(old)==1
    text=text.replace(old,"native['affinity'] == [12 if seed=='performance' else 13]")
    old='for p in (Path(previous.__file__),original,'
    assert text.count(old)==1
    return text.replace(old,'for p in (Path(previous.__file__),Path(previous.previous.__file__),original,')


if __name__=='__main__':exec(compile(derive(),__file__,'exec'),globals())
