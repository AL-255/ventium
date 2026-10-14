"""Bind the unchanged complete-state replay to the two-file timing candidate."""
import ast
import hashlib
from pathlib import Path

SOURCE=Path(__file__).with_name('run_window_current_same_input.py')
SOURCE_SHA='60eaf87e536a6fc3a24467c4a294433cde3ccf484bcb7eaa919ee7b95a369890'
REPLACEMENTS=(
    ('window-current-same-input-r1','way-banked-same-input-r1'),
    ('window-current-func-r1','way-banked-func-r1'),
    ('env-write-core-r1','fp-compare-core-r1'),
    ('window-current-core-r1','way-banked-core-r1'),
    ('360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779',
     '5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'),
    ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
     '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'))


def derive():
    text=SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest()==SOURCE_SHA
    for before,after in REPLACEMENTS:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    marker="    pins = dict(started['pins'])"
    assert text.count(marker)==1
    text=text.replace(marker,marker+'\n    pins['+repr(str(SOURCE.resolve()))+']='+repr(SOURCE_SHA))
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
