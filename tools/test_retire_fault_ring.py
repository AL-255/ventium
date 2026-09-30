#!/usr/bin/env python3
"""Bounded host-only C++ tests; no simulator, guest image or RTL build."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CPP = r'''
#include "retire_fault_ring.h"
#include <cassert>
#include <string>
using namespace ven_host;
int main(int argc, char **argv) {
    assert(argc >= 2);
    const std::string mode(argv[1]);
    if (mode == "parse") {
        FaultRingOptions options;
        for (int i = 2; i < argc; ++i) {
            const char *error = nullptr;
            const int result = parse_fault_ring_option(argc, argv, i, options, error);
            if (result != 1) return 2;
        }
        if (validate_fault_ring_options(options, false)) return 2;
        std::printf("%llu %d %u\n", (unsigned long long)options.start_retire,
                    options.vector, options.max_events);
        return 0;
    }
    if (mode == "disabled") {
        RetireFaultRing ring;
        ring.prepare({}); ring.retire({}); ring.observe_fault({});
        assert(!ring.enabled() && !ring.events() && !ring.retire_count() && !ring.bytes());
        return 0;
    }
    if (mode == "restore") {
        FaultRingOptions o; o.path = "some-new-file";
        return validate_fault_ring_options(o, true) ? 2 : 0;
    }
    assert(argc == 3);
    FaultRingOptions options; options.path = argv[2];
    if (mode == "filter") { options.start_retire = 10; options.vector = 6; }
    RetireFaultRing ring;
    if (!ring.open(options)) return 3;
    FaultCoreEdge before;
    before.cycle = 100; before.seg[0] = 0xc000; before.seg[1] = 0x1234;
    before.base[0] = 0xc0000; before.base[1] = 0x12340;
    before.gpr = {1,2,3,4,0xabcdfff0,6,7,8};
    before.eflags = 0x23002; before.state = 37; before.q_pc = 0xabc;
    before.int_step = 2; before.int_gate_op16 = 1;
    before.iret_eip = 0xfb17; before.iret_cs = 0xf000;
    before.mem_ack = 1; before.mem_req = 1; before.mem_rdata = 0x12345678;
    before.cur_lin_nat = 0x22330; before.cur_lin = 0x22330;
    before.mem_addr = before.bd_addr = 0x22330;
    before.read_strobes = 3; before.cur_size = 2;
    before.esp_write_enable = 1; before.esp_write_data = 0xabcdfff2;
    for (unsigned i=0; i<16; ++i) before.ibuf[i]=uint8_t(i);
    if (mode == "wrap") before.fault_count = 255;
    ring.reset(before.fault_count);
    ring.reset(before.fault_count);
    assert(ring.epoch() == 1);
    ring.prepare(before);
    FaultRetireSnapshot s;
    s.fetch_pc = 0xeee; s.eflags = 0x202;
    s.gpr = {0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17};
    s.seg = {0x28,0x30,0x38,0x40,0x48,0x50};
    const unsigned count = mode == "order" || mode == "cap" ? 300 : 1;
    for (unsigned n=1; n<=count; ++n) {
        s.retire = n; s.core_n = n-1; s.cycle = before.cycle;
        ring.retire(s);
    }
    if (mode == "reset") {
        ring.reset(); ring.reset(); assert(ring.epoch() == 2);
        assert(!ring.retire_count() && !ring.edge_count());
        before.fault_count = 0; ring.prepare(before);
        s.retire = 900; ring.retire(s);
    }
    FaultCoreEdge after = before;
    after.state = 31; after.int_vec = 6; after.int_src_pc = 0xfb17;
    after.int_ret_eip = 0xfb17; after.fault_count = uint8_t(before.fault_count + 1);
    after.retires = 20;
    if (mode == "filter") {
        after.retires = 9; ring.observe_fault(after); assert(!ring.events());
        after.fault_count++; after.retires = 20; after.int_vec = 13;
        ring.observe_fault(after); assert(!ring.events());
        after.fault_count++; after.int_vec = 6;
    }
    if (mode == "edges" || mode == "cap") {
        for (unsigned n=1; n<=100; ++n) {
            before.cycle=n; ring.prepare(before);
        }
        assert(ring.edge_count() == 64);
    }
    if (mode == "waiting") {
        before.mem_ack = before.esp_write_enable = 0;
        ring.prepare(before);
        const auto size = ring.edge_count();
        for (unsigned n=0; n<100; ++n) ring.prepare(before);
        assert(ring.edge_count() == size);
    }
    if (mode == "idle-ack") {
        before.mem_req = 0; before.mem_ack = 1; before.esp_write_enable = 0;
        ring.prepare(before);
        const auto size = ring.edge_count();
        for (unsigned n=0; n<100; ++n) ring.prepare(before);
        assert(ring.edge_count() == size);
    }
    ring.observe_fault(after);
    ring.observe_fault(after); // repeated high count must not emit again
    assert(ring.events() == 1);
    if (mode == "cap") {
        for (unsigned n=0; n<100; ++n) { after.fault_count++; ring.observe_fault(after); }
        assert(ring.events() == 16 && !ring.enabled());
        ring.reset(); after.fault_count++; ring.observe_fault(after);
        assert(ring.events() == 16); // reset does not reset lifetime file/event cap
    }
    assert(ring.bytes() <= RetireFaultRing::file_limit);
    std::printf("%u %zu %zu\n", ring.events(), ring.bytes(), sizeof(ring));
    return ring.close() ? 0 : 4;
}
'''


class RetireFaultRingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="ventium-fault-ring.", dir="/tmp")
        cls.base = Path(cls.scratch.name)
        cls.exe = cls.base / "fault-ring-probe"
        compiler = shlex.split(os.environ.get("CXX", "c++"))
        subprocess.run(compiler + ["-std=c++17", "-Wall", "-Wextra", "-Werror",
                       "-I", str(ROOT / "tools"), "-x", "c++", "-",
                       "-o", str(cls.exe)], input=CPP, text=True, check=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def probe(self, mode, *args, expected=0):
        run = subprocess.run([str(self.exe), mode, *map(str, args)],
                             capture_output=True, text=True, timeout=5)
        self.assertEqual(run.returncode, expected, run.stdout + run.stderr)
        return run

    def capture(self, mode):
        path = self.base / (self._testMethodName + ".log")
        self.probe(mode, path)
        return path.read_text()

    def test_disabled_and_restore_guard(self):
        self.probe("disabled")
        self.probe("restore", expected=2)

    def test_retire_wraparound_order_and_post_state(self):
        text = self.capture("order")
        n = re.findall(r"^RETIRE n=(\d+)", text, re.M)
        self.assertEqual(list(map(int, n)), list(range(45, 301)))
        self.assertIn("post_cs=0028 post_ss=0030", text)
        self.assertIn("pre_cs=c000 pre_cs_base=000c0000", text)
        self.assertIn("ax=00000010 cx=00000011 dx=00000012 bx=00000013", text)
        self.assertIn("sp=00000014 bp=00000015 si=00000016 di=00000017", text)

    def test_fault_edge_source_and_actual_frame_bus(self):
        text = self.capture("fields")
        self.assertIn("source_pc=0000fb17", text)
        self.assertIn("source_linear_pre_cs=000cfb17", text)
        self.assertIn("pre_esp=abcdfff0 pre_flags=00023002", text)
        self.assertIn("pre_state=37 post_state=31", text)
        self.assertIn("size=2 rstrb=3 wstrb=0 rdata=12345678", text)
        self.assertIn("esp_we=1 esp_wd=abcdfff2", text)
        self.assertIn("ibuf=000102030405060708090a0b0c0d0e0f", text)
        self.assertIn("step=2 gate16=1 iret_ip=0000fb17 iret_cs=f000", text)

    def test_filter_and_duplicate_fault_count(self):
        text = self.capture("filter")
        self.assertEqual(len(re.findall(r"^FAULT event=", text, re.M)), 1)
        self.assertIn("count_delta=1", text)

    def test_counter_wrap_is_one_fault(self):
        self.assertIn("count_delta=1", self.capture("wrap"))

    def test_reset_clears_history_but_not_lifetime_caps(self):
        text = self.capture("reset")
        self.assertEqual(re.findall(r"^RETIRE n=(\d+)", text, re.M), ["900"])
        self.assertIn("epoch=2", text)

    def test_edge_ring_order_is_bounded(self):
        text = self.capture("edges")
        cycles = re.findall(r"^EDGE cycle=(\d+)", text, re.M)
        self.assertEqual(list(map(int, cycles)), list(range(37, 101)))

    def test_waiting_request_is_not_repeated_each_clock(self):
        self.capture("waiting")

    def test_idle_high_ack_does_not_evict_frame_history(self):
        self.capture("idle-ack")

    def test_event_file_memory_caps(self):
        text = self.capture("cap")
        self.assertEqual(len(re.findall(r"^FAULT event=", text, re.M)), 16)
        self.assertLess(len(text.encode()), 4 * 1024 * 1024)
        self.assertIn("FAULT-RING-END events=16", text)

    def test_existing_path_is_never_overwritten(self):
        path = self.base / "existing"
        path.write_text("retained evidence")
        self.probe("fields", path, expected=3)
        self.assertEqual(path.read_text(), "retained evidence")

    def test_argument_boundaries(self):
        run = self.probe("parse", "--ven-fault-ring", "new.log",
                         "--ven-fault-ring-start", "18446744073709551615",
                         "--ven-fault-ring-vector", "255", "--ven-fault-ring-events", "16")
        self.assertEqual(run.stdout.strip(), "18446744073709551615 255 16")
        self.probe("parse", "--ven-fault-ring", "new.log",
                   "--ven-fault-ring-start", "0x10", "--ven-fault-ring-vector", "0",
                   "--ven-fault-ring-events", "1")
        bad = [[], ["--ven-fault-ring"], ["--ven-fault-ring", ""],
               ["--ven-fault-ring", "one", "--ven-fault-ring", "two"],
               ["--ven-fault-ring-events", "1"],
               ["--ven-fault-ring", "new.log", "--ven-fault-ring-events", "0"],
               ["--ven-fault-ring", "new.log", "--ven-fault-ring-events", "17"],
               ["--ven-fault-ring", "new.log", "--ven-fault-ring-vector", "256"]]
        # No options is valid (disabled); every explicitly malformed option fails.
        for args in bad[1:]:
            with self.subTest(args=args): self.probe("parse", *args, expected=2)
        for value in ["-1", "+1", " 1", "1junk", "18446744073709551616"]:
            with self.subTest(value=value):
                self.probe("parse", "--ven-fault-ring", "new.log",
                           "--ven-fault-ring-start", value, expected=2)

    def test_integration_has_no_guest_pokes_or_extra_evals(self):
        source = (ROOT / "ao486-sim/ven/sim_ven.cpp").read_text()
        dpi = (ROOT / "ao486-sim/ven/vtm_dpi.cpp").read_text()
        prepare = source.index("g_fault_ring.prepare(before)")
        rising = source.index("set_clocks(1); step_vga_clock(); top->eval();", prepare)
        fault = source.index("g_fault_ring.observe_fault(after)", rising)
        ddr = source.index("ddr_service(); top->eval();", rising)
        self.assertLess(prepare, rising)
        self.assertLess(rising, fault)
        self.assertLess(fault, ddr)
        self.assertNotIn("top->eval()", source[rising+len("set_clocks(1); step_vga_clock(); top->eval();"):fault])
        capture = dpi[dpi.index("if (g_vtm_fault_ring"):dpi.index("if (g_vtm_dump >")]
        self.assertIn("snapshot.gpr = {eax, ecx, edx, ebx, esp, ebp, esi, edi}", capture)
        self.assertIn("snapshot.seg = {cs, ss, ds, es, fs, gs}", capture)
        self.assertNotIn("ao486_peek_guest", capture)
        self.assertNotIn("ddr", capture)


if __name__ == "__main__":
    unittest.main()
