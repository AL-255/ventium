"""Regrade complete prefix payload traces and native owners, retaining failures."""
import ast
import hashlib
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
import audit_window_current_checks as previous

SOURCE_SHA = 'b0a329ffba10adaef13cd605a7534fe15612f03406b6d69b25d65b1b3d247f8f'


def derive():
    source = Path(previous.__file__).resolve()
    assert hashlib.sha256(source.read_bytes()).hexdigest() == SOURCE_SHA
    text = previous.derive()
    for before, after, count in (
        ('window-current', 'prefix-payload', 8),
        ('env-write', 'fast-segment', 5),
        ('-oct13-r1.service', '-oct14-r1.service', 2),
        ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
         'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6', 1),
        ("'ventium-prefix-payload-'+label", "'ventium-prefix-payload-'+('verify' if label=='canonical' else label)", 1),
        ("'prefix-payload-'+label", "'prefix-payload-'+('verify' if label=='canonical' else label)", 2),
    ):
        assert text.count(before) == count, (before, text.count(before), count)
        text = text.replace(before, after)
    marker = '    pins={'
    assert text.count(marker) == 1
    text = text.replace(marker, marker+repr(str(source))+':'+repr(SOURCE_SHA)+',')
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
