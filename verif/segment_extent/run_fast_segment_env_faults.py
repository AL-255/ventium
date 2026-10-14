"""Repeat unchanged cold x87 environment-store faults on the segment candidate."""
import ast
import hashlib
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import run_way_banked_env_faults as previous
import prepare_fast_segment as segment

PREVIOUS=Path(previous.__file__).resolve()
PREVIOUS_SHA='be906c9cdcb2d992add0a4b2733b126b2849b213749990eea74224a127cc08a3'
SOURCE=previous.SOURCE
window,next_tag,classifier,tags,fetch=(previous.window,previous.next_tag,previous.classifier,
                                    previous.tags,previous.fetch)


def derive():
    assert hashlib.sha256(PREVIOUS.read_bytes()).hexdigest()==PREVIOUS_SHA
    text=previous.derive()
    changes=(
        ("== '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'",
         "== '1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c'"),
        ("before['parent_model']=='5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8' and before['changes']==['rtl/core/core.sv','rtl/mem/ven_l1d.sv']",
         "before['parent_model']=='139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7' and before['changes']==['rtl/core/core.sv']"),
        ("fetch.transform((original/'candidate/rtl/core/core.sv').read_text())",
         "segment.transform(fetch.transform((original/'candidate/rtl/core/core.sv').read_text()))"),
        ('for p in (PREVIOUS, Path(tags.__file__)',
         'for p in (PREVIOUS, Path(segment.__file__), previous.PREVIOUS, Path(tags.__file__)'))
    for before,after in changes:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
