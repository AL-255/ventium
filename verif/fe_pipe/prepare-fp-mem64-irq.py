#!/usr/bin/env python3
"""Cold flat-CS m64 queue fixture with a real external IRQ boundary."""
import argparse
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('event', HERE/'prepare-fp-mem64-event.py')
event = importlib.util.module_from_spec(spec)
spec.loader.exec_module(event)


def transform(text):
    text = event.transform(text)
    # Reuse the exact handler's metadata/TOP/result checks, but install it at
    # external vector 69. No INT instruction or internal-state injection.
    for old, new in (('0x1018','0x1228'),('0x101a','0x122a'),
                     ('0x101c','0x122c'),('0x101e','0x122e')):
        if text.count(old) != 1:
            raise ValueError('IRQ descriptor anchor drifted: '+old)
        text = text.replace(old, new)
    text = event.once(text, '    fninit\n', '    fninit\n    sti\n')
    text = event.once(text, 'integer_begin:\n    .rept 4', '''integer_begin:
    incl %eax
    .global irq_boundary
irq_boundary:
    # Privileged serial form cannot pair with the marker. It also establishes
    # an exact next-instruction boundary for the held-pin and real-PIC oracles.
    movl %cr0,%edx
    incl %ebx
    incl %esi
    incl %edi
    .rept 3''')
    text = event.once(text, '''integer_end:
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
    fwait''', 'integer_end:\n    fwait')
    text = event.once(text, '    cmpl $event_after,32(%esp)', '    cmpl $irq_boundary,32(%esp)')
    text = event.once(text, '    incl 0x8f2c0\n', '''    incl 0x8f2c0
    # Ordinary master-PIC EOI: meaningful for the independent QEMU device,
    # harmless for the standalone RTL's already-completed INTA handshake.
    movb $0x20,%al
    outb %al,$0x20
''')
    # Remap/unmask only the dedicated external IRQ5. No periodic timer input.
    text = event.once(text, '    fninit\n    sti\n', '''    movb $0x11,%al
    outb %al,$0x20
    movb $0x40,%al
    outb %al,$0x21
    movb $4,%al
    outb %al,$0x21
    movb $1,%al
    outb %al,$0x21
    movb $0xdf,%al
    outb %al,$0x21
    movb $0xff,%al
    outb %al,$0xa1
    fninit
    sti
''')
    return '#if RELOC || EVENT_GP\n#error IRQ oracle requires flat CS and external events\n#endif\n'+text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    with args.out.open('x') as f:
        f.write(transform(args.source.read_text()))
