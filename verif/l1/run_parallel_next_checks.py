"""Bind unchanged differential/cycle gates to the one-file next-line proposal."""
import ast
import hashlib
from pathlib import Path

import run_window_current_checks as previous


def derive():
    text=previous.derive()
    replacements=[
        (repr(previous.__doc__),repr(__doc__)),
        ('import prepare_window_current_reuse as recipe','import prepare_parallel_next_tag as recipe'),
        ("parent=scratch/'ventium-data-size.v2HaTO2X/env-write-core-r1'",
         "parent=scratch/'ventium-data-size.v2HaTO2X/window-current-core-r1'"),
        ("=='360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779'",
         "=='737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'"),
        ('    env=dict(os.environ)',
         '    pins['+repr(str(Path(previous.__file__).resolve()))+']='+
         repr(hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest())+'\n    env=dict(os.environ)')]
    for before,after in replacements:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
