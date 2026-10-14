"""Run original x87 environment-store fault fixtures on the response derivative."""
import ast
import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO/'verif/sys/fp_env_store/run_fault.py'
SOURCE_SHA = '9ada61a46eee45104bf973d6df50a00b63b7c401622ae65520a90a6a636b1499'


def derive():
    text = SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == SOURCE_SHA
    substitutions = (
        ('HERE = Path(__file__).resolve().parent', 'HERE = SOURCE.parent'),
        ('import prepare_write_class as recipe', 'import prepare_response_kind_mux as recipe'),
        ("ap.add_argument('--core', type=Path)", "ap.add_argument('--core', type=Path, required=True)"),
        ("original = scratch/'ventium-data-size.v2HaTO2X/core-r1'",
         "original = scratch/'ventium-data-size.v2HaTO2X/prefix-payload-core-r1'"),
        ("assert sha(model) == built['binary_sha256']",
         "assert sha(model) == built['binary_sha256'] == 'da6744ec11615ca7900a6ed132bc9e64471dd567e363d33985864e50719be6dd'"),
        ('fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041',
         'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'),
        ('for p in (Path(__file__), Path(recipe.__file__),',
         'for p in (SOURCE, Path(__file__), Path(recipe.__file__),'),
    )
    for before, after in substitutions:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
