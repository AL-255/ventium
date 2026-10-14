"""Transfer the proved fast-segment factorization into the UV-fast full PC.

Keep all 102 shared RTL files matched to the directed core, the posted-16
single-fill policy, 156 definitions and private generated-header contract.
This is not a canonical-gate, standard-suite or physical FPGA pass.
"""
import ast
import hashlib
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/segment_extent'))
import prepare_fast_segment as recipe


def transform(name,source):
    if name==recipe.FILE:
        return recipe.transform(source)
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
         '810fca8a8f27298f190274a85d8bec7d6ccf785347edfaa0316f4662a43f4719'),
        ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
         '1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c'),
        ("CHANGES = [env_write.FILE, 'rtl/mem/ven_l1d.sv']","CHANGES = [recipe.FILE]"),
        ("proof / 'window-current-core-r1'","proof / 'fast-segment-core-r1'"),
        ("proof / 'soc-r1'","proof / 'way-banked-soc-r1'"),
        ('window-current-regression-audit.json','fast-segment-regression-audit.json'),
        ('sim_window_current_','sim_fast_segment_'),
        ('Path(window.__file__), Path(env_write.__file__),','original, Path(recipe.__file__),'),
        ('Two-file transfer prepared;','One-file transfer prepared;'),
        ('    assert \'MemoryMax=10G MemorySwapMax=2G\' in command[4]',
         "    affinity = command.index('taskset')\n"
         "    assert command[affinity+1:affinity+3] == ['-c', '0-9,12-31']\n"
         "    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]"))
    for before,after in substitutions:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return original,text


original,derived=derive()
exec(compile(derived,str(Path(__file__)),'exec'),globals())
