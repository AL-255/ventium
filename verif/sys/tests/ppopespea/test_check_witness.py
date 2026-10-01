"""Pure host synthetic contracts; never DUT/QEMU acceptance evidence."""
import copy
import os
from pathlib import Path
import unittest

import check_witness as c
import run_gate


def synthetic(case):
    info = c.variant(case)
    sym = dict(info, tested_pop=0xF1000, pop_end=0xF1000 + len(c.OPCODES[case]) - (2 if case == 1 else 0),
               capture_esp=0xF1200, capture_destination=0xF1300, capture_source=0xF1400,
               set_exit_port=0xF1500, do_out=0xF1503 if case == 1 else 0xF1504,
               fail=0xF1600, fault_fail=0xF1700, fault_handler=0xF1100,
               check_fault_flags=0xF1800,
               control_addr16=0xF1010, control_reg=0xF1020, control_esp=0xF1030)
    image = bytearray(65536)
    opcode = c.OPCODES[case]
    image[0x1000:0x1000+len(opcode)] = opcode
    port = bytes.fromhex('baf400ee') if case == 1 else bytes.fromhex('66baf400ee')
    image[0x1500:0x1500+len(port)] = port
    fault = info.get('expected_faults', 0)
    if fault:
        frame_flags = (info['expected_handler_esp'] if info['stack_b'] else info['expected_handler_esp'] & 0xFFFF) + 12
        image[0x1800:0x1807] = b'\x83\x3d' + frame_flags.to_bytes(4, 'little') + b'\x02'
    value = (0x5AA5 if info.get('width') == 2 else 0xA55A5AA5) if fault else info['expected_value']
    regs = dict(eax=0x42, ebx=case, ecx=info['expected_esp'], edx=0xF4,
                esp=info['expected_esp'] if case <= 2 else 0x9000, ebp=fault,
                esi=value, edi=info['expected_value'])
    segs = dict(cs=info['expected_cs'], ss=0x20 if case <= 2 else 0x10, ds=0x10, es=0x10, fs=0x10, gs=0x10)
    system = dict(cr0=0x80000001 if case == 14 else 1, cr2=info['expected_cr2'] if fault else 0,
                  cr3=0x11000 if info.get('paged_case') else 0, cr4=0)
    labels = ['tested_pop'] + (['fault_handler'] if fault else []) + \
        (['control_addr16', 'control_reg', 'control_esp'] if case == 11 else []) + \
        ['capture_esp', 'capture_destination', 'capture_source', 'set_exit_port']
    rows = []
    for n, label in enumerate(labels):
        gpr, seg = dict(regs), dict(segs)
        if label == 'tested_pop':
            gpr.update(eax=0x11223344, esp=info['expected_handler_esp'] if fault else info['pop_esp'])
            seg['ss'] = 0x20
            if case >= 3:
                gpr.update(ebx=0x3000, ecx=3, edx=0x55667788, esi=0x10, edi=0x778899AA, ebp=0x7000)
        if label in ('control_addr16', 'control_reg', 'control_esp'):
            gpr['esp'] = {'control_addr16': 0x2002, 'control_reg': 0x2004, 'control_esp': 0x13579BDF}[label]
        rows.append(c.tracefmt.func_record(n, sym[label] - 0xF0000, 2, gpr, seg, sysregs=system))
    trace = c.tracefmt.Trace(c.tracefmt.header('rtl', 'func', sys=True), rows)
    log = (f'tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after {len(rows)} retired in 99 clocks\n'
           f'tb: retired {len(rows)} instructions in 99 clocks (bus: 3 reads, 2 writes)\n'
           'tb: M7.3b win95 co-sim: 0 IN reads serviced (0 dev_in available, cursor at 0), 1 OUT writes consumed, 0 port/size desync(s), isa-debug-exit reached\n')
    faultlog = f'[FAULT] vec={info["expected_fault_vector"]} err={info["expected_fault_error"]:08x} pc=00001000 state=37 v86=0 depth=0\n' if fault else ''
    return trace, sym, bytes(image), faultlog, log


