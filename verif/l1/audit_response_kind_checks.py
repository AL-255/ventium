"""Independently regrade complete traces and terminal native gate owners."""
import ast
import hashlib
from pathlib import Path

import audit_window_current_checks as previous

SOURCE_SHA = 'b0a329ffba10adaef13cd605a7534fe15612f03406b6d69b25d65b1b3d247f8f'


def derive():
    source = Path(previous.__file__).resolve()
    assert hashlib.sha256(source.read_bytes()).hexdigest() == SOURCE_SHA
    text = previous.derive()
    for before, after, count in (
        ('window-current', 'response-kind', 8),
        ('env-write', 'prefix-payload', 5),
        ('-oct13-r1.service', '-oct14-r1.service', 2),
        ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
         'da6744ec11615ca7900a6ed132bc9e64471dd567e363d33985864e50719be6dd', 1),
        ("'ventium-response-kind-'+label", "'ventium-response-kind-'+('verify' if label=='canonical' else label)", 1),
        ("'response-kind-'+label", "'response-kind-'+('verify' if label=='canonical' else label)", 2),
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
