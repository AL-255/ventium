"""Regrade the fresh private corpus without changing canonical acceptance."""
from pathlib import Path

import audit_system_read_ack_func as previous


def derive():
    import hashlib
    assert hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest() == 'b5a287b96915e864c9b35317617a6af08709ac2ab8d8a2d27b7fb8b2e1c77513'
    source = previous.derive()
    for old, new in (
        ('import run_system_read_ack_func as runner', 'import run_qualified_pair_credit_func as runner'),
        ('system-read-ack-func-r1', 'qualified-pair-credit-func-r1'),
        ('system-read-ack-core-r1', 'qualified-pair-credit-core-r1'),
        ('ventium-system-read-ack-func-oct16-r1.service', 'ventium-qualified-pair-func-oct16-r1.service'),
        ('runner.SOURCE, Path(', 'runner.SOURCE, Path('+repr(str(Path(previous.__file__)))+'), Path('),
    ):
        assert source.count(old) == 1, old
        source = source.replace(old, new)
    compile(source, __file__, 'exec')
    return source


if __name__ == '__main__':
    exec(compile(derive(), __file__, 'exec'), globals())
