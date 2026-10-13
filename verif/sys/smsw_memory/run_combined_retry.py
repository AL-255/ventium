"""Run the unchanged 25-case paging-retry matrix on the composed RTL model.

Only the exact model admission and wrapper input pins differ. Preserve all
guest instructions, full QEMU comparisons, native outcomes and AXI delays.
"""
import ast
import hashlib
from pathlib import Path

import run_retry as parent

MODEL = '42bd14c86eff5e33d98753cd07d34bf1340e804989daec237e42fd499565cfa5'
ORIGINAL_MODEL = 'cbf749f16babd88fb5dcf508c2381d48b77dedd348e9b23a5ed9083de9f4e65e'
original, fixture = parent.original, parent.fixture


def derive():
    assert hashlib.sha256(Path(parent.__file__).read_bytes()).hexdigest() == \
        '48e13f69a080532ba5d19515a920585b108965a177a289bd75feaaca9c4214d9'
    text = parent.text
    assert text.count(ORIGINAL_MODEL) == 1
    text = text.replace(ORIGINAL_MODEL, MODEL)
    before = '(Path(__file__),original,Path(fixture.__file__),'
    assert text.count(before) == 1
    text = text.replace(before, '(Path(__file__),Path(parent.__file__),original,Path(fixture.__file__),')
    anchor = "    assert sha(model) == built['binary_sha256'] == " + repr(MODEL)
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + "\n"
        "    composition = json.loads((core/'combined-build-closed.json').read_text())\n"
        "    assert composition['passed'] and composition['wrapper_pins_unchanged']\n"
        "    assert composition['binary_sha256'] == built['binary_sha256']\n"
        "    assert before['exact_disjoint_composition']\n"
        "    assert not before['canonical_gate_passed'] and not before['standard_suite']")
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
