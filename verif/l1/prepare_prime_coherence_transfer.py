"""Compose the two audited commit cofactors for the FP-WIDE-CONTEXT parent.

The native core's immediate parent is MC-LOCAL; the PC/hardware parent is one
generation earlier. Three headers, not two, must therefore be transferred.
"""
import hashlib

import prepare_mc_local_commit as local
import prepare_prime_coherence_cut as hint

PARENTS = dict(hint.PARENTS)
PARENTS['rtl/core/core_mem_chain.svh'] = local.PARENTS['core_mem_chain.svh']
CHILDREN = {
    'rtl/core/core_mem_chain.svh': hint.PARENTS['rtl/core/core_mem_chain.svh'],
    'rtl/core/core_agi_resident_prime.svh': '2fe36debf81b73a11d0c03efce591518a5260ccf0067833406bfb81586c926ab',
    'rtl/core/core_ref_operand_prime.svh': '20c28f6aba142ba4893a3aa5cd8e1203e1b9c3d925f5ad8c3ce48ffd005fac8c',
}


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def transform(source, name):
    """Byte-exact per-file exporter; validate_sources is the full admission."""
    if name not in CHILDREN or digest(source) != PARENTS[name]:
        raise ValueError('unreviewed PC/hardware parent: '+name)
    if name.endswith('/core_mem_chain.svh'):
        edits = local.edits(source)
    else:
        kind = 'agi' if name.endswith('/core_agi_resident_prime.svh') else 'ref'
        edits = [hint.edits(source, kind)]
    result = source
    for old, new in edits:
        assert result.count(old) == 1
        result = result.replace(old, new)
    assert digest(result) == CHILDREN[name]
    return result


def validate_sources(inputs):
    if set(inputs) != set(PARENTS):
        raise ValueError('need the complete eight-file transfer contract')
    for name, expected in PARENTS.items():
        if digest(inputs[name]) != expected:
            raise ValueError('transfer source drift: '+name)
    stage = dict(inputs)
    stage['rtl/core/core_mem_chain.svh'] = local.transform({
        name: inputs['rtl/core/'+name] for name in local.PARENTS})
    result = hint.transform(stage)
    assert sorted(n for n in inputs if inputs[n] != result[n]) == sorted(CHILDREN)
    for name in CHILDREN:
        assert result[name] == transform(inputs[name], name)
    return result
