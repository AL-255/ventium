#!/usr/bin/env python3
"""Exercise the real full-PC DPI callback without compiling/running an RTL model.

This is a host integration test, not an architectural differential gate. Compile
the production vtm_dpi.cpp, with inert clock/memory providers and synthetic
callback arguments. No native snapshot or guest disk is read or written.
"""
import os
from pathlib import Path
import resource
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CPP = r'''
#include "retire_pc_snapshot.h"
#include <cassert>
#include <string>
uint64_t *ddr = nullptr;
volatile unsigned long g_disk_reads = 0;
static unsigned clock_reads = 0, memory_reads = 0;
double sc_time_stamp() { ++clock_reads; return 123.; }
extern "C" int ao486_peek_guest(unsigned int, void *, int) {
    ++memory_reads; std::abort();
}
extern ven_host::RetirePcSnapshot *g_vtm_pc_snapshot;
extern ven_host::RetireFaultRing *g_vtm_fault_ring;
extern "C" {
extern uint64_t g_vtm_retires, g_vtm_n;
extern uint32_t g_vtm_eip, g_vtm_eax;
extern uint16_t g_vtm_cs;
void vtm_retire(unsigned long long, unsigned int, unsigned int,
    unsigned int, unsigned int, unsigned int, unsigned int,
    unsigned int, unsigned int, unsigned int, unsigned int,
    unsigned short, unsigned short, unsigned short,
    unsigned short, unsigned short, unsigned short);
}
static void callback(uint64_t core_n, uint32_t pc, uint32_t eax) {
    vtm_retire(core_n, pc, 0x202, eax, 2, 3, 4, 5, 6, 7, 8,
               0x28, 0x30, 0x38, 0x40, 0x48, 0x50);
}
int main(int argc, char **argv) {
    assert(argc == 3);
    const std::string mode(argv[1]), path(argv[2]);
    ven_host::RetirePcSnapshot pc;
    ven_host::RetireFaultRing faults;
    if (mode != "disabled") {
        ven_host::RetirePcSnapshotOptions o;
        o.enabled = true; o.cs = 0x28; o.pc = 0xc002a7bc;
        if (mode == "v-match") o.pc = 0x12345678;
        ven_host::RetirePcSnapshotContext c;
        c.save_file = path.c_str();
        const char *error = nullptr;
        assert(pc.open(o, c, error));
        g_vtm_pc_snapshot = &pc;
    }
    if (mode == "both") {
        ven_host::FaultRingOptions o;
        const std::string fault_path = path + ".fault";
        o.path = fault_path.c_str();
        assert(faults.open(o));
        faults.reset(); faults.prepare({});
        g_vtm_fault_ring = &faults;
    }
    callback(40, 0xc002a7bc, 1); // actual U callback, arbitrary core counter
    callback(41, 0x12345678, 9); // actual V callback on the SAME clock
    assert(g_vtm_retires == 2 && g_vtm_n == 41);
    assert(g_vtm_eip == 0x12345678 && g_vtm_eax == 9 && g_vtm_cs == 0x28);
    assert(memory_reads == 0);
    if (mode == "disabled") {
        assert(clock_reads == 0 && !pc.enabled());
    } else {
        assert(clock_reads == 2 && pc.pending() && !pc.failed());
        const auto &hit = pc.trigger();
        assert(hit.cycle == 123 && hit.eflags == 0x202);
        assert(hit.gpr == (std::array<uint32_t, 8>{
            mode == "v-match" ? 9u : 1u, 2, 3, 4, 5, 6, 7, 8}));
        assert(hit.seg == (std::array<uint16_t, 6>{0x28,0x30,0x38,0x40,0x48,0x50}));
        assert(hit.retire == (mode == "v-match" ? 2u : 1u));
        assert(hit.core_n == (mode == "v-match" ? 41u : 40u));
        assert(pc.history_count() == (mode == "v-match" ? 1u : 0u));
        const char *error = nullptr;
        assert(pc.prepare_save(123, 2, error));
        if (mode == "both") assert(faults.retire_count() == 2);
    }
    g_vtm_pc_snapshot = nullptr; g_vtm_fault_ring = nullptr;
}
'''


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (768 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class RetirePcDpiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(
            prefix="ventium-retire-pc-dpi.", dir=os.environ.get("TMPDIR", "/tmp"))
        cls.directory = Path(cls.scratch.name)
        cls.source = cls.directory / "fixture.cpp"
        cls.source.write_text(CPP)
        cls.binary = cls.directory / "fixture"
        flags = ["c++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-I", str(ROOT / "tools")]
        obj = cls.directory / "vtm_dpi.o"
        # The production host build already suppresses unused variables in its
        # historical probes (e.g. tblval). Keep that waiver out of the fixture.
        commands = [flags + ["-Wno-unused-variable", "-c",
                            str(ROOT / "ao486-sim/ven/vtm_dpi.cpp"), "-o", str(obj)],
                    flags + [str(cls.source), str(obj), "-o", str(cls.binary)]]
        for command in commands:
            result = subprocess.run(command, text=True, capture_output=True,
                                    timeout=45, preexec_fn=limits)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def check_mode(self, mode):
        env = dict(os.environ)
        env.pop("VEN_PCTRACE", None)
        result = subprocess.run(
            [str(self.binary), mode, str(self.directory / (mode + ".snap"))],
            env=env, text=True, capture_output=True, timeout=5, preexec_fn=limits)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_disabled_preserves_dpi_globals_without_clock_or_memory_reads(self):
        self.check_mode("disabled")

    def test_actual_u_callback_match_survives_v_callback(self):
        self.check_mode("u-match")

    def test_actual_v_callback_matches_with_prior_u_history(self):
        self.check_mode("v-match")

    def test_fault_ring_and_pc_observer_both_receive_each_callback(self):
        self.check_mode("both")


if __name__ == "__main__":
    unittest.main()
