#!/usr/bin/env python3
"""Explicit private integration of the proved residency helper, default OFF.

Only three frontend residency assignments change. Original miss addresses,
guard order, byte selection, arbitrary-target queries and non-BRAM code stay
unchanged. The caller miter must use these exact extracted replacement bodies.
"""
import re

FLAG = 'VEN_IC_RESIDENCY_SPAN'
HEADER = 'core_ic_residency_span.svh'
CALLERS = ('pipe_bytes_ok','pf_miss_fa','v_bytes_ok')
REPLACEMENTS = (
    ('ic_present(flin + {28\'d0,u_d.len} + {28\'d0,v_d.len} - 32\'d1)',
     "ic_res_present_end({2'b0,u_d.len}+{2'b0,v_d.len})"),
    ("ic_present(flin + {28'd0,u_d.len} - 32'd1)",
     "ic_res_present_end({2'b0,u_d.len})"),
    ("ic_present(flin + {26'd0,fp_pipe_decode_win_last})",
     'ic_res_present_offset(fp_pipe_decode_win_last)'),
    ("ic_present(flin + {28'd0,u_d.len})",
     "ic_res_present_offset({2'b0,u_d.len})"),
    ('ic_present(flin)', 'ic_front_a[IC_WAYW]'),
)


def assignments(source):
    result = {}
    for name in CALLERS:
        matches = re.findall(r'(?m)^\s*'+name+r'\s*=.*?;',source,re.S)
        if len(matches) != 1 or 'ic_present(' not in matches[0]:
            raise ValueError('missing/ambiguous/unexpected raw caller '+name)
        result[name] = matches[0].strip()
    return result


def replacement_bodies(source):
    # All decoded lengths are four bits; window offsets are exactly 5/6.
    if not re.search(r'logic\s+\[3:0\]\s+d_len;',source):
        raise ValueError('reference length width drift')
    if not re.search(r'wire\s+\[5:0\]\s+fp_pipe_decode_win_last\s*=.*?6\'d6\s*:\s*6\'d5;',source):
        raise ValueError('decode window bound drift')
    result = assignments(source)
    counts = [0]*len(REPLACEMENTS)
    for name,old in result.items():
        new = old
        for i,(raw,factored) in enumerate(REPLACEMENTS):
            counts[i] += new.count(raw)
            new = new.replace(raw,factored)
        if 'ic_present(' in new:
            raise ValueError('unreviewed raw caller in '+name)
        result[name] = new
    if counts != [1,1,2,1,2]:
        raise ValueError('caller replacement counts drift: '+repr(counts))
    return result


def transform(source):
    if FLAG in source or HEADER in source:
        raise ValueError('already integrated')
    originals = assignments(source)
    replacements = replacement_bodies(source)
    anchor = '  // END IC FRONT SPAN'
    if source.count(anchor) != 1:
        raise ValueError('missing front-span boundary')
    source = source.replace(anchor,anchor+'\n\n`ifdef '+FLAG+'\n'
        '  // A private combinational sharing experiment, never a timing waiver.\n'
        '  `include "'+HEADER+'"\n`endif')
    for name in CALLERS:
        old,new = originals[name],replacements[name]
        if source.count(old) != 1:
            raise ValueError('caller no longer unique: '+name)
        source = source.replace(old,'\n`ifdef '+FLAG+'\n    '+new+
            '\n`else\n    '+old+'\n`endif',1)
    return source
