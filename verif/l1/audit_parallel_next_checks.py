"""Independently grade closed next-tag runs without waiving canonical failures."""
import ast
import hashlib
from pathlib import Path

import audit_window_current_checks as previous


def derive():
    text = previous.derive()
    # The inherited auditor rereads complete traces and native owner receipts;
    # only candidate/parent identities and evidence destinations change here.
    assert text.count('window-current') == 8
    text = text.replace('window-current', 'parallel-next-tag')
    text = text.replace('ventium-parallel-next-tag-', 'ventium-next-tag-')
    assert text.count('env-write') == 5
    text = text.replace('env-write', 'window-current')
    model = '737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'
    assert text.count(model) == 1
    text = text.replace(model, '97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e')
    source = Path(previous.__file__).resolve()
    marker = '    pins={'
    assert text.count(marker) == 1
    text = text.replace(marker, marker + repr(str(source)) + ':' +
                        repr(hashlib.sha256(source.read_bytes()).hexdigest()) + ',')
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
