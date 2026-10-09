#!/usr/bin/env python3
"""Generate post-queue INT3/#GP cases from the pinned ordinary m64 workload.

The original fixture is never edited. Insert only guest IDT setup, a real event
after independent integer work, and an ordinary architectural handler.
"""
import argparse
from pathlib import Path


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('event fixture anchor missing or ambiguous: '+old)
    return text.replace(old, new)


def transform(text):
    text = once(text, '    movl $0x12023,0x11000', '''    movl $event_handler,%eax
    movw %ax,0x1018
    movw %ax,0x1068
    movw $0x18,0x101a
    movw $0x18,0x106a
    movw $0x8e00,0x101c
    movw $0x8e00,0x106c
    shrl $16,%eax
    movw %ax,0x101e
    movw %ax,0x106e
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0x12023,0x11000''')
    text = once(text, '    fninit\n', '    movl $0,0x8f2c0\n    fninit\n')
    text = once(text, '    movl $0x000063,0x12000', '''    movl $0x000063,0x12000
    # The ordinary loop needs only the GDT's page. Events also read the IDT.
    movl $0x001063,0x12004''')
    text = once(text, 'integer_end:\n    fwait', '''integer_end:
    .global event_op,event_after
#if EVENT_GP
    movl $0x28,%edx
event_op:
    movw %dx,%ds
#else
event_op:
    int3
#endif
event_after:
    fwait''')
    text = once(text, '    cmpl $64,%eax\n', '''    cmpl $16,0x8f2c0
    jne fail
    cmpl $64,%eax
''')
    text = once(text, 'fail:\n', '''    .global event_handler
event_handler:
    pushal
#if EVENT_GP
    cmpl $0x28,32(%esp)
    jne fail
    cmpl $event_op,36(%esp)
    jne fail
    cmpl $0x18,40(%esp)
    jne fail
    movl $event_after,36(%esp)
#else
    cmpl $event_after,32(%esp)
    jne fail
    cmpl $0x18,36(%esp)
    jne fail
#endif
    fnstenv 0x8f240
    cmpl $source_op,0x8f24c
    jne fail
    cmpw $0x18,0x8f250
    jne fail
    cmpl $(0x8f100+DATA_OFFSET),0x8f254
    jne fail
    cmpw $0x20,0x8f258
    jne fail
    # Read the already-saved FSW. The pinned QEMU's FNSTSW AX also changes
    # FIP; its memory/environment forms retain the architectural pointer.
    movzwl 0x8f244,%eax
    andl $0x3800,%eax
#if KIND >= 6
    cmpl $0x2800,%eax
#else
    cmpl $0x3000,%eax
#endif
    jne fail
    # Complete QEMU/RTL traces check all 80-bit stack values in the handler.
    # Do not execute a data operation here: it changes FIP/FDP, and the pinned
    # QEMU FLDENV does not restore those fields. The unchanged main loop also
    # stores/checks the result after IRET. No trace fields are omitted.
    incl 0x8f2c0
    popal
#if EVENT_GP
    addl $4,%esp
#endif
    iretl
fail:
''')
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    with args.out.open('x') as f:
        f.write(transform(args.source.read_text()))
