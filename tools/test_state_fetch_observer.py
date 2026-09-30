#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only structural checks for the passive bounded VENFETCH observer.

Reads source only: no C++ compilation, model execution, guest RAM or trace
mutation. Optional VEN_STATE_FETCH_BEFORE points at the preserved dirty source
to prove the patch contains insertions only, including unchanged eval calls.
These checks are not runtime equivalence or a DUT qualification gate.
"""
from __future__ import annotations

import difflib
import os
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "ao486-sim" / "ven" / "sim_ven.cpp").read_text()
EDGE_SOURCE = (ROOT / "tools" / "retire_fault_ring.h").read_text()
BEFORE = os.environ.get("VEN_STATE_FETCH_BEFORE")


def function_body(name: str) -> str:
    match = re.search(r"\b" + re.escape(name) + r"\([^\n]*\)\s*\{", SOURCE)
    if match is None:
        raise AssertionError(f"missing function {name}")
    start = match.end()
    depth = 1
    for index in range(start, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[start:index]
    raise AssertionError(f"unterminated function {name}")


class StateFetchObserverStaticTests(unittest.TestCase):
    def test_default_off_and_explicit_opt_in(self) -> None:
        self.assertRegex(SOURCE, r"static bool g_state_trace_fetch = false;")
        self.assertRegex(SOURCE, r'!strcmp\(argv\[i\], "--ven-state-fetch"\)\) g_state_trace_fetch = true;')

    def test_lifetime_event_limit_and_one_capped_caller(self) -> None:
        self.assertIn("STATE_TRACE_FETCH_LIMIT = 256;", SOURCE)
        self.assertEqual(SOURCE.count("state_trace_fetch_snapshot("), 2)
        self.assertEqual(len(re.findall(r"g_state_trace_fetch_events\s*=(?!=)", SOURCE)), 1)
        self.assertEqual(SOURCE.count("++g_state_trace_fetch_events"), 1)
        self.assertRegex(function_body("tick"), r"g_state_trace_fetch && !top->reset &&\s*"
                         r"g_state_trace_fetch_events < STATE_TRACE_FETCH_LIMIT &&\s*"
                         r"!state_trace_fetch_snapshot\(\*r\)")

    def test_required_capture_is_const_and_fail_closed(self) -> None:
        self.assertIn("state_trace_fetch_snapshot(const Root &r)", SOURCE)
        self.assertIn("if (!fault_ring_edge(r, edge, 0)) return false;",
                      function_body("state_trace_fetch_snapshot"))
        self.assertRegex(SOURCE, r"if \(!fault_ring_edge\(\*top->rootp, edge, 0\)\) \{\s*"
                         r'fprintf\(stderr, "--ven-state-fetch required model fields are unavailable\\n"\);\s*'
                         r"return 2;")

    def test_no_evaluation_guest_read_or_debug_drive_in_snapshot(self) -> None:
        body = function_body("state_trace_fetch_snapshot")
        for forbidden in ("eval(", "ao486_peek_guest", "ddr[", "guest_word", "guest_dword",
                          "ven_debug_drive", "cpu_dbg", "top->", "load_state", "save_state"):
            self.assertNotIn(forbidden, body)
        self.assertNotRegex(body, r"\br\.[A-Za-z0-9_]+\s*=(?!=)")

    def test_observer_is_within_existing_window_after_low_eval_before_rising_edge(self) -> None:
        tick = function_body("tick")
        low = tick.index("set_clocks(0); top->eval();")
        window = tick.index("if (g_state_trace_cycles && main_time >= g_state_trace_start &&")
        sample = tick.index("!state_trace_fetch_snapshot(*r)")
        high = tick.index("set_clocks(1); step_vga_clock(); top->eval();")
        self.assertLess(low, window)
        self.assertLess(window, sample)
        self.assertLess(sample, high)
        self.assertIn("main_time - g_state_trace_start < g_state_trace_cycles", tick[window:sample])
        self.assertEqual(tick.count("top->eval();"), 3)

    def test_fetch_requires_active_read_ack_and_decode_uses_state_two(self) -> None:
        body = function_body("state_trace_fetch_snapshot")
        self.assertIn("edge.state == 1 && edge.mem_req && !edge.mem_we && edge.mem_ack", body)
        self.assertIn("if (!fetch_ack && edge.state != 2) return true;", body)
        self.assertLess(body.index("if (!fetch_ack"), body.index("++g_state_trace_fetch_events"))

    def test_fixed_sixteen_byte_buffer_and_pre_edge_labels(self) -> None:
        body = function_body("state_trace_fetch_snapshot")
        self.assertIn("char bytes[33];", body)
        self.assertIn("k < edge.ibuf.size()", body)
        self.assertRegex(EDGE_SOURCE, r"std::array<uint8_t, 16> ibuf")
        self.assertIn("pre_edge=1", body)
        self.assertIn("ibuf16_pre=%s", body)
        self.assertIn('fetch_ack ? "FETCH_ACK" : "DECODE"', body)

    def test_all_gprs_segments_and_real_bus_fields_are_emitted(self) -> None:
        body = function_body("state_trace_fetch_snapshot")
        for index in range(8):
            self.assertIn(f"edge.gpr[{index}]", body)
        for field in ("csb=%08x", "eip=%08x", "flags=%08x", "cr2=%08x",
                      "ssb=%08x", "dsb=%08x", "esb=%08x", "nat=%08x", "lin=%08x",
                      "addr=%08x", "req=%u", "we=%u", "ack=%u", "rstrb=%x",
                      "wstrb=%x", "rdata=%08x", "event=%u"):
            self.assertIn(field, body)
        for field in ("mem_addr", "read_strobes", "write_strobes", "mem_rdata"):
            self.assertIn(f"edge.{field}", body)

    def test_optional_decode_members_are_explicitly_unavailable_not_guessed(self) -> None:
        helper = SOURCE[SOURCE.index("#define STATE_FETCH_FIELD(name)"):
                        SOURCE.index("#undef STATE_FETCH_FIELD")]
        self.assertIn("decltype((void)r.system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name", helper)
        self.assertIn("const Root &, long) { return -1; }", helper)
        body = function_body("state_trace_fetch_snapshot")
        for field in ("fetch_word", "d_len", "d_pop_sreg", "d_ct"):
            self.assertIn(f"STATE_FETCH_FIELD({field})", helper)
            self.assertIn(f"{field}=%d", body)
            self.assertIn(f"state_trace_{field}(r, 0)", body)

    def test_zero_or_out_of_range_state_window_rejected_before_model_creation(self) -> None:
        main = function_body("main")
        guard = "if (g_state_trace_fetch && (!g_state_trace_cycles || g_state_trace_cycles > 1000000))"
        self.assertIn(guard, main)
        start = main.index(guard)
        stop = main.index("top = new Vsystem;")
        self.assertLess(start, stop)
        self.assertIn("return 2;", main[start:stop])

    def test_no_workload_specific_fetch_filter_or_state_poke(self) -> None:
        body = function_body("state_trace_fetch_snapshot")
        self.assertNotRegex(body.lower(), r"0x0?63[159f]|0xc000|quake|win95|bios")
        self.assertNotIn(".vtrace", body)
        self.assertNotIn("fopen", body)

    @unittest.skipUnless(BEFORE, "set VEN_STATE_FETCH_BEFORE to audit dirty-source preservation")
    def test_observer_patch_only_inserts_and_preserves_existing_evals(self) -> None:
        original = Path(BEFORE).read_text()
        edits = difflib.SequenceMatcher(a=original.splitlines(), b=SOURCE.splitlines(),
                                       autojunk=False).get_opcodes()
        self.assertTrue(any(tag == "insert" for tag, *_ in edits))
        self.assertTrue(all(tag in ("equal", "insert") for tag, *_ in edits))
        self.assertEqual(original.count("top->eval();"), SOURCE.count("top->eval();"))


if __name__ == "__main__":
    unittest.main()
