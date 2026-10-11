"""Reuse frontend ownership probes only inside the checked fallthrough span.

The arbitrary-address descriptor API, guards, raw decoder, byte selection and
commit equations stay unchanged. No change is made when residency sharing is
disabled. This recipe applies to the independently checked timing-combo source.
"""
import hashlib

PARENT = '5d2044b045cf9fd99281ce4f246d79031e3460bc4017acc43a87515938fd0b37'
OLD = '''            ic_buffered(lin) && ic_buffered(lin+{28'd0,branch_d.len}-32'd1))
'''
NEW = '''`ifdef VEN_IC_RESIDENCY_SPAN
            // The outer guard proves pc=eip+off, off<=13. Thus lin=flin+off
            // modulo 2^32, and off+len<=28 even for an arbitrary 4-bit len.
            // Reuse the already returned frontend identities; neither a
            // present tag alone nor equal bytes establish buffer ownership.
            ic_res_buffered_offset({1'b0,off}) &&
            ic_res_buffered_end({1'b0,off}+{2'b0,branch_d.len}))
`else
''' + OLD + '''`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT or source.count(OLD) != 1:
        raise ValueError('branch-residency source drift')
    changed = source.replace(OLD, NEW)
    if changed.replace(NEW, OLD) != source:
        raise ValueError('non-reversible branch-residency edit')
    return changed
