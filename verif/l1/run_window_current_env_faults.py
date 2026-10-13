"""Repeat the unchanged x87 page-fault/retry corpus after the cache cofactor."""
import ast
import hashlib
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'verif/sys/fp_env_store/run_fault.py'
SOURCE_SHA = '9ada61a46eee45104bf973d6df50a00b63b7c401622ae65520a90a6a636b1499'
sys.path.insert(0, str(SOURCE.parent))
import prepare_window_current_reuse as window


def derive():
    text = SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == SOURCE_SHA
    replacements = [
        ('HERE = Path(__file__).resolve().parent', 'HERE = SOURCE.parent'),
        ("ap.add_argument('--core', type=Path)", "ap.add_argument('--core', type=Path, required=True)"),
        ('    assert sha(model) == built[\'binary_sha256\']',
         "    assert sha(model) == built['binary_sha256'] == '737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'"),
        ("assert before['parent_model']==parent_model and before['changes']==[recipe.FILE]",
         "assert before['parent_model']=='360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779' and before['changes']==['rtl/mem/ven_l1d.sv']"),
        ("assert [n for n in parent_files if parent_files[n]!=actual_files[n]]==[recipe.FILE]",
         "assert sorted(n for n in parent_files if parent_files[n]!=actual_files[n])==[recipe.FILE,'rtl/mem/ven_l1d.sv']\n"
         "        assert window.transform((original/'candidate/rtl/mem/ven_l1d.sv').read_text())==(core/'candidate/rtl/mem/ven_l1d.sv').read_text()"),
        ('for p in (Path(__file__), Path(recipe.__file__), HERE/\'fault.S\'',
         "for p in (SOURCE, Path(window.__file__), Path(__file__), Path(recipe.__file__), HERE/'fault.S'")]
    for before, after in replacements:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    ast.parse(text)
    return text


if __name__ == '__main__': exec(compile(derive(), str(__file__), 'exec'), globals())
