"""Rebase the guarded bank-overlap cut without losing the same-line ACK fix.

Only prepare a private source. The old predicate proof is reusable because all
of its extracted ACK/overlap/lookup equations are byte-identical. The combined
cache and whole core still need native qualification; no timing gain is implied.
"""
import hashlib

import prepare_pair_now_ack_cut as same_line
import prepare_pair_overlap_ack_cut as overlap

PARENT = 'debab0ccd20eef18b3c2e5e9f349350e4f2b48eff8bd4b29213c5658fe499e6d'


def restore_parent(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('current paired-overlap parent drift/reapplication')
    now = same_line.extract(source)
    if now.count(same_line.NEW) != 1:
        raise ValueError('same-line ACK fix drift')
    before = now.replace(same_line.NEW, same_line.OLD)
    block = same_line.COMMENT+now+same_line.witness(before)
    if source.count(block) != 1:
        raise ValueError('same-line block/witness drift')
    old = source.replace(block, before)
    if hashlib.sha256(old.encode()).hexdigest() != same_line.PARENT:
        raise ValueError('same-line inverse did not recover exact qualified source')
    return old


def transform(source):
    old = restore_parent(source)
    qualified = overlap.transform(old)
    before = overlap.extract_lookup(old)
    after = overlap.extract_lookup(qualified)
    if overlap.extract_lookup(source) != before or source.count(before) != 1:
        raise ValueError('bank lookup no longer matches old proof')
    result = source.replace(before, overlap.OWNED+after+overlap.witness(before))
    if same_line.extract(result) != same_line.extract(source):
        raise ValueError('lost same-line return cut')
    return result
