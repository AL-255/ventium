"""Repeat the unchanged cold x87 environment fault/retry corpus on this core."""
import ast
import hashlib
import importlib.util
from pathlib import Path

REPO=Path(__file__).resolve().parents[2]
PREVIOUS=REPO/'verif/fp_compare/run_env_faults.py'
PREVIOUS_SHA='8cd143704a0ca5efce9e215e03fa4e819f60ac030e48a07040eb05e94b1dfc53'
assert hashlib.sha256(PREVIOUS.read_bytes()).hexdigest()==PREVIOUS_SHA
spec=importlib.util.spec_from_file_location('way_banked_parent_env_faults',PREVIOUS)
previous=importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)
SOURCE=previous.SOURCE
window,next_tag,classifier=previous.window,previous.next_tag,previous.classifier
import prepare_way_banked_tags as tags
import sys
sys.path.insert(0,str(REPO/'verif/issue_uv'))
import prepare_fetch_fault_page_current as fetch


def derive():
    text=previous.derive()
    for before,after in (
        ('5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8',
         '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'),
        ("before['parent_model']=='97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e' and before['changes']==['fp_shared/ven_fp_top.sv']",
         "before['parent_model']=='5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8' and before['changes']==['rtl/core/core.sv','rtl/mem/ven_l1d.sv']"),
        ("==['fp_shared/ven_fp_top.sv',recipe.FILE,'rtl/mem/ven_l1d.sv']",
         "==sorted(['fp_shared/ven_fp_top.sv',recipe.FILE,'rtl/core/core.sv','rtl/mem/ven_l1d.sv'])"),
        ("next_tag.transform(window.transform((original/'candidate/rtl/mem/ven_l1d.sv').read_text()))",
         "tags.transform(next_tag.transform(window.transform((original/'candidate/rtl/mem/ven_l1d.sv').read_text())))"),
        ("        assert classifier.transform(",
         "        assert fetch.transform((original/'candidate/rtl/core/core.sv').read_text())==(core/'candidate/rtl/core/core.sv').read_text()\n"
         "        assert classifier.transform("),
        ('for p in (SOURCE, Path(window.__file__)',
         'for p in (PREVIOUS, Path(tags.__file__), Path(fetch.__file__), Path(fetch.original.__file__), SOURCE, Path(window.__file__)')):
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
