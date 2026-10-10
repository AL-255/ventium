#!/usr/bin/env python3
"""Second private sharing stage: returned-line residency, with guards intact.

Apply only after prepare_integration.transform. The same default-off flag
selects both stages. No new cache state, read port or issue permission is added.
The old expressions remain verbatim in the disabled preprocessor branches.
"""
import re

from prepare_integration import FLAG, HEADER

MARKER = '// IC BUFFERED SPAN CALLERS: private identity-preserving sharing'
REPLACEMENTS = (
    ("ic_buffered(flin + 32'(IWORDS*4 - 1))",
     "ic_res_buffered_offset(6'(IWORDS*4 - 1))", 3),
    ("ic_buffered(flin + {28'd0,sfetch_short_len_q} - 32'd1)",
     "ic_res_buffered_end({2'b0,sfetch_short_len_q})", 1),
    ("ic_buffered(flin + {28'd0,d_len} - 32'd1)",
     "ic_res_buffered_end({2'b0,d_len})", 3),
    ("ic_buffered(flin + 32'd1)", "ic_res_buffered_offset(6'd1)", 1),
    ('ic_buffered(flin)', 'ic_res_a_buffered', 7),
)


def changed_lines(source):
    if source.count('`include "'+HEADER+'"') != 1 or source.count('`ifdef '+FLAG) != 4:
        raise ValueError('require exact first-stage presence integration')
    if MARKER in source:
        raise ValueError('buffered stage already integrated')
    if 'localparam int IWORDS = 4;' not in source:
        raise ValueError('slow window must remain exactly 16 bytes')
    for name in ('d_len','sfetch_short_len_q'):
        if not re.search(r'logic\s+\[3:0\]\s+'+name+r'\s*;', source):
            raise ValueError('four-bit length contract changed: '+name)
    counts = [0]*len(REPLACEMENTS)
    result = []
    for line in source.splitlines(keepends=True):
        if not re.search(r'^\s*(?:&&.*)?\bic_buffered\(', line):
            continue
        new = line
        for i,(raw,factored,_) in enumerate(REPLACEMENTS):
            counts[i] += new.count(raw)
            new = new.replace(raw,factored)
        if 'ic_buffered(' in new:
            raise ValueError('unreviewed buffered endpoint in caller')
        result.append((line,new))
    if counts != [n for _,_,n in REPLACEMENTS] or len(result) != 15:
        raise ValueError('buffered call-site count drift: '+repr(counts))
    return result


def transform(source):
    lines = changed_lines(source)
    # Replace by line identity in one pass: several original lines deliberately
    # repeat. No whole-source global replacement may transform the old fallback.
    mapping = dict(lines)
    out = []
    for line in source.splitlines(keepends=True):
        if line in mapping:
            out.extend(['`ifdef '+FLAG+'\n',mapping[line],
                        '`else\n',line,'`endif\n'])
        else:
            out.append(line)
    return MARKER+'\n'+''.join(out)
