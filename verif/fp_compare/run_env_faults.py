"""Repeat unchanged cold environment-store fault/retry fixtures on this model."""
import ast
import hashlib
import importlib.util
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'verif/sys/fp_env_store/run_fault.py'
sys.path.insert(0, str(SOURCE.parent))
sys.path.insert(0, str(REPO / 'verif/l1'))
import prepare_window_current_reuse as window
import prepare_parallel_next_tag as next_tag
spec = importlib.util.spec_from_file_location('fp_compare_fault_recipe', Path(__file__).with_name('prepare.py'))
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


def derive():
    text = SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == '9ada61a46eee45104bf973d6df50a00b63b7c401622ae65520a90a6a636b1499'
    for before, after in (
        ('HERE = Path(__file__).resolve().parent', 'HERE = SOURCE.parent'),
        ("ap.add_argument('--core', type=Path)", "ap.add_argument('--core', type=Path, required=True)"),
        ("    assert sha(model) == built['binary_sha256']",
         "    assert sha(model) == built['binary_sha256'] == '5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'"),
        ("assert before['parent_model']==parent_model and before['changes']==[recipe.FILE]",
         "assert before['parent_model']=='97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e' and before['changes']==['fp_shared/ven_fp_top.sv']"),
        ("assert [n for n in parent_files if parent_files[n]!=actual_files[n]]==[recipe.FILE]",
         "assert sorted(n for n in parent_files if parent_files[n]!=actual_files[n])==['fp_shared/ven_fp_top.sv',recipe.FILE,'rtl/mem/ven_l1d.sv']\n"
         "        assert next_tag.transform(window.transform((original/'candidate/rtl/mem/ven_l1d.sv').read_text()))==(core/'candidate/rtl/mem/ven_l1d.sv').read_text()\n"
         "        assert classifier.transform((original/'candidate/fp_shared/ven_fp_top.sv').read_text())==(core/'candidate/fp_shared/ven_fp_top.sv').read_text()"),
        ("for p in (Path(__file__), Path(recipe.__file__), HERE/'fault.S'",
         "for p in (SOURCE, Path(window.__file__), Path(next_tag.__file__), Path(classifier.__file__), Path(__file__), Path(recipe.__file__), HERE/'fault.S'"),
    ):
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    ast.parse(text)
    return text


if __name__ == '__main__': exec(compile(derive(), str(__file__), 'exec'), globals())
