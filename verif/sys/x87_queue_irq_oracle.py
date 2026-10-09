#!/usr/bin/env python3
"""Cold QEMU/Pentium IRQ5 oracle: real PIC input, no guest-state injection.

GDB single-step suppresses interrupts. At the named post-integer boundary we
raise the physical master PIC input and continue to a debugger breakpoint at
the handler entry. Its observed entry state goes in a separately labelled
event stream, not an instruction retirement. We then step the actual handler.
"""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'verif/qemu-trace'))
import gen_trace as gt
import tracefmt


def generate(image, out, marker, boundary, handler, count=64):
    for option in ('VEN_IRQ_SCHED', 'VEN_IRQ_SCHED_EXCLUSIVE',
                   'VEN_CSEIP_SCHED', 'VEN_CSEIP_EXCLUSIVE'):
        assert option not in os.environ, f'unrelated QEMU IRQ replay option is active: {option}'
    directory = Path(out).parent
    qmp_path, qtest_path = directory / 'qmp.sock', directory / 'qtest.sock'
    # Ask the OS for a free local GDB port (QEMU has no inherited socket option).
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    qemu = ROOT / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    cmd = [str(qemu), '-display', 'none', '-S', '-gdb', f'tcp::{port}',
           '-machine', 'pc', '-cpu', 'pentium,apic=off', '-m', '32', '-icount', 'shift=0,sleep=off',
           '-device', 'isa-debug-exit,iobase=0xf4,iosize=4', '-bios', str(image),
           '-d', 'int', '-D', str(directory / 'qemu-interrupts.log'),
           '-qmp', f'unix:{qmp_path},server=on,wait=off',
           '-qtest', f'unix:{qtest_path},server=on,wait=off']
    rsp = None
    sockets = []
    injected = 0
    with (directory / 'qemu-process.log').open('w') as process_log:
        proc = subprocess.Popen(cmd, stdout=process_log, stderr=process_log, pass_fds=(9,),
                                env=dict(os.environ, VEN_PIC_LOG='1'))
        try:
            def connect(path):
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(20)
                for _ in range(200):
                    try:
                        s.connect(str(path))
                        sockets.append(s)
                        return s.makefile('rwb', buffering=0)
                    except (FileNotFoundError, ConnectionRefusedError):
                        if proc.poll() is not None:
                            raise RuntimeError(f'QEMU exited {proc.returncode}')
                        time.sleep(.01)
                raise TimeoutError(path)

            qmp, qtest = connect(qmp_path), connect(qtest_path)
            assert 'QMP' in json.loads(qmp.readline())

            def monitor(command, **arguments):
                qmp.write((json.dumps(dict(execute=command, arguments=arguments)) + '\n').encode())
                while True:
                    reply = json.loads(qmp.readline())
                    if 'event' in reply:
                        continue
                    assert 'return' in reply, reply
                    return reply['return']

            monitor('qmp_capabilities')
            pics = []
            for entry in monitor('qom-list', path='/machine/unattached'):
                if entry['type'] == 'child<isa-i8259>':
                    path = '/machine/unattached/' + entry['name']
                    if monitor('qom-get', path=path, property='master'):
                        pics.append(path)
            assert len(pics) == 1, pics

            def irq(level):
                qtest.write(f'set_irq_in {pics[0]} unnamed-gpio-in 5 {level}\n'.encode())
                assert qtest.readline().strip() == b'OK'

            # This standalone core-pin test deliberately uses the external
            # PIC directly. The RTL no-L2 top has no LAPIC device fabric, so
            # the pinned QEMU Pentium's APIC feature is explicitly disabled.
            # This is not a full platform/LAPIC or CPUID qualification.
            cpus = monitor('query-cpus-fast')
            assert len(cpus) == 1
            assert monitor('qom-get', path=cpus[0]['qom-path'], property='apic') is False
            # Dedicated IRQ5 has no device driving it and resets low.
            rsp = gt.RSPClient(port=port, timeout=20.0, verbose=False)
            rsp.handshake()
            # Permit external/APIC interrupt polling while single-stepping,
            # but retain NOTIMER. Otherwise an APIC POLL raised during setup
            # remains masked until continue and delays the intended IRQ by a TB.
            rsp.send('Qqemu.sstep=5')
            assert rsp.recv() == b'OK'
            layout = rsp.discover_layout()
            raw = rsp.read_g()
            layout.anchor_tail(len(raw))
            assert layout.has('st0') and layout.has('cr0')
            eip, flags, gpr, seg, fp = gt.regs_to_fields(layout, raw)
            sysr = gt.sysregs_from_raw(layout, raw)
            previous_pc = None
            with Path(out).open('w') as trace, (directory / 'qemu-irq-events.vtrace').open('w') as events:
                trace.write(tracefmt.dumps(tracefmt.header('qemu-gdbstub', 'func', x87=True,
                    sys=True, note='Cold pentium,apic=off (standalone PIC/core-pin); real qtest IRQ5; no state injection')) + '\n')
                events.write(tracefmt.dumps(tracefmt.header('qemu-gdbstub', 'func', x87=True,
                    sys=True, note='IRQ ENTRY STATES ONLY: not instruction retirements; observed after real PIC INTA')) + '\n')
                for n in range(10000):
                    if previous_pc == marker:
                        assert eip == boundary and flags & 0x200, (eip, flags)
                        assert injected < count
                        rsp.send(f'Z1,{handler:x},1')
                        assert rsp.recv() == b'OK'
                        # Pulse the edge-triggered DEVICE input. The 8259
                        # latches IRR and holds its CPU-facing INT until INTA,
                        # exactly like the held CPU pin in the RTL hook. Lower
                        # now while PIC INT is still high: lowering after INTA
                        # queues an APIC POLL which can create a zero-instruction
                        # GDB step at the handler entry.
                        irq(1)
                        irq(0)
                        if not injected:
                            print(monitor('human-monitor-command', **{'command-line': 'info pic'}), flush=True)
                        rsp.send('c')
                        stop = gt.StopReply(rsp.recv())
                        assert stop.kind == 'stop' and stop.signal == 5
                        raw = rsp.read_g()
                        eip, flags, gpr, seg, fp = gt.regs_to_fields(layout, raw)
                        sysr = gt.sysregs_from_raw(layout, raw)
                        assert eip == handler and not flags & 0x200, (eip, handler, flags)
                        assert int.from_bytes(rsp.read_mem(gpr['esp'], 4), 'little') == boundary
                        events.write(tracefmt.dumps(tracefmt.func_record(injected, boundary,
                            flags, gpr, seg, x87=fp, sysregs=sysr)) + '\n')
                        rsp.send(f'z1,{handler:x},1')
                        assert rsp.recv() == b'OK'
                        injected += 1
                        print(f'[QEMU-IRQ] n={injected} vector=69 saved_pc={boundary:08x} handler={handler:08x}', flush=True)
                    pc = eip
                    # This fixture has flat CS in protected mode. The pinned
                    # GDB XML exports no CS hidden base; real mode still uses
                    # the ordinary selector*16 fetch base.
                    base = 0 if sysr['cr0'] & 1 else seg['cs'] << 4
                    linear = (sysr.get('cs_base', base) + pc) & 0xffffffff
                    insn = rsp.read_mem(linear, 15)
                    try:
                        stop = gt.StopReply(rsp.step())
                    except gt.RSPError as error:
                        if 'closed' not in str(error):
                            raise
                        break
                    if stop.kind in ('exit', 'term'):
                        break
                    assert stop.kind == 'stop' and stop.signal == 5, vars(stop)
                    raw = rsp.read_g()
                    eip, flags, gpr, seg, fp = gt.regs_to_fields(layout, raw)
                    sysr = gt.sysregs_from_raw(layout, raw)
                    assert eip != handler, 'unscheduled IRQ reached handler during ordinary stepping'
                    trace.write(tracefmt.dumps(tracefmt.func_record(n, pc, flags, gpr, seg,
                        bytes_=insn.hex(), x87=fp, sysregs=sysr)) + '\n')
                    previous_pc = pc
                else:
                    raise AssertionError('QEMU instruction limit reached')
            assert injected == count, injected
            assert proc.wait(timeout=5) == 133, 'QEMU guest did not report PASS'
            vectors = re.findall(r'^Servicing hardware INT=0x([0-9a-f]+)$',
                                 (directory / 'qemu-interrupts.log').read_text(), re.M)
            assert vectors == ['45'] * count, ('unexpected hardware interrupt delivery', vectors)
            print(f'[QEMU-IRQ] PASS actual_pic_injections={injected}', flush=True)
        finally:
            if rsp is not None:
                rsp.close()
            for s in sockets:
                s.close()
            gt._terminate(proc)
