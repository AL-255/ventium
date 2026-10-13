"""One-file transfer contract for the PRIME-COHERENCE CS-request derivative."""
import hashlib

import prepare_pipe_mem_cs_extent as cofactor

PARENTS = {'rtl/core/core.sv': cofactor.PRIME_PARENT}


def transform(source, name):
    if name not in PARENTS or hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('unreviewed CS-request transfer parent: '+name)
    return cofactor.transform(source)
