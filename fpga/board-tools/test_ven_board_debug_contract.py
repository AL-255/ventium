#!/usr/bin/env python3
"""Host-only checks of ABI refusal and honest primary-counter reporting."""
import argparse
from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import struct
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'debug_contract_probe', Path(__file__).with_name('ven_board_probe.py'))
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class FakeCtrl(bytearray):
    def __init__(self, capability=PROBE.DBG_EXEC_CAP):
        super().__init__(PROBE.CTRL_SIZE)
        self.closed = False
        struct.pack_into('<I', self, PROBE.R_IDENT, PROBE.IDENT_MAGIC)
        struct.pack_into('<I', self, PROBE.R_DBG_EXEC_CAP, capability)

    def close(self):
        self.closed = True


class DebugContractTests(unittest.TestCase):
    def cold_ctrl(self):
        ctrl = FakeCtrl()
        struct.pack_into('<I', ctrl, 0x20, 1)
        struct.pack_into('<I', ctrl, PROBE.R_DBG_CR0, 0x60000010)
        return ctrl

    def test_cold_prepare_has_only_three_admitted_writes(self):
        ctrl = self.cold_ctrl()
        before = bytes(ctrl)
        output = io.StringIO()
        with patch.object(PROBE, 'open_mmio', return_value=(987654, ctrl, None)), \
             patch.object(PROBE.os, 'close') as close, \
             patch.object(PROBE.struct, 'pack_into', wraps=struct.pack_into) as writes, \
             redirect_stdout(output):
            self.assertEqual(PROBE.prepare_cold_probe(argparse.Namespace()), 0)
        self.assertEqual([(c.args[2], c.args[3]) for c in writes.call_args_list],
                         [(PROBE.R_DBG_EXEC_CTRL, PROBE.DBG_EXEC_HALT_REQ | PROBE.DBG_EXEC_BP_CLR),
                          (PROBE.W_DBG_CMP_CFG, 0), (PROBE.W_DBG_FREEZE_THRESH, 0)])
        self.assertTrue(all(c.args[0] == '<I' and c.args[1] is ctrl for c in writes.call_args_list))
        expected = bytearray(before)
        for address, value in ((PROBE.R_DBG_EXEC_CTRL, PROBE.DBG_EXEC_HALT_REQ | PROBE.DBG_EXEC_BP_CLR),
                               (PROBE.W_DBG_CMP_CFG, 0), (PROBE.W_DBG_FREEZE_THRESH, 0)):
            struct.pack_into('<I', expected, address, value)
        self.assertEqual(ctrl, expected)
        report = json.loads(output.getvalue())
        self.assertTrue(report['guest_held_reset'])
        self.assertFalse(report['guest_released'])
        self.assertFalse(report['acceptance'])
        self.assertIsNone(report['gameplay_ipc'])
        self.assertTrue(ctrl.closed)
        close.assert_called_once_with(987654)

    def test_cold_prepare_refuses_nonfresh_state_before_any_write(self):
        for address, value in ((0x20, 0), (PROBE.R_DBG_RET_LO, 1),
                               (PROBE.R_DBG_RET_HI, 1), (PROBE.R_DBG_FRZINFO, 0x80000000),
                               (PROBE.R_DBG_CR0, 0x80000011), (PROBE.R_IDENT, 0),
                               (PROBE.R_DBG_EXEC_CAP, 0x56450009)):
            with self.subTest(address=hex(address), value=hex(value)):
                ctrl = self.cold_ctrl()
                struct.pack_into('<I', ctrl, address, value)
                before = bytes(ctrl)
                with patch.object(PROBE, 'open_mmio', return_value=(987654, ctrl, None)), \
                     patch.object(PROBE.os, 'close'), \
                     patch.object(PROBE.struct, 'pack_into', wraps=struct.pack_into) as writes, \
                     self.assertRaises(RuntimeError):
                    PROBE.prepare_cold_probe(argparse.Namespace())
                writes.assert_not_called()
                self.assertEqual(ctrl, before)
                self.assertTrue(ctrl.closed)

    def test_abi5_run_only_clears_breakpoint_no_step_or_pair_suppression(self):
        ctrl = FakeCtrl()
        before = bytes(ctrl)
        with patch.object(PROBE, 'open_mmio', return_value=(987654, ctrl, None)), \
             patch.object(PROBE.os, 'close') as close, redirect_stdout(io.StringIO()):
            self.assertEqual(PROBE.run_probe(argparse.Namespace(timeout=0.1)), 0)
        expected = bytearray(before)
        struct.pack_into('<I', expected, PROBE.R_DBG_EXEC_CTRL, PROBE.DBG_EXEC_BP_CLR)
        self.assertEqual(ctrl, expected)
        self.assertTrue(ctrl.closed)
        close.assert_called_once_with(987654)

    def test_unknown_abi_refuses_all_execution_writes(self):
        args = argparse.Namespace(timeout=0.1, count=1, eip=0x14565, wait=False)
        for cap in (0, 0xffffffff, 0x56450004, 0x56450009):
            for command in (PROBE.halt_probe, PROBE.run_probe, PROBE.step_probe,
                            PROBE.breakpoint_probe, PROBE.dump_state_probe):
                with self.subTest(cap=hex(cap), command=command.__name__):
                    ctrl = FakeCtrl(cap)
                    before = bytes(ctrl)
                    with patch.object(PROBE, 'open_mmio', return_value=(987654, ctrl, None)), \
                         patch.object(PROBE.os, 'close') as close, \
                         self.assertRaisesRegex(RuntimeError, 'capability read'):
                        command(args)
                    self.assertEqual(bytes(ctrl), before, 'ABI refusal must precede every write')
                    self.assertTrue(ctrl.closed)
                    close.assert_called_once_with(987654)

    def test_abi5_state_is_read_only_and_explicit(self):
        ctrl = FakeCtrl()
        struct.pack_into('<I', ctrl, PROBE.R_DBG_EXEC_CTRL, 7)
        struct.pack_into('<I', ctrl, PROBE.R_DBG_RET_LO, 200)
        before = bytes(ctrl)
        state = PROBE.debug_state(ctrl)
        self.assertEqual(bytes(ctrl), before)
        self.assertEqual(state['execution']['format'], 5)
        self.assertEqual(state['execution']['raw'], '00000007')
        for field in ('halt_requested', 'breakpoint_enabled', 'halted'):
            self.assertTrue(state['execution'][field])
        self.assertFalse(state['execution']['step_command_readback_available'])
        self.assertEqual(state['counters']['retirements'], 200)
        self.assertEqual(state['counters']['retirement_counter_kind'], 'primary_U_not_total_UV')

    def test_unknown_abi_state_does_not_invent_execution_fields(self):
        state = PROBE.debug_state(FakeCtrl(0x56450009))
        self.assertEqual(state['execution'],
                         dict(available=False, capability_read='56450009'))

    def sample(self, counters, *, profiler=False):
        ctrl = FakeCtrl()
        output = io.StringIO()
        before = bytes(ctrl)
        with ExitStack() as stack:
            stack.enter_context(patch.object(PROBE, 'open_mmio', return_value=(987654, ctrl, None)))
            close = stack.enter_context(patch.object(PROBE.os, 'close'))
            stack.enter_context(patch.object(PROBE, 'stable_u64', side_effect=counters))
            stack.enter_context(patch.object(PROBE.time, 'monotonic', side_effect=[10.0, 12.0]))
            stack.enter_context(patch.object(PROBE.time, 'sleep'))
            stack.enter_context(redirect_stdout(output))
            try:
                result = PROBE.perf_probe(argparse.Namespace(seconds=2.0, axi_read_profiler=profiler))
            finally:
                self.assertEqual(bytes(ctrl), before, 'perf must not write MMIO')
                self.assertTrue(ctrl.closed)
                close.assert_called_once_with(987654)
        self.assertEqual(result, 0)
        return output.getvalue()

    def test_primary_sample_never_claims_total_or_gameplay(self):
        # 80M clocks / 2s = 40 MHz, 20M PRIMARY retirements / 80M = 0.25.
        text = self.sample([100, 20, 80_000_100, 20_000_020])
        self.assertIn('clock=40.000000MHz', text)
        self.assertIn('primary_u_ipc=0.250000', text)
        self.assertIn('cycles_per_u_retirement=4.000', text)
        self.assertIn('primary_u_retired=20000000', text)
        self.assertIn('total_uv_ipc=unavailable gameplay_qualified=false', text)
        self.assertNotIn(' ipc=', text)
        self.assertNotIn(' cpi=', text)

    def test_counter_clear_is_not_uint64_wrap(self):
        for counters in ([100, 20, 99, 21], [100, 20, 101, 19]):
            with self.subTest(counters=counters), self.assertRaisesRegex(RuntimeError, 'reset/clear'):
                self.sample(counters)

    def test_idle_sample_is_not_gameplay(self):
        text = self.sample([100, 20, 100, 20])
        self.assertIn('primary_u_ipc=0.000000', text)
        self.assertIn('cycles_per_u_retirement=inf', text)
        self.assertIn('gameplay_qualified=false', text)

    def test_profiler_zero_transactions_remains_unavailable(self):
        self.assertIn('axi-read-profiler unavailable/inconsistent interval:',
                      self.sample([100, 20, 200, 40], profiler=True))

    def test_bad_duration_refused_before_open(self):
        for seconds in (0, -1, 3601, float('nan'), float('inf')):
            with self.subTest(seconds=seconds), \
                 patch.object(PROBE, 'open_mmio') as opened, \
                 self.assertRaises(ValueError):
                PROBE.perf_probe(argparse.Namespace(seconds=seconds, axi_read_profiler=False))
            opened.assert_not_called()


if __name__ == '__main__':
    unittest.main()
