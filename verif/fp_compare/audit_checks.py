"""Regrade classifier traces and terminal owners; retain canonical failures."""
import ast
import hashlib
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import audit_parallel_next_checks as previous


def derive():
    text=previous.derive()
    # Simultaneous identity mapping is deliberately ordered so the old parent
    # becomes the new parent, not the newly selected candidate directory.
    for before,after,count in (
        ('parallel-next-tag','fp-compare',6),
        ('window-current','parallel-next-tag',5),
        ('ventium-next-tag-','ventium-fp-compare-',2),
        ('-oct13-r1.service','-oct14-r1.service',2),
        ('97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e',
         '5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8',1)):
        assert text.count(before)==count,before
        text=text.replace(before,after)
    source=Path(previous.__file__).resolve();marker='    pins={'
    assert text.count(marker)==1
    text=text.replace(marker,marker+repr(str(source))+':'+
                      repr(hashlib.sha256(source.read_bytes()).hexdigest())+',')
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
