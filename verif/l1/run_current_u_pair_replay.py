"""Complete 108-program replay on retained authenticated input states.

Both parent and candidate rerun the same images/initial ESP. Every functional
record and clock count must match the retained qualified run; no new masks or
goldens. This is explicitly a replay, not a fresh-QEMU or canonical-gate pass.
"""
import ast
import hashlib
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/fe_pipe'))
import run_fetch_fragment_owned_replay as prior


def derive():
    text = prior.derive()
    pairs = (
        ('fetch-fragment-owned-same-input-r1','current-u-pair-replay-r1'),
        ('fetch-fragment-core-r1','current-u-pair-core-r1'),
        ("assert sha(models['candidate']) == started['model'] == "
         "'0698ce2f2e0de10ec1952704b63b40fd70fc8cbb682171d5ed83cade6e612c6c'",
         "assert sha(models['candidate']) == '10864ce701d4c90d5b8b16e3dd470a7eedc7e565450e2eef3b3f18784b5732b9'\n"
         "    assert started['model'] == '0698ce2f2e0de10ec1952704b63b40fd70fc8cbb682171d5ed83cade6e612c6c'"),
    )
    for old,new in pairs:
        assert text.count(old) == 1, old
        text = text.replace(old,new)
    anchor = "    pins = dict(started['pins'])"
    assert text.count(anchor) == 1
    path = Path(prior.__file__).resolve()
    text = text.replace(anchor,anchor+f'\n    pins[{str(path)!r}]={hashlib.sha256(path.read_bytes()).hexdigest()!r}')
    ast.parse(text)
    return text


if __name__ == '__main__': exec(compile(derive(),str(__file__),'exec'),globals())
