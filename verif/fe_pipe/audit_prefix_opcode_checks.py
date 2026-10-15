"""Regrade complete candidate records and retain the canonical gate's failures."""
import ast
import hashlib
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import audit_window_current_checks as previous

SOURCE_SHA='b0a329ffba10adaef13cd605a7534fe15612f03406b6d69b25d65b1b3d247f8f'
REPLACEMENTS=(
    ('window-current','prefix-opcode',8),
    ('env-write','prefix-payload',5),
    ('-oct13-r1.service','-oct15-r1.service',2),
    ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
     '14435a4d189ed3d0d441e14d356877cf6492c4c50077f80093b5d92ea8b4aff5',1),
    ('ventium-prefix-opcode-same-input-oct15-r1.service','ventium-prefix-opcode-replay-oct15-r1.service',1))


def derive():
    source=Path(previous.__file__).resolve()
    assert hashlib.sha256(source.read_bytes()).hexdigest()==SOURCE_SHA
    text=previous.derive()
    for before,after,count in REPLACEMENTS:
        assert text.count(before)==count,(before,text.count(before),count)
        text=text.replace(before,after)
    marker='    pins={'
    assert text.count(marker)==1
    text=text.replace(marker,marker+repr(str(source))+':'+repr(SOURCE_SHA)+',')
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
