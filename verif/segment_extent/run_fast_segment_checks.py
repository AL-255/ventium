"""Run unchanged canonical/private-reference gates on the segment factorization."""
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
        ('import prepare_write_class as recipe','import prepare_fast_segment as recipe'),
        ('\nREPO=Path(__file__).resolve().parents[3]\n','\nREPO=Path(__file__).resolve().parents[2]\n'),
        ("parent=scratch/'ventium-data-size.v2HaTO2X/core-r1'",
         "parent=scratch/'ventium-data-size.v2HaTO2X/way-banked-core-r1'"),
        ('fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041',
         '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'),
        ('    env=dict(os.environ)',
         '    pins['+repr(str(SOURCE))+']='+repr(SOURCE_SHA)+'\n    env=dict(os.environ)')]
    for before,after in substitutions:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
