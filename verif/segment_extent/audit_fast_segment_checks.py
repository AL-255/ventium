"""Regrade complete segment-candidate traces without relaxing canonical failures."""
import ast
import hashlib
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import audit_way_banked_checks as previous

SOURCE_SHA='1c5038bbf6edbc9b8e8b6f0f0a848894a97fc59e0b2238b537e0dbde7cc54fea'


def derive():
    source=Path(previous.__file__).resolve()
    assert hashlib.sha256(source.read_bytes()).hexdigest()==SOURCE_SHA
    text=previous.derive()
    for before,after,count in (
        ('way-banked','fast-segment',8),
        ('fp-compare','way-banked',5),
        ('139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7',
         '1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c',1)):
        assert text.count(before)==count,before
        text=text.replace(before,after)
    marker='    pins={'
    assert text.count(marker)==1
    text=text.replace(marker,marker+repr(str(source))+':'+repr(SOURCE_SHA)+',')
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
