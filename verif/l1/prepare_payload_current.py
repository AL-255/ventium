"""Compose the tested payload-kind and overlap cuts on the I-fill timing core.

Lift only exact, context-checked hunks from the original four-file proposal.
The default-off source must retain every current timing fix. Neither a source
composition check nor earlier isolated proofs qualify the combined whole core.
"""
from difflib import SequenceMatcher
import hashlib

import prepare_payload_code_hint as payload
import prepare_payload_fetch_kind as fetch
import prepare_pair_overlap_current as overlap

CURRENT = dict(payload.HASHES, **{
    'rtl/core/core.sv': '853bcdaaa61c25dac567774d4aeb67219af2b7367199a527a850142e4e72ecaf',
    'rtl/mem/ven_l1d.sv': overlap.PARENT,
})


def lift(current, before, after):
    """Apply nonoverlapping four-line-context hunks; reject absent/duplicate anchors."""
    old, new = before.splitlines(keepends=True), after.splitlines(keepends=True)
    groups = list(SequenceMatcher(None, old, new, autojunk=False).get_grouped_opcodes(4))
    replacements = []
    for group in groups:
        old_block = ''.join(old[group[0][1]:group[-1][2]])
        new_block = ''.join(new[group[0][3]:group[-1][4]])
        if not old_block or current.count(old_block) != 1:
            raise ValueError('payload hunk context drift or ambiguity: '+old_block[:100])
        replacements.append((old_block, new_block))
    for old_block, new_block in replacements:
        if current.count(old_block) != 1:
            raise ValueError('payload hunks overlap')
        current = current.replace(old_block, new_block)
    return current


def transform(current, original):
    if set(current) != set(CURRENT):
        raise ValueError('need all four current interface sources')
    for name, digest in CURRENT.items():
        if hashlib.sha256(current[name].encode()).hexdigest() != digest:
            raise ValueError('current parent drift/reapplication: '+name)
    proposal = payload.transform(original)  # Independently checks all original hashes.
    proposal['rtl/core/core.sv'] = fetch.transform(proposal['rtl/core/core.sv'])
    base = dict(current)
    base['rtl/mem/ven_l1d.sv'] = overlap.transform(base['rtl/mem/ven_l1d.sv'])
    result = {name: lift(base[name], original[name], proposal[name]) for name in CURRENT}
    for name in CURRENT:
        if payload.select_hint_branch(result[name], False).split() != base[name].split():
            raise ValueError('flag-off changed current source: '+name)
    return result
