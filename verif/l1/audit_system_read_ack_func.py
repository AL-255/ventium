"""Regrade fresh full private-reference records without changing gate policy."""
from pathlib import Path

import audit_raw_prime_storage_func as previous


def derive():
    assert previous.template.previous.hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest()==(
        '2b2231299bdc29e38d721a0d6d73d4978fc36418cf518bb233de31b7aec4e404')
    text=previous.derive()
    for old,new in (
        ('import run_raw_prime_storage_func as runner','import run_system_read_ack_func as runner'),
        ('raw-prime-storage-func-r1','system-read-ack-func-r1'),
        ('raw-prime-storage-core-r1','system-read-ack-core-r1'),
        ('ventium-raw-prime-storage-func-oct16-r1.service','ventium-system-read-ack-func-oct16-r1.service'),
        ('runner.SOURCE, Path(', 'runner.SOURCE, Path('+repr(str(Path(previous.__file__)))+'), Path('),
    ):
        assert text.count(old)==1,old
        text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':exec(compile(derive(),__file__,'exec'),globals())
