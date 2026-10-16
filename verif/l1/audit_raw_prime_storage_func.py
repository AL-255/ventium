"""Independent complete private-reference regrading, not a canonical waiver."""
from pathlib import Path

import audit_prime_width_func as template


def derive():
    assert template.previous.hashlib.sha256(Path(template.__file__).read_bytes()).hexdigest() == '1419010942546c12c15934156e611955cc8e53cf99002713f1aaf8e182b81ba0'
    text = template.derive()
    for old, new in (
        ('import run_prime_width_func as runner', 'import run_raw_prime_storage_func as runner'),
        ('prime-width-func-r2', 'raw-prime-storage-func-r1'),
        ('prime-width-core-r1', 'raw-prime-storage-core-r1'),
        ('ventium-prime-width-func-oct16-r2.service', 'ventium-raw-prime-storage-func-oct16-r1.service'),
        ('runner.SOURCE, Path(', 'runner.SOURCE, Path('+repr(str(Path(template.__file__)))+'), Path('),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    compile(text, __file__, 'exec')
    return text


if __name__ == '__main__':exec(compile(derive(), __file__, 'exec'), globals())
