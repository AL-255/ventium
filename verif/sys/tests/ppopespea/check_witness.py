#!/usr/bin/env python3
"""Closed POP-to-memory witnesses; import is pure, no DUT/model evaluation."""
import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SHARED = REPO / 'verif/sys/run-pverrw-gate.py'
spec = importlib.util.spec_from_file_location('ppopespea_contracts', SHARED)
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
tracefmt = contracts.tracefmt
MAX_INSN = 12000
OPCODES = {1: bytes.fromhex('67668f44240866cb'), 2: bytes.fromhex('8f442408'),
           3: bytes.fromhex('668f442408'), 4: bytes.fromhex('668f442408'),
           5: bytes.fromhex('8f442408'), 6: bytes.fromhex('668f442408'),
           7: bytes.fromhex('8f442408'), 8: bytes.fromhex('8f448c08'),
           9: bytes.fromhex('8f4424fc'), 10: bytes.fromhex('268f842400800100'),
           11: bytes.fromhex('8f4508'), 12: bytes.fromhex('8f442404'),
           13: bytes.fromhex('8f442408'), 14: bytes.fromhex('8f8424fa0f0000'),
           15: bytes.fromhex('8f8424fa0f0000'), 16: bytes.fromhex('8f442408')}


def variant(case):
    if type(case) is not int or not 1 <= case <= 16:
        raise ValueError('case must be integer1..16')
    if case <= 2:
        return dict(case_id=case, expected_esp=0x200C if case == 1 else 0x2004,
                    pop_esp=0x2004, destination_lin=0x200C, source_lin=0x2000,
                    expected_value=0x13579BDF, expected_cs=0x18 if case == 1 else 8)
    width = 2 if case in (3, 4, 6) else 4
    stack_b = int(case not in (3, 5, 6, 7, 13))
    old = 0x1FFFE if case == 6 else 0x1FFFC if case in (7, 8) else \
        0x12000 if case in (3, 4, 5, 13) else 0xFFF8 if case == 12 else 0x10000 if case == 16 else 0x2000
    post = old + width if stack_b else (old & 0xFFFF0000) | ((old + width) & 0xFFFF)
    disp = -4 if case == 9 else 0x18000 if case == 10 else 4 if case == 12 else 0xFFA if case in (14, 15) else 8
    dest = 0x7008 if case == 11 else old + width + disp + (12 if case == 8 else 0) + (0x40000 if case == 10 else 0)
    fault = int(case in (12, 13, 15, 16))
    return dict(case_id=case, width=width, stack_b=stack_b, initial_esp=old,
                pop_esp=post, expected_esp=old if fault else 0x13579BDF if case == 11 else post,
                destination_lin=dest, wrong_destination_lin=dest if case == 11 else dest - width,
                source_lin=old if stack_b else old & 0xFFFF, expected_value=0x9BDF if width == 2 else 0x13579BDF,
                expected_cs=8, expected_faults=fault, expected_fault_vector=12 if case == 13 else 14,
                expected_fault_error=0 if case in (13, 16) else 3 if case == 15 else 2,
                expected_fault_flags=2,
                expected_cr2=0 if case == 13 else 0x3000 if case == 15 else 0x10000,
                expected_handler_esp=old - 16 if stack_b else (old & 0xFFFF0000) | ((old - 16) & 0xFFFF),
                paged_case=int(case in (12, 14, 15, 16)))


