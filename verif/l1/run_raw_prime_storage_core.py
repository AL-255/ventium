"""Keep all eight original QEMU/full-state/cycle corpora for RAW storage.

The original aggregate's older-parent counter failure remains a failure; this
adapter does not change its coverage expectations or substitute a passing leaf.
"""
from pathlib import Path

import run_prime_width_core as template
from run_raw_prime_storage_func import MODEL as CANDIDATE
from build_raw_prime_storage_core import MODEL as PARENT

HERE, BASE = template.HERE, template.BASE


def derive():
    assert template.hashlib.sha256(Path(template.__file__).read_bytes()).hexdigest() == '49a3350bf136edcf940608f24527962f4b1b2b777ac5794e6d54ef308482681a'
    text = template.derive()
    for old, new in (
        ('import prepare_prime_width_payload as recipe', 'import prepare_raw_prime_storage as recipe'),
        ('build_prime_width_core.py', 'build_raw_prime_storage_core.py'),
        ('run_prime_width_func.py', 'run_raw_prime_storage_func.py'),
        (template.CANDIDATE, CANDIDATE),
        ('prime_width_equality_assertion=True', 'raw_storage_zero_assertion=True'),
        ("HERE/'build_raw_prime_storage_core.py',", "Path(template.__file__),HERE/'build_raw_prime_storage_core.py',"),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    compile(text, __file__, 'exec')
    return text


if __name__ == '__main__':exec(compile(derive(), __file__, 'exec'), globals())
