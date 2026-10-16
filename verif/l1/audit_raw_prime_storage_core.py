"""Regrade every complete current-parent A/B trace without waiving old totals."""
import inspect
from pathlib import Path

import audit_prime_width_core as template
import run_raw_prime_storage_core as runner


def derive():
    assert template.sha(template.__file__) == '63033dff97f85eac2336c3c07955c39528d4c00d540c274606b981e4d5e6432e'
    text = inspect.getsource(template.main)
    for old, new in (
        ('ventium-prime-width-core-checks-oct16-r1.service', 'ventium-raw-prime-storage-core-checks-oct16-r1.service'),
        ('c53eb9d385a0472faf4de153b2b0980c', 'febd335ce935488f8ae109377d4f86c7'),
        ('8309e8d067bc4c7ba048fe1816700c82', '1bb8eb4df8ed4070b282ad380fe6c64b'),
        ('(Path(__file__).resolve(),root/', '(Path(__file__).resolve(),Path(template.__file__).resolve(),root/'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    compile(text, __file__, 'exec')
    return text


def main():
    scope = dict(template.__dict__, __file__=__file__, template=template, runner=runner)
    exec(compile(derive(), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__':main()
