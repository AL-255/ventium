#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Static host integration checks, not a DUT or equivalence gate."""
import re
import unittest

from test_state_fetch_observer import SOURCE, function_body


class CacheWatchIntegrationTests(unittest.TestCase):
    def test_default_off_and_fixed_lifetime_cap(self):
        self.assertIn("static bool g_cache_watch_enabled = false;", SOURCE)
        self.assertIn("static constexpr unsigned CACHE_WATCH_LIMIT = 256;", SOURCE)
        self.assertEqual(SOURCE.count("++g_cache_watch_events"), 1)
        self.assertEqual(len(re.findall(r"g_cache_watch_events\s*=(?!=)", SOURCE)), 1)

    def test_address_parser_rejects_bad_input_and_aligns_only_host_selection(self):
        main = function_body("main")
        option = main[main.index('!strcmp(argv[i], "--ven-cache-line")'):
                      main.index('!strcmp(argv[i], "--ven-delta-out")')]
        for guard in ("i+1 >= argc", "errno", "!*value", "*value == '-'",
                      "*end", "parsed > UINT32_MAX"):
            self.assertIn(guard, option)
        self.assertIn("uint32_t(parsed) & ~uint32_t(31)", option)
        self.assertNotIn("top->", option)

    def test_watch_is_pre_edge_and_does_not_change_evaluation_count(self):
        tick = function_body("tick")
        start = tick.index("if (g_cache_watch_enabled && !top->reset")
        end = tick.index("if (g_fault_ring.enabled())", start)
        watch = tick[start:end]
        self.assertLess(tick.index("set_clocks(0); top->eval();"), start)
        self.assertLess(end, tick.index("set_clocks(1); step_vga_clock(); top->eval();"))
        self.assertEqual(tick.count("top->eval();"), 3)
        for forbidden in ("eval(", "ddr[", "ao486_peek_guest", "cpu_dbg", "load_state", "save_state"):
            self.assertNotIn(forbidden, watch)

    def test_events_fail_closed_and_cap_exhaustion_is_explicit(self):
        tick = function_body("tick")
        self.assertIn("g_cache_watch_events < CACHE_WATCH_LIMIT", tick)
        self.assertIn("if (event < 0)", tick)
        self.assertIn("if (event)", tick)
        self.assertIn("if (g_cache_watch_events == CACHE_WATCH_LIMIT)", tick)
        self.assertIn("later events not observed", tick)

    def test_mutation_filter_is_opt_in_and_requires_an_address(self):
        self.assertIn("static bool g_cache_watch_mutations_only = false;", SOURCE)
        main = function_body("main")
        self.assertIn('!strcmp(argv[i], "--ven-cache-line-mutations")', main)
        self.assertIn("if (g_cache_watch_mutations_only && !g_cache_watch_enabled)", main)
        tick = function_body("tick")
        self.assertRegex(tick, r"ven_cache_line_event\(\*top->rootp, g_cache_watch_line, 0,\s*"
                              r"g_cache_watch_mutations_only\)")

    def test_core_owner_and_sources_share_the_same_pre_edge(self):
        tick = function_body("tick")
        for capture in ("fault_ring_edge(*top->rootp, owner, 0)",
                        "ven_cache_source_probe(stderr, *top->rootp, main_time, g_cache_watch_line, 0)"):
            self.assertIn(capture, tick)
        for field in ("qpc=%08x", "csb=%08x", "esb=%08x", "dsb=%08x",
                      "nat=%08x", "lin=%08x", "pre_edge=1"):
            self.assertIn(field, tick)

    def test_required_hierarchy_is_checked_before_running(self):
        main = function_body("main")
        start = main.index("if (g_cache_watch_enabled)")
        end = main.index("if (g_state_trace_fetch)", start)
        guard = main[start:end]
        self.assertIn("!fault_ring_edge(*top->rootp, owner, 0)", guard)
        self.assertIn("ven_cache_line_event(*top->rootp, g_cache_watch_line, 0) < 0", guard)
        self.assertIn("return 2;", guard)

    def test_fetch_source_capture_remains_inside_its_existing_event_cap(self):
        fetch = function_body("state_trace_fetch_snapshot")
        self.assertIn("ven_cache_source_probe(stderr, r, edge.cycle, edge.mem_addr, 0)", fetch)
        self.assertIn("VENCACHE available=0", fetch)
        self.assertNotRegex(fetch.lower(), r"0x0?63[159f]|0xc000|quake|win95|bios")


if __name__ == "__main__":
    unittest.main()
