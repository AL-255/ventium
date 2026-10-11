"""Extract ACK control without leaving branches of a preprocessed data mux.

The R1 regex stopped at the first semicolon of a conditional payload mux,
leaving its alternate branch behind. Preserve that failed proof input and
remove the entire data-only span up to the next ACK assignment instead.
"""
import re
from prepare_fp_read_ack_split import PARENTS, transform, read_ack_block


def ack_block(source):
    marker = '  // core-side response: HIT (read) returns combinationally;'
    start = source.index('  always_comb begin', source.index(marker))
    end = source.index('\n`ifndef SYNTHESIS\n`ifndef VEN_L1D_COMB_ACK', start)
    block = re.sub(r'/\*.*?\*/|//[^\n]*', '', source[start:end], flags=re.S)
    block, count = re.subn(r'\bc_rdata\s*=.*?(?=\bc_ack\s*=)', '', block, flags=re.S)
    if count != 3 or 'c_rdata' in block:
        raise ValueError('response payload structure drift')
    depth = 0
    for directive in re.findall(r'^`(ifdef|ifndef|else|endif)\b', block, re.M):
        if directive in ('ifdef', 'ifndef'): depth += 1
        elif directive == 'endif': depth -= 1
        elif depth < 1: raise ValueError('orphan else')
        if depth < 0: raise ValueError('orphan endif')
    if depth: raise ValueError('unclosed conditional')
    return block
