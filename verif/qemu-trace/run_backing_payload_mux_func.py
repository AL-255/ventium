"""Fresh qualified-private-reference corpus for the backing payload mux.

Same 108 programs, comparison masks, worker, AXI waits and CPU assignment as
the preceding fresh run. Canonical verification remains a separate owner.
"""
import ast
import hashlib
from pathlib import Path

import run_fetch_pair_next_func as prior

BASE=prior.BASE
REPO=prior.REPO
MODEL='7c88579767354f269055420cafe3acca089acda87e5ac174b633b3e7905dcdb5'


def derive():
    text=prior.derive()
    assert text.count(prior.MODEL)==1
    text=text.replace(prior.MODEL,MODEL)
    anchor='    assert all(sha(p)==h for p,h in pins.items())\n'
    assert text.count(anchor)==1
    path=Path(prior.__file__).resolve()
    text=text.replace(anchor,f'    pins[{str(path)!r}]={hashlib.sha256(path.read_bytes()).hexdigest()!r}\n'+anchor)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
