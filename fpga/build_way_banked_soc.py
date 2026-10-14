"""Transfer the two-file tag-bank/fetch-page candidate to the full PC.

Keep the complete source, profile, host-header and native build contracts.
Canonical failures remain failures; no standard-suite or hardware pass follows.
"""
import ast
import hashlib
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(REPO/'verif/l1'),str(REPO/'verif/issue_uv')]
import prepare_way_banked_tags as tags
import prepare_fetch_fault_page_current as fetch


def transform(name,source):
    if name=='rtl/core/core.sv':
        return fetch.transform(source)
    if name=='rtl/mem/ven_l1d.sv':
        return tags.transform(source)
    raise ValueError('unreviewed source delta: '+name)


def derive():
    original=Path(__file__).with_name('build_window_current_soc.py')
    text=original.read_text()
    assert hashlib.sha256(text.encode()).hexdigest()=='ddfd33d54a5952e9168c5957a4e7e1225d00a8c364f8c8e3a310b913d90ef4e9'
    tree=ast.parse(text)
    function=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='transform')
    lines=text.splitlines(keepends=True)
    text=''.join(lines[:function.lineno-1]+lines[function.end_lineno:])
    substitutions=(
        ('"""'+ast.get_docstring(tree,clean=False)+'"""',repr(__doc__)),
        ('c0de36c5456d737ed38431598095f3df7d5c03f4f61da5e9462d1ddb23cd772f',
         '81edc510dab23425c3935e68b4ac9b5c0d84620e2df9f99e47a0a162f1c8f76a'),
        ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
         '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'),
        ("CHANGES = [env_write.FILE, 'rtl/mem/ven_l1d.sv']",
         "CHANGES = ['rtl/core/core.sv', 'rtl/mem/ven_l1d.sv']"),
        ("proof / 'window-current-core-r1'","proof / 'way-banked-core-r1'"),
        ("proof / 'soc-r1'","proof / 'fp-compare-soc-r1'"),
        ('window-current-regression-audit.json','way-banked-regression-audit.json'),
        ('sim_window_current_','sim_way_banked_'),
        ('Path(window.__file__), Path(env_write.__file__),',
         'original, Path(tags.__file__), Path(fetch.__file__), Path(fetch.original.__file__),'),
        ('    assert \'MemoryMax=10G MemorySwapMax=2G\' in command[4]',
         "    affinity = command.index('taskset')\n"
         "    assert command[affinity+1:affinity+3] == ['-c', '0-15,18-21,23,26-27,29-31']\n"
         "    command[affinity+2] = '0-9,12-31'  # Reserve CPU11's existing gameplay run.\n"
         "    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]"))
    for before,after in substitutions:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return original,text


original,derived=derive()
exec(compile(derived,str(Path(__file__)),'exec'),globals())
