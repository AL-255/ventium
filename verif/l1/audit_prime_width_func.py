"""Regrade unchanged complete private-reference comparisons and native closure."""
from pathlib import Path
import sys

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fe_pipe'))
import audit_sfetch_interior_func as previous


def derive():
    assert previous.hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest()=='d402d699f8adb56e126b4fe52c104aa63791a8b4d8923026024dde4714a794cb'
    text=previous.derive()
    for old,new in (
        ('import run_sfetch_interior_func as runner','import run_prime_width_func as runner'),
        ('sfetch-interior-func-r1','prime-width-func-r2'),
        ('sfetch-interior-core-r1','prime-width-core-r1'),
        ('ventium-sfetch-interior-func-oct16-r1.service','ventium-prime-width-func-oct16-r2.service'),
        ('runner.SOURCE, Path(', 'runner.SOURCE, Path('+repr(str(Path(previous.__file__)))+'), Path('),
    ):
        assert text.count(old)==1,old
        text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__': exec(compile(derive(),__file__,'exec'),globals())
