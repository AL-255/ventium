"""Retain the full unmasked same-input state/cycle replay for next-line tags."""
import ast
import hashlib
from pathlib import Path

SOURCE=Path(__file__).with_name('run_window_current_same_input.py')
SOURCE_SHA='60eaf87e536a6fc3a24467c4a294433cde3ccf484bcb7eaa919ee7b95a369890'


def derive():
    text=SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest()==SOURCE_SHA
    changes=[
        ("root = evidence / 'window-current-same-input-r1'",
         "root = evidence / 'parallel-next-tag-same-input-r1'"),
        ("func = evidence / 'window-current-func-r1'",
         "func = evidence / 'parallel-next-tag-func-r1'"),
        ("('parent', 'env-write-core-r1'), ('candidate', 'window-current-core-r1')",
         "('parent', 'window-current-core-r1'), ('candidate', 'parallel-next-tag-core-r1')"),
        ("assert sha(models['parent']) == '360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779'",
         "assert sha(models['parent']) == '737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'"),
        ("assert sha(models['candidate']) == started['model'] == '737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'",
         "assert sha(models['candidate']) == started['model'] == '97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e'"),
        ("    pins = dict(started['pins'])",
         "    pins = dict(started['pins'])\n    pins["+repr(str(SOURCE.resolve()))+"]="+repr(SOURCE_SHA))]
    for before,after in changes:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
