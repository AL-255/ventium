"""Remove late probe authority from a bus payload in a no-request state.

Private exact-parent experiment, not an accepted timing or processor fix.
The existing S_DECODE invariant proves bd_req=0 there, and cur_lin_nat already
prepares the next-page payload independently of decoded overlength. This
change affects only the address carried when no transaction is authorized.
MMU translation/probe/fault authority and every bd_req assignment stay intact.
"""
import hashlib

FILE = 'rtl/core/core_bus_driver.svh'
PARENT = '2e592948d1ae2a99babc970a5c573a1de42fbf011f62e8b34d473c4b216ae08c'
OLD = '    if (fe_translatable) bd_addr = cur_lin;\n'
NEW = '''    // DECODE never issues a bus beat. Prepare its already independent
    // next-page address without reintroducing late overlength qualification
    // into the shared bus/cache payload. MMU/probe authority is UNCHANGED:
    // fe_translatable still owns the optional I-side probe, and no request
    // or cache mutation is authorized by this payload-only cofactor.
    if (fe_translatable || state == S_DECODE) bd_addr = cur_lin;
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('decode-bus predecessor drift/reapplication')
    if source.count(OLD) != 1:
        raise ValueError('ambiguous decode-bus payload assignment')
    return source.replace(OLD, NEW)
