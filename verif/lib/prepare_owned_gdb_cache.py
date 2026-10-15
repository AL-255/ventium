"""Exact successor to the installed observer/ESP cache fix (9866f49e).

Keep cycle keys unchanged. Functional producers and their local dependencies
must be in the identity; a transport fix must not reuse a mislabelled trace.
"""
import hashlib

PARENT_SHA = 'a39a497a74a92deef65c648a535835192085e904e8dffb497ef64aec7c6aa3e6'
ANCHOR = '# =============================================================================\n# FUNC PATH'
IDENTITY = '''# Functional-only producer closure: invalidate old TCP-derived entries without
# invalidating the independent plugin cycle oracle. Match this in ESP lookup.
GEN_DIR="$(dirname "$GEN_TRACE")"
FUNC_PRODUCER_SIG="$(printf '%s|%s|%s\\n' \\
    "generator=$(_sha_of "$GEN_TRACE")" \\
    "transport=$(_sha_of "$GEN_DIR/owned_gdb.py")" \\
    "tracefmt=$(_sha_of "$GEN_DIR/../diff/tracefmt.py")" \\
    | sha1sum | cut -d' ' -f1)"

'''
OLD_KEY = '${ORACLE_SIG:0:12}.func.preexit'
NEW_KEY = '${ORACLE_SIG:0:12}.producer${FUNC_PRODUCER_SIG:0:12}.func.preexit'


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT_SHA:
        raise ValueError('worker predecessor drift')
    assert text.count(ANCHOR) == 1 and text.count(OLD_KEY) == 2
    return text.replace(ANCHOR, IDENTITY+ANCHOR).replace(OLD_KEY, NEW_KEY)


def original(text):
    if text.count(IDENTITY) != 1 or text.count(NEW_KEY) != 2:
        raise ValueError('not the complete producer-identity repair')
    old = text.replace(IDENTITY, '').replace(NEW_KEY, OLD_KEY)
    if transform(old) != text:
        raise ValueError('producer-identity repair drift')
    return old