class WitnessContracts(unittest.TestCase):
    def grade(self, case=1, mutate=None, code=133, stdout=None, stderr=None):
        trace, sym, image, faults, log = synthetic(case)
        if mutate:
            mutate(trace, sym)
        return c.grade_native(trace, faults if stdout is None else stdout, log if stderr is None else stderr,
                              case, sym, image, code)

    def test_all_16_synthetic_contracts(self):
        for case in range(1, 17):
            with self.subTest(case=case):
                self.assertEqual(self.grade(case)['result'], 'PASS')

    def test_wrong_wait_status(self):
        for code in (0, 135, -15, 124):
            with self.assertRaises(ValueError):
                self.grade(code=code)

    def test_pop_stack_commit_not_double_or_wrong_high(self):
        for case in (1, 3, 6, 7, 14):
            with self.assertRaises(ValueError):
                self.grade(case, lambda trace, _: trace.records[0].update(esp='0x00002008'))

    def test_pop_changed_unrelated_register_or_flags(self):
        for key in ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'ebp', 'eflags'):
            with self.assertRaises(ValueError):
                self.grade(3, lambda trace, _: trace.records[0].update({key: '0x00000007'}))

    def test_fault_precise_old_stack_and_adjacent_handler(self):
        for case in (12, 13, 15, 16):
            with self.assertRaises(ValueError):
                self.grade(case, lambda trace, _: trace.records[0].update(esp='0x00000007'))
            with self.assertRaises(ValueError):
                self.grade(case, lambda trace, _: trace.records[1].update(pc='0x00000007'))

    def test_source_destination_esp_readback(self):
        for index, field in ((1, 'ecx'), (2, 'esi'), (3, 'edi')):
            with self.assertRaises(ValueError):
                self.grade(1, lambda trace, _: trace.records[index].update({field: '0x00000007'}))

    def test_final_witnesses_and_fail_path(self):
        for key in ('eax', 'ebx', 'ecx', 'esi', 'edi', 'ebp', 'esp', 'cs', 'ss', 'ds', 'cr2', 'cr3'):
            with self.assertRaises(ValueError):
                self.grade(1, lambda trace, _: trace.records[-1].update({key: '0x00000007'}))
        with self.assertRaises(ValueError):
            self.grade(1, lambda trace, sym: trace.records[-1].update(pc=c.tracefmt.h32(sym['fail'] - 0xF0000)))

    def test_closed_footer_faults_and_opcode_pins(self):
        for log in ('', '%Error\n', synthetic(1)[4][:-1], synthetic(1)[4] * 2):
            with self.assertRaises(ValueError):
                self.grade(stderr=log)
        with self.assertRaises(ValueError):
            self.grade(stdout='[FAULT] vec=14 err=00000002 pc=00001000 state=37 v86=0 depth=0\n')
        with self.assertRaises(ValueError):
            self.grade(12, stdout='')
        trace, sym, image, _, _ = synthetic(1)
        wrong = bytearray(image)
        wrong[0x1000] = 0x66
        with self.assertRaises(ValueError):
            c.validate_image(1, sym, bytes(wrong))

    def test_selected_cases(self):
        self.assertEqual(run_gate.selected_cases('all'), list(range(1, 17)))
        for value in ('0', '17', '1,1', '1,', '-1'):
            with self.assertRaises(ValueError):
                run_gate.selected_cases(value)

    def test_crosspage_formula_and_actual_elf_geometry(self):
        for case in (14, 15):
            info = c.variant(case)
            self.assertEqual(info['destination_lin'], 0x2FFE)
            self.assertGreater((info['destination_lin'] & 0xFFF) + info['width'], 0x1000)
            self.assertEqual(c.OPCODES[case], bytes.fromhex('8f8424fa0f0000'))
            trace, sym, image, _, _ = synthetic(case)
            c.validate_image(case, sym, image)
            sym['destination_lin'] = 0x2DFE
            with self.assertRaises(ValueError):
                c.validate_image(case, sym, image)

    def test_ss_limit_case_cannot_be_claimed_qemu_correctness(self):
        trace, sym, image, _, _ = synthetic(13)
        with self.assertRaisesRegex(ValueError, 'Intel-spec-only'):
            c.grade_golden(trace, 'invented\n', 13, sym, image, 0, 133)

    def test_fault_flags_are_exact_profile_two_not_masked(self):
        for case in (12, 13, 15, 16):
            trace, sym, image, _, _ = synthetic(case)
            self.assertEqual(sym['expected_fault_flags'], 2)
            sym['expected_fault_flags'] = 0x10002
            with self.assertRaises(ValueError):
                c.validate_image(case, sym, image)
            trace, sym, image, _, _ = synthetic(case)
            image = bytearray(image)
            image[0x1806] = 0
            with self.assertRaisesRegex(ValueError, 'exact savedFLAGS2'):
                c.validate_image(case, sym, bytes(image))
            with self.assertRaises(ValueError):
                self.grade(case, lambda trace, _: trace.records[0].update(eflags='0x00010002'))

    def test_actual_host_assembled_images_when_requested(self):
        images = os.environ.get('PPOPESPEA_IMAGES')
        if not images:
            self.skipTest('set PPOPESPEA_IMAGES for host-built image contract checks')
        for case in range(1, 17):
            image = Path(images) / f'ppopespea-c{case}.bin'
            elf = image.with_suffix('.elf')
            with self.subTest(case=case):
                c.validate_image(case, c.contracts.symbols(elf), image.read_bytes())
