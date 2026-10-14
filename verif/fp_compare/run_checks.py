"""Run unchanged canonical/private-QEMU gates for the compare classifier model."""
import ast
import hashlib
from pathlib import Path
import sys

import prepare as recipe

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import run_parallel_next_checks as previous


def derive():
    text=previous.derive()
    replacements=[
        ('import prepare_parallel_next_tag as recipe', '# recipe supplied by the classifier adapter'),
        ("FILE='rtl/mem/ven_l1d.sv'", "FILE='fp_shared/ven_fp_top.sv'"),
        ("parent=scratch/'ventium-data-size.v2HaTO2X/window-current-core-r1'",
         "parent=scratch/'ventium-data-size.v2HaTO2X/parallel-next-tag-core-r1'"),
        ("=='737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'",
         "=='97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e'"),
        ('    env=dict(os.environ)',
         '    pins['+repr(str(Path(previous.__file__).resolve()))+']='+
         repr(hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest())+'\n    env=dict(os.environ)')]
    for before,after in replacements:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
