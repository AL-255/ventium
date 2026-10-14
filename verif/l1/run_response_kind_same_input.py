"""Same images, initial stack, complete architectural records and cycle counts."""
import ast
import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO/'verif/l1/run_window_current_same_input.py'
SOURCE_SHA = '60eaf87e536a6fc3a24467c4a294433cde3ccf484bcb7eaa919ee7b95a369890'
REPLACEMENTS = (
    ('window-current-same-input-r1', 'response-kind-same-input-r1'),
    ('window-current-func-r1', 'response-kind-func-r1'),
    ('env-write-core-r1', 'prefix-payload-core-r1'),
    ('window-current-core-r1', 'response-kind-core-r1'),
    ('360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779',
     'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'),
    ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
     'da6744ec11615ca7900a6ed132bc9e64471dd567e363d33985864e50719be6dd'),
)


def derive():
    text = SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == SOURCE_SHA
    for before, after in REPLACEMENTS:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    marker = "    pins = dict(started['pins'])"
    assert text.count(marker) == 1
    text = text.replace(marker, marker+'\n    pins['+repr(str(SOURCE))+']='+repr(SOURCE_SHA))
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