def validate_image(case, sym, image):
    info = variant(case)
    if len(image) != 65536 or any(sym.get(key) != value for key, value in info.items()):
        raise ValueError('wrong image geometry/ELF variant constants')
    if case in (14, 15) and (sym['destination_lin'] != 0x2FFE or
            (sym['destination_lin'] & 0xFFF) + sym['width'] <= 0x1000):
        raise ValueError('cross-page cases must actually cross4KiB at2FFE')
    names = ('tested_pop', 'pop_end', 'capture_esp', 'capture_destination', 'capture_source',
             'set_exit_port', 'do_out', 'fail', 'fault_fail')
    if any(not 0xF0000 <= sym.get(key, -1) < 0xFFFF0 for key in names):
        raise ValueError('missing/out-of-ROM witness label')
    at = sym['tested_pop'] - 0xF0000
    opcode = OPCODES[case]
    length = len(opcode) - 2 if case == 1 else len(opcode)
    if image[at:at+len(opcode)] != opcode or sym['pop_end'] != sym['tested_pop'] + length:
        raise ValueError('wrong exact POP/prefix/RETF instruction bytes')
    port = b'\xba\xf4\x00\xee' if case == 1 else b'\x66\xba\xf4\x00\xee'
    at = sym['set_exit_port'] - 0xF0000
    if image[at:at+len(port)] != port or sym['do_out'] != sym['set_exit_port'] + len(port) - 1:
        raise ValueError('wrong actual successful debug-exit path')
    if info.get('expected_faults'):
        frame_flags = (info['expected_handler_esp'] if info['stack_b'] else
                       info['expected_handler_esp'] & 0xFFFF) + 12
        flags_at = sym.get('check_fault_flags', 0) - 0xF0000
        # GAS emits compact CMP imm8 here. Never mask RF or accept10002 as2.
        wanted = b'\x83\x3d' + frame_flags.to_bytes(4, 'little') + b'\x02'
        if not 0 <= flags_at < 65536 or image[flags_at:flags_at+7] != wanted:
            raise ValueError('wrong exact savedFLAGS2 QEMU-profile assertion')
    return info


def grade_trace(trace, case, sym, image, producer):
    info = validate_image(case, sym, image)
    rows = contracts.validate_trace(trace, producer)
    if len(rows) >= MAX_INSN:
        raise ValueError('instruction-cap exhaustion')
    def event(name):
        hits = [i for i, row in enumerate(rows) if tracefmt.parse_hex(row['pc']) == sym[name] - 0xF0000]
        if len(hits) != 1:
            raise ValueError(f'{name} must occur exactly once')
        return hits[0]
    order = [event(name) for name in ('tested_pop', 'capture_esp', 'capture_destination', 'capture_source')]
    if order != sorted(set(order)) or any(tracefmt.parse_hex(row['pc']) in
            {sym['fail'] - 0xF0000, sym['fault_fail'] - 0xF0000} for row in rows):
        raise ValueError('self-check failure or witness order mismatch')
    fault = info.get('expected_faults', 0)
    pop = rows[order[0]]
    esp = info['expected_handler_esp'] if fault else info['pop_esp']
    if (tracefmt.parse_hex(pop['esp']) != esp or tracefmt.parse_hex(pop['cs']) != info['expected_cs'] or
            tracefmt.parse_hex(pop['ss']) != 0x20 or tracefmt.parse_hex(pop['eax']) != 0x11223344):
        raise ValueError('wrong precise POP/delivery stack/register state')
    if case >= 3:
        for key, value in dict(ebx=0x3000, ecx=3, edx=0x55667788, esi=0x10, edi=0x778899AA, ebp=0x7000).items():
            if tracefmt.parse_hex(pop[key]) != value:
                raise ValueError('POP/fault changed an unrelated GPR')
    if tracefmt.parse_hex(pop['eflags']) != 2:
        raise ValueError('POP/delivery changed exact profile live flags')
    if fault and event('fault_handler') != order[0] + 1:
        raise ValueError('fault delivery marker must immediately precede handler entry')
    if case == 11:
        controls = [event(name) for name in ('control_addr16', 'control_reg', 'control_esp')]
        if not order[0] < controls[0] < controls[1] < controls[2] < order[1]:
            raise ValueError('missing/out-of-order independent controls')
        for index, value in zip(controls, (0x2002, 0x2004, 0x13579BDF)):
            if tracefmt.parse_hex(rows[index]['esp']) != value:
                raise ValueError('wrong address16/register POP control')
    value = (0x5AA5 if info.get('width') == 2 else 0xA55A5AA5) if fault else info['expected_value']
    for index, key, expected in ((order[1], 'ecx', info['expected_esp']), (order[2], 'esi', value),
                                 (order[3], 'edi', info['expected_value'])):
        if tracefmt.parse_hex(rows[index][key]) != expected:
            raise ValueError('wrong actual ESP/destination/source readback')
    final = rows[-1]
    expected = dict(eax=0x42, ebx=case, ecx=info['expected_esp'], esi=value, edi=info['expected_value'], ebp=fault,
                    esp=info['expected_esp'] if case <= 2 else 0x9000, cs=info['expected_cs'],
                    ss=0x20 if case <= 2 else 0x10, ds=0x10, es=0x10, fs=0x10, gs=0x10,
                    cr2=info['expected_cr2'] if fault else 0, cr3=0x11000 if info.get('paged_case') else 0)
    if any(tracefmt.parse_hex(final[key]) != wanted for key, wanted in expected.items()) or \
            tracefmt.parse_hex(final['edx']) & 0xFFFF != 0xF4 or tracefmt.parse_hex(final['pc']) not in \
            {sym['set_exit_port'] - 0xF0000, sym['do_out'] - 0xF0000}:
        raise ValueError('wrong final independent witnesses/exit')
    if tracefmt.parse_hex(final['cr0']) & 0x80000001 != (0x80000001 if case == 14 else 1):
        raise ValueError('wrong final protected/paging mode')
    return len(rows)


