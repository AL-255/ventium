"""Replay unchanged complete architectural/cycle traces for the classifier."""
import ast
import hashlib
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import run_parallel_next_same_input as previous


def derive():
    text=previous.derive()
    replacements=[
        ("root = evidence / 'parallel-next-tag-same-input-r1'",
         "root = evidence / 'fp-compare-same-input-r1'"),
        ("func = evidence / 'parallel-next-tag-func-r1'",
         "func = evidence / 'fp-compare-func-r1'"),
        ("('parent', 'window-current-core-r1'), ('candidate', 'parallel-next-tag-core-r1')",
         "('parent', 'parallel-next-tag-core-r1'), ('candidate', 'fp-compare-core-r1')"),
        ("assert sha(models['parent']) == '737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'",
         "assert sha(models['parent']) == '97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e'"),
        ("assert sha(models['candidate']) == started['model'] == '97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e'",
         "assert sha(models['candidate']) == started['model'] == '5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'"),
        ('    pins = dict(started[\'pins\'])',
         '    pins = dict(started[\'pins\'])\n    pins['+repr(str(Path(previous.__file__).resolve()))+']='+
         repr(hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest()))]
    for before,after in replacements:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
