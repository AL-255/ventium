#!/usr/bin/env python3
"""Keep the platform request port closed until reset/tag initialization finishes."""


def transform(text):
    before='assign CPU_BUSY       = (state == IDLE) ? DDRAM_BUSY :'
    if text.count(before)!=2:
        raise ValueError('missing/ambiguous original streamed and legacy busy assignments')
    after='''// START cannot consume a CPU command. Its duration depends on cache depth;
// callers must use BUSY, not an assumed reset delay. Keep both reset pipeline
// stages and the complete tag walk behind the same ordinary request handshake.
assign CPU_BUSY       = (RESET || RESET_1 || (state == START)) ? 1'b1 :
                        (state == IDLE) ? DDRAM_BUSY :'''
    return text.replace(before,after)
