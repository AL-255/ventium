#!/usr/bin/env python3
"""Runtime PLL mailbox via exclusively claimed PS GPIO lines, never PCAP.

Requires ven_programmable_clock ABI1. No raw PS register writes, voltage change,
STEP or CPU fallback. Caller must first hold guest reset and drain DDR. Hardware
also checks that interlock before gating the core clock. The GPIO path runs from
the independent PS/reference clock and remains usable during MMCM reset/relock.
"""
import argparse
import fcntl
import json
import os
import struct
import time

# Linux GPIO cdev v1 UAPI, shared by x86_64 and aarch64. This board has v1.
CHIP_INFO = 0x8044b401
LINE_HANDLE = 0xc16cb403
GET_VALUES = 0xc040b408
SET_VALUES = 0xc040b409
HANDLE = struct.Struct('<64II64B32sIi')
COMMAND_LINES = tuple(range(110,126))   # MIO78 + EMIO32..47
STATUS_LINES = tuple(range(142,173))    # MIO78 + EMIO64..94; bit31 is fixed 0


def decode(raw):
    if not isinstance(raw,int) or raw >> 16 != 0x504c or (raw >> 14) & 3 != 1:
        raise ValueError(f'not programmable-clock ABI1: {raw:08x}')
    return dict(raw=f'{raw:08x}', divider=raw & 127,
        clock_enabled=bool(raw & 128), busy=bool(raw & 256), error=bool(raw & 512),
        locked=bool(raw & 1024), ack=(raw >> 11) & 1,
        safe=bool(raw & 4096), mmcm_reset=bool(raw & 8192))


class GpioMailbox:
    def __init__(self, chip='/dev/gpiochip1'):
        self.chip = self.input_fd = self.output_fd = None
        try:
            self.chip = os.open(chip, os.O_RDONLY | os.O_CLOEXEC)
            info = bytearray(68)
            fcntl.ioctl(self.chip, CHIP_INFO, info, True)
            name,label,lines = struct.unpack('<32s32sI',info)
            if label.rstrip(b'\0') != b'zynqmp_gpio' or lines != 174:
                raise ValueError(f'wrong GPIO chip: {(name,label,lines)!r}')
            self.input_fd = self.request(STATUS_LINES, 1)
            decode(self.read())  # Unknown image: fail BEFORE claiming outputs.
        except BaseException:
            self.close()
            raise

    def request(self, lines, flags):
        payload = bytearray(HANDLE.pack(*(list(lines)+[0]*(64-len(lines))),
            flags,*([0]*64),b'ventium-pll',len(lines),0))
        fcntl.ioctl(self.chip,LINE_HANDLE,payload,True)
        fd = HANDLE.unpack(payload)[-1]
        if fd < 0:
            raise OSError('GPIO request returned invalid handle')
        os.set_inheritable(fd,False)
        return fd

    def read(self):
        values = bytearray(64)
        fcntl.ioctl(self.input_fd,GET_VALUES,values,True)
        return sum((values[i] & 1) << i for i in range(len(STATUS_LINES)))

    def claim_output(self):
        if self.output_fd is None:
            self.output_fd = self.request(COMMAND_LINES,2)

    def write(self, value):
        if self.output_fd is None or not 0 <= value <= 65535:
            raise ValueError('invalid/unclaimed command')
        values = bytearray((value >> i) & 1 if i < 16 else 0 for i in range(64))
        fcntl.ioctl(self.output_fd,SET_VALUES,values,True)

    def close(self):
        for attr in ('output_fd','input_fd','chip'):
            fd = getattr(self,attr,None)
            if fd is not None:
                os.close(fd)
                setattr(self,attr,None)


def change(box, divider, *, monotonic=time.monotonic, sleep=time.sleep):
    if type(divider) is not int or not 10 <= divider <= 50:
        raise ValueError('integer divider must be 10..50 (1000/divider MHz)')
    before = decode(box.read())
    if before['busy'] or not before['safe']:
        raise ValueError('requires idle PLL controller, guest reset and drained DDR')
    # Error/gated state is intentionally accepted: the same mailbox recovers it.
    box.claim_output()
    # Outputs initially become zero. Set the acknowledged toggle with INVALID
    # magic first, so even non-atomic GPIO implementations cannot invent a request.
    box.write(before['ack'] << 15)
    sleep(.002)
    staged = before['ack'] << 15 | 0xc1 << 7 | divider
    box.write(staged)
    sleep(.002)
    ready = decode(box.read())
    if ready['busy'] or not ready['safe'] or ready['ack'] != before['ack']:
        raise ValueError('PLL ownership/interlock changed while staging command')
    request = staged ^ 0x8000
    box.write(request)  # Only the request bit changes.
    deadline = monotonic()+2
    stable = None
    samples = []
    while monotonic() < deadline:
        raw = box.read()
        status = decode(raw)
        if not samples or samples[-1] != status:
            samples.append(status)
        if status['ack'] == request >> 15 and not status['busy']:
            if status['error']:
                raise RuntimeError(f'PLL rejected/failed request: {status}')
            if not status['safe'] or not status['locked'] or not status['clock_enabled'] or status['mmcm_reset'] or status['divider'] != divider:
                raise RuntimeError(f'PLL ACK without required final state: {status}')
            # Two equal observations reject torn status reads at ACK transitions.
            if stable == raw:
                return dict(before=before, after=status, observations=samples,
                    requested_divider=divider, expected_mhz=1000/divider,
                    reprogrammed=False, measured_mhz=None, acceptance=False)
            stable = raw
        else:
            stable = None
        sleep(.002)
    raise TimeoutError('PLL acknowledgement timed out; image was NOT reprogrammed')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--divider',type=int,help='omit for read-only status')
    args = ap.parse_args()
    if os.geteuid() != 0:
        raise PermissionError('board root required')
    box = GpioMailbox()
    try:
        print(json.dumps(decode(box.read()) if args.divider is None else change(box,args.divider),indent=2))
    finally:
        box.close()


if __name__ == '__main__':
    main()
