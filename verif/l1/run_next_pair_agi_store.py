"""Cold QEMU/A-B check: paid U-load AGI with a decoded independent V store.

LEA writes the load's base without changing its value. The paid AGI edge has
no architectural read request but can issue a resident hint. This distinguishes
the exact read-request-and-pair-shape exclusion from a harmful shape-only gate.
The reused driver still requires actual V stores, full state and equal clocks.
"""
from pathlib import Path
import hashlib

import run_l1_write_kind_system as driver


def main():
    original = Path(driver.__file__)
    digest = hashlib.sha256(original.read_bytes()).hexdigest()
    driver.PATTERNS = (
        ('same-line', 'leal (%eax),%eax\n    movl (%eax),%edx', 'movl %esi,4(%eax)'),
        ('other-line', 'leal (%eax),%eax\n    movl (%eax),%edx', 'movl %esi,4(%edi)'),
    )
    try:
        return driver.main()
    finally:
        assert hashlib.sha256(original.read_bytes()).hexdigest() == digest


if __name__ == '__main__':
    raise SystemExit(main())
