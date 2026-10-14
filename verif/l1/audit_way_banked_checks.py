"""Regrade complete timing-candidate traces, retaining canonical failures."""
import ast
import hashlib
import importlib.util
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[2]
SOURCE=REPO/'verif/fp_compare/audit_checks.py'
SOURCE_SHA='26d9b284286c87b0d3b2850799c4e1e8791446b924a9a5b69e0d3e684586980c'


def derive():
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest()==SOURCE_SHA
    sys.path.insert(0,str(REPO/'verif/l1'))
    spec=importlib.util.spec_from_file_location('way_banked_parent_audit',SOURCE)
    previous=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(previous)
    text=previous.derive()
    for before,after,count in (
        ('fp-compare','way-banked',8),
        ('parallel-next-tag','fp-compare',5),
        ('5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8',
         '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7',1)):
        assert text.count(before)==count,before
        text=text.replace(before,after)
    marker='    pins={'
    assert text.count(marker)==1
    text=text.replace(marker,marker+repr(str(SOURCE))+':'+repr(SOURCE_SHA)+',')
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
