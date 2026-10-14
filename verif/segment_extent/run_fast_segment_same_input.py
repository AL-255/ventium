"""Keep exact architectural/cycle replay and private-QEMU input bytes unchanged."""
import ast
import hashlib
from pathlib import Path

REPO=Path(__file__).resolve().parents[2]
SOURCE=REPO/'verif/l1/run_window_current_same_input.py'
SOURCE_SHA='60eaf87e536a6fc3a24467c4a294433cde3ccf484bcb7eaa919ee7b95a369890'
REPLACEMENTS=(
    ('window-current-same-input-r1','fast-segment-same-input-r1'),
    ('window-current-func-r1','fast-segment-func-r1'),
    ('env-write-core-r1','way-banked-core-r1'),
    ('window-current-core-r1','fast-segment-core-r1'),
    ('360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779',
     '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'),
    ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
     '1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c'))


def derive():
    text=SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest()==SOURCE_SHA
    for before,after in REPLACEMENTS:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    marker="    pins = dict(started['pins'])"
    assert text.count(marker)==1
    text=text.replace(marker,marker+'\n    pins['+repr(str(SOURCE))+']='+repr(SOURCE_SHA))
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
