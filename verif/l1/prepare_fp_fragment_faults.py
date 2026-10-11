"""Misalign only the FP operand of the existing cold page-fault fixture."""
import hashlib

SOURCE_SHA = '42281a8987add25587e223492565060b8323d0df2bfc8a8549adf909d6cc14ea'


def transform(source, delta):
    if type(delta) is not int or delta not in (1, 2, 3):
        raise ValueError('expected FFD/FFE/FFF operand offset')
    if hashlib.sha256(source.encode()).hexdigest() != SOURCE_SHA:
        raise ValueError('FP fragment fixture source drift')
    edits = []

    def replace(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise ValueError('ambiguous FP fragment fixture anchor')
        source = source.replace(old, new)
        edits.append((old, new))

    first = source.index('#if defined(PREP_FP_LOAD) && PREP_FP_LOAD == 2')
    last = source.index('#endif', first) + len('#endif')
    old = source[first:last]
    assert old.count('0x00400ffc') == old.count('0x00401000') == 3
    replace(old, old.replace('0x00400ffc', '0x%08x' % (0x400ffc + delta))
                   .replace('0x00401000', '0x%08x' % (0x401000 + delta)))
    for prefix, address in (('    movl $', 0x3f0ffc), ('    fldl ', 0x400ffc),
                            ('    fildll ', 0x400ffc), ('    faddl ', 0xffc),
                            ('    faddl ', 0x400ffc)):
        old = prefix + '0x%08x' % address
        replace(old, prefix + '0x%08x' % (address + delta))
    # The second page still starts at 401000. Never move the expected CR2,
    # page-table entries, trap/retry PCs, guest PASS checks or command length.
    check = source
    for old, new in reversed(edits):
        assert check.count(new) == 1
        check = check.replace(new, old)
    assert hashlib.sha256(check.encode()).hexdigest() == SOURCE_SHA
    return source
