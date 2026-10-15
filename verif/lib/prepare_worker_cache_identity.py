"""Compose the qualified observer-mode key fix with the cycle ESP lookup fix.

Prepare only: production worker edits must wait for any source-pinned owner.
Cycle golden keys, producers, masks, limits and timing bands stay unchanged.
"""
import prepare_preexit_cache as preexit

OLD_LOOKUP = 'FUNC_GOLD="$CACHE_DIR/${SRC_SHA}.func.x87${X87}.max${MAX}.vtrace"'
NEW_LOOKUP = '''# Match the functional producer's complete key, including observer mode.
# A source-only legacy lookup cannot identify the actual image/oracle trace.
PREEXIT_MODE=0
[ "${VTM_QEMU_GDB_PREEXIT:-}" = "1" ] && PREEXIT_MODE=1
FUNC_GOLD="$CACHE_DIR/${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.func.preexit${PREEXIT_MODE}.x87${X87}.max${MAX}.vtrace"'''


def transform(source):
    changed = preexit.transform(source)
    if changed.count(OLD_LOOKUP) != 1:
        raise ValueError('cycle functional-cache lookup drift')
    return changed.replace(OLD_LOOKUP, NEW_LOOKUP)


def original(source):
    """Recover the pinned predecessor, refusing partial/mixed repairs."""
    if source.count(NEW_LOOKUP) != 1 or source.count(preexit.NEW) != 1:
        raise ValueError('not the complete cache-identity repair')
    old = source.replace(NEW_LOOKUP, OLD_LOOKUP).replace(preexit.NEW, preexit.OLD)
    if transform(old) != source:
        raise ValueError('repaired worker drift')
    return old
