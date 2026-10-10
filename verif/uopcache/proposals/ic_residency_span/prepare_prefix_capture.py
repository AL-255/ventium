#!/usr/bin/env python3
"""Complete prefix-span integration at its sequential byte consumer.

The first experiment changed the live decoder but missed this included task.
Its retained generic gather could therefore keep the original lookup cone.
Only the byte RHS changes. Ownership, loop bound and nonblocking writes stay.
"""
import re

FLAG = 'VEN_IC_PREFIX_SPAN'
OLD = "        ibuf[i]<=ic_byte(p54_prefix_ex_flin+32'(i));"
NEW = '        ibuf[i]<=ic_prefix_bytes[i];'


def transform(source):
    if FLAG in source or 'ic_prefix_bytes' in source or source.count(OLD) != 1:
        raise ValueError('already applied or sequential gather contract drift')
    pattern = (r'`ifdef VEN_P54_PREFIX_EX_CHAIN\s*'
               r'if \(p54_prefix_ex_take\) begin\s*'
               r'(?://[^\n]*\n\s*)*capture_reference_decode\(next_eip\);\s*'
               r'for \(int i=0;i<IWORDS\*4;i\+\+\)\n' + re.escape(OLD))
    if len(re.findall(pattern, source)) != 1:
        raise ValueError('not the reviewed retiring-owner byte-copy loop')
    return source.replace(OLD, '`ifdef '+FLAG+'\n'+NEW+'\n`else\n'+OLD+'\n`endif')


def audit_consumers(core, retire):
    """Check both original/flagged consumers, not just the core.sv text."""
    for source, old, new in (
        (core, "        refdecode_ibuf[i] = ic_byte(p54_prefix_ex_flin + 32'(i));",
         '        refdecode_ibuf[i] = ic_prefix_bytes[i];'),
        (retire, OLD, NEW),
    ):
        expected = '`ifdef '+FLAG+'\n'+new+'\n`else\n'+old+'\n`endif'
        if source.count(expected) != 1 or source.count(old) != 1 or source.count(new) != 1:
            raise ValueError('require both exact default-off byte consumers')
    if core.count('`include "core_ic_prefix_span.svh"') != 1:
        raise ValueError('missing shared gather producer')

