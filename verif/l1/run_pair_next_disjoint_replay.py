"""Full same-input replay for the narrower pair/next cofactor.

No masks, golden changes, or cycle tolerances; this reuses authenticated
inputs, not a new canonical-QEMU qualification.
"""
import ast
import hashlib
from pathlib import Path

import run_current_u_pair_replay as prior


def derive():
    text = prior.derive()
    for old,new in (
        ('current-u-pair-replay-r1','pair-next-disjoint-replay-r1'),
        ('current-u-pair-core-r1','pair-next-disjoint-core-r1'),
        ('10864ce701d4c90d5b8b16e3dd470a7eedc7e565450e2eef3b3f18784b5732b9',
         '9beb7023ddfd56888fe6eac6b12ed2feebdbcb7fc367748a989fcb2b63292516'),
    ):
        assert text.count(old)==1,old
        text=text.replace(old,new)
    anchor="    pins = dict(started['pins'])"
    path=Path(prior.__file__).resolve()
    assert text.count(anchor)==1
    text=text.replace(anchor,anchor+f'\n    pins[{str(path)!r}]={hashlib.sha256(path.read_bytes()).hexdigest()!r}')
    ast.parse(text)
    return text


if __name__ == '__main__': exec(compile(derive(),str(__file__),'exec'),globals())
