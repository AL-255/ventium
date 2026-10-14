"""Rebase the exact proved fetch-fault arithmetic onto the current timing core.

This is not a new arithmetic design or an override of the historical recipe's
guard. The historical implementation is hash-checked; this revision has its own
exact parent contract and still changes only the two original expressions.
"""
import hashlib
import prepare_fetch_fault_page as original

PARENT='6c020b3c171fb422756a7874fb48cd32a683953ff5b95d44b708be3a7fa08b1c'
ORIGINAL='94f468e4c063e39f1d1eef45d27498f8d3ef43efa5e022aa1496118e01b3d38f'
with open(original.__file__,'rb') as stream:
    assert hashlib.file_digest(stream,'sha256').hexdigest()==ORIGINAL
OLD,NEW,PROBE_OLD,PROBE_NEW=original.OLD,original.NEW,original.PROBE_OLD,original.PROBE_NEW


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest()!=PARENT:
        raise ValueError('current fetch-fault parent drift')
    if source.count(OLD)!=1 or source.count(PROBE_OLD)!=1 or NEW in source:
        raise ValueError('current fetch-fault anchor drift')
    changed=source.replace(OLD,NEW).replace(PROBE_OLD,PROBE_NEW)
    assert changed.replace(NEW,OLD).replace(PROBE_NEW,PROBE_OLD)==source
    return changed
