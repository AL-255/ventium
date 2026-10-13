"""Separate actual QEMU exit-observer modes in the functional golden cache.

Private-worker recipe: keep the canonical worker immutable while its hash is
pinned by live gates. No oracle, trace, mask, cycle key or comparison changes.
"""
import hashlib

PARENT = '9638c5548faf39409e8696ef7f7f72cbb4a68b3b0dc429f930092e449d7a3cd4'
OLD = '''    KEY="${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.func.x87${X87}.max${MAX}"
'''
NEW = '''    # The opt-in QEMU observer changes the actual terminal record without
    # changing the binary. Match its literal-1 activation rule; all other
    # values are disabled. Never share enabled/disabled functional goldens.
    PREEXIT_MODE=0
    [ "${VTM_QEMU_GDB_PREEXIT:-}" = "1" ] && PREEXIT_MODE=1
    KEY="${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.func.preexit${PREEXIT_MODE}.x87${X87}.max${MAX}"
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT or source.count(OLD) != 1:
        raise ValueError('functional cache worker drift/reapplication')
    return source.replace(OLD, NEW)
