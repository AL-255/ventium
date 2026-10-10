#!/usr/bin/env python3
"""Private, default-off factoring of the 16-byte prefix/EX successor gather."""
import re

FLAG = 'VEN_IC_PREFIX_SPAN'
HEADER = 'core_ic_prefix_span.svh'
OLD = "        refdecode_ibuf[i] = ic_byte(p54_prefix_ex_flin + 32'(i));"
ANCHOR = '  // END IC FRONT SPAN\n'


def transform(source):
    if FLAG in source or HEADER in source or source.count(OLD) != 1:
        raise ValueError('already applied or successor gather contract drift')
    if source.count(ANCHOR) != 1 or 'localparam int IWORDS = 4;' not in source:
        raise ValueError('require one existing shared probe and a 16-byte window')
    if source.count('function automatic logic [IC_WAYW:0] ic_front_probe(') != 1:
        raise ValueError('require the existing ordered probe function')
    pattern = (r'for \(int i=0; i<IWORDS\*4; i\+\+\) begin\s*'
               r'`ifdef VEN_P54_PREFIX_EX_CHAIN\s*'
               r'(?://[^\n]*\n\s*)*if \(state == S_EXEC\)\n' + re.escape(OLD))
    if len(re.findall(pattern, source)) != 1:
        raise ValueError('successor consumer is not the reviewed state-only mux')
    source = source.replace(OLD,
        '`ifdef '+FLAG+'\n        refdecode_ibuf[i] = ic_prefix_bytes[i];\n'
        '`else\n'+OLD+'\n`endif')
    return source.replace(ANCHOR, ANCHOR+'\n`ifdef '+FLAG+'\n'
        '  `include "'+HEADER+'"\n`endif\n')
