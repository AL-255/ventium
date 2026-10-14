"""Bind unchanged canonical/private functional gates to the prefix cofactor.

The canonical gate's existing failures remain failures. Neither the qualified
private oracle nor parent-identical cycle records replace that gate.
"""
import ast
import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO/'verif/sys/fp_env_store/run_write_checks.py'
SOURCE_SHA = 'e22906bbc0c19d1e37ab59eb34539ecbc29ad2249b81f8f43c6608f8285bcb9d'


def derive():
    text = SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == SOURCE_SHA
    substitutions = [
        ('"""'+ast.get_docstring(ast.parse(text))+'"""', repr(__doc__)),
        ('import prepare_write_class as recipe', 'import prepare_prefix_mem_payload as recipe'),
        ('\nREPO=Path(__file__).resolve().parents[3]\n', '\nREPO=Path(__file__).resolve().parents[2]\n'),
        ("parent=scratch/'ventium-data-size.v2HaTO2X/core-r1'",
         "parent=scratch/'ventium-data-size.v2HaTO2X/fast-segment-core-r1'"),
        ('fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041',
         '1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c'),
        ("recipe.transform((parent/'candidate'/recipe.FILE).read_text())",
         "recipe.transform((parent/'candidate'/recipe.FILE).read_text(), (parent/'candidate'/recipe.DECODER_FILE).read_text())"),
        ('    env=dict(os.environ)',
         '    pins['+repr(str(SOURCE))+']='+repr(SOURCE_SHA)+'\n    env=dict(os.environ)'),
    ]
    for before, after in substitutions:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
