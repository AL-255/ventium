#!/usr/bin/env python3
"""Direct-user-only host optimization for the full-address L1/debug model.

The inherited runtime guard still rejects active AXI, system mode, device
models, tracing, save/restore and debugger control. This does not accelerate
or alter any guest clock. It must pass exact same-model A/B state comparison
before a benchmark can use --skip-unchanged-settle.
"""
from prepare_inactive_board_settle import prepare as prepare_board


def prepare(text):
    text = prepare_board(text)
    old = '''#if !defined(VEN_L1_AXI) || !defined(VEN_DBG_CORE) || !defined(VEN_KV260_SOC)
#error "inactive-board qualification requires the complete board/debug harness"
#endif'''
    new = '''#if !defined(VEN_L1_AXI) || !defined(VEN_DBG_CORE) || defined(VEN_KV260_SOC)
#error "inactive-L1 qualification requires full-address L1/debug without KV260 remapping"
#endif'''
    if text.count(old) != 1:
        raise ValueError('missing board-profile compile guard')
    text = text.replace(old, new)
    for old, new in (
        ('#include "inactive_board_settle_guard.h"', '#include "inactive_l1_settle_guard.h"'),
        ('require_inactive_board_settle(*top)', 'require_inactive_l1_settle(*top)'),
    ):
        if text.count(old) != 1:
            raise ValueError('missing inherited inactive guard')
        text = text.replace(old, new)
    return text