def grade_native(trace, stdout, stderr, case, sym, image, return_code):
    if return_code != 133:
        raise ValueError('native actual wait must be133')
    count = grade_trace(trace, case, sym, image, 'rtl')
    if any((text and not text.endswith('\n')) or contracts.FATAL.search(text) for text in (stdout, stderr)):
        raise ValueError('truncated/fatal native evidence')
    log = stdout + stderr
    stop = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) after (\d+) retired in (\d+) clocks$', log, re.M)
    footer = re.findall(r'^tb: retired (\d+) instructions in (\d+) clocks \(bus: \d+ reads, \d+ writes\)$', log, re.M)
    io = [line for line in log.splitlines() if line.startswith('tb: M7.3b')]
    if len(stop) != 1 or int(stop[0][0]) != count or int(stop[0][1]) <= 0 or footer != stop or io != [
            'tb: M7.3b win95 co-sim: 0 IN reads serviced (0 dev_in available, cursor at 0), 1 OUT writes consumed, 0 port/size desync(s), isa-debug-exit reached']:
        raise ValueError('missing/duplicate/incomplete native closure')
    observed = []
    for line in log.splitlines():
        if '[FAULT]' not in line:
            continue
        match = contracts.check_faultlog.FAULT.fullmatch(line)
        if not match:
            raise ValueError('malformed canonical fault')
        observed.append((int(match[1]), int(match[2], 16), int(re.search(r' pc=([0-9a-fA-F]{8}) ', line)[1], 16)))
    info = variant(case)
    required = [(info['expected_fault_vector'], info['expected_fault_error'], sym['tested_pop'] - 0xF0000)] if info.get('expected_faults') else []
    if observed != required:
        raise ValueError(f'wrong ordered precise fault events: {observed}')
    return dict(result='PASS', case=case, records=count, clocks=int(stop[0][1]), actual_return_code=return_code,
                ordinary_faults=observed, record_note='Legacy fault delivery markers retained; no records discarded.')


def grade_golden(trace, log, case, sym, image, generator_code, free_code):
    if case == 13:
        raise ValueError('case13 is Intel-spec-only; QEMU omits per-access SS-limit checks')
    if generator_code != 0 or free_code != 133:
        raise ValueError('golden actual waits require generator0/free133')
    count = grade_trace(trace, case, sym, image, 'qemu-gdbstub')
    if not log.endswith('\n') or contracts.FATAL.search(log) or re.findall(
            r'^\[gen_trace\] wrote (\d+) records to [^\r\n]+ \(guest exited, code=0\)$', log, re.M) != [str(count)]:
        raise ValueError('incomplete/fatal golden footer')
    return count
