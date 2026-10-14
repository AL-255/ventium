"""Bind unchanged canonical/private-QEMU gates to the two-file timing candidate."""
import ast
import hashlib
from pathlib import Path

REPO=Path(__file__).resolve().parents[2]
SOURCE=REPO/'verif/sys/fp_env_store/run_write_checks.py'
SOURCE_SHA='e22906bbc0c19d1e37ab59eb34539ecbc29ad2249b81f8f43c6608f8285bcb9d'


def derive():
    text=SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest()==SOURCE_SHA
    substitutions=[
        ('"""'+ast.get_docstring(ast.parse(text))+'"""',repr(__doc__)),
        ('import prepare_write_class as recipe',
         'import prepare_way_banked_tags as recipe\nfrom build_way_banked_core import CHANGES,MODEL,changed_sources'),
        ('\nREPO=Path(__file__).resolve().parents[3]\n','\nREPO=Path(__file__).resolve().parents[2]\n'),
        ("parent=scratch/'ventium-data-size.v2HaTO2X/core-r1'",
         "parent=scratch/'ventium-data-size.v2HaTO2X/fp-compare-core-r1'"),
        ("started['changes']==[recipe.FILE]","started['changes']==CHANGES"),
        ("started['parent_model']=='fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041'",
         "started['parent_model']==MODEL"),
        ("    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()",
         "    assert changed_sources(parent/'candidate')=={name:(core/'candidate'/name).read_text() for name in CHANGES}"),
        ('    env=dict(os.environ)',
         '    pins['+repr(str(SOURCE))+']='+repr(SOURCE_SHA)+'\n    env=dict(os.environ)')]
    for before,after in substitutions:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
