#!/usr/bin/env python3
"""Bounded host-only passive PC snapshot tests; no DUT/native image compile.

Run inside tools/build_scope.sh with an explicit real-rootFS TMPDIR. Tiny
C++ compile <=45s/768MiB, each fixture <=5s; default test scratch is /tmp.
The test payload is deliberately NOT a native snapshot.
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
#include <cstdio>
#include <string>
using namespace ven_host;
static void write_payload(const char *path) {
    FILE *f = std::fopen(path, "wb"); assert(f);
    assert(std::fputs("HOST_TEST_NOT_NATIVE_SNAPSHOT", f) >= 0);
    assert(!std::fclose(f));
}
int main(int argc, char **argv) {
    assert(argc >= 2);
    const std::string mode(argv[1]);
    if (mode == "parse") {
        RetirePcSnapshotOptions o;
        for (int i = 2; i < argc; ++i) {
            const char *error = nullptr;
            const int rc = parse_retire_pc_snapshot_option(argc, argv, i, o, error);
            if (rc != 1) { std::puts(error ? error : "unrelated option"); return 2; }
        }
        RetirePcSnapshotContext c; c.save_file = std::getenv("SNAPSHOT_PATH");
        const char *flags = std::getenv("SNAPSHOT_CONTEXT");
        const std::string context = flags ? flags : "";
        c.restoring = context == "restore";
        c.save_at = context == "cycle";
        c.save_every = context == "periodic";
        c.stop_retire = context == "retire-stop";
        c.mouse = context == "mouse" || context == "mouse-v4";
        c.snapshot_v4 = context == "mouse-v4";
        c.save_stop = context == "save-stop";
        if (const char *error = validate_retire_pc_snapshot_options(o, c)) {
            std::puts(error); return 2;
        }
        std::printf("OPTIONS %04x:%08x occurrence=%llu after=%llu\n", unsigned(o.cs), o.pc,
            (unsigned long long)o.occurrence, (unsigned long long)o.after_retire);
        return 0;
    }
    if (mode == "disabled") {
        RetirePcSnapshot observer; RetirePcSnapshotOptions o; RetirePcSnapshotContext c;
        const char *error = nullptr;
        assert(observer.open(o, c, error));
        assert(!observer.enabled() && !observer.pending() && !observer.saved());
        assert(observer.retire({}) && !observer.finish_error() && !observer.history_count());
        return 0;
    }
    assert(argc == 3);
    const std::string path(argv[2]);
    RetirePcSnapshotOptions o; o.enabled = true; o.cs = 0x28; o.pc = 0xc002a7bc;
    if (mode == "filter") { o.after_retire = 2; o.occurrence = 2; }
    RetirePcSnapshotContext c; c.save_file = argv[2]; c.snapshot_v4 = true;
    RetirePcSnapshot observer; const char *error = nullptr;
    if (!observer.open(o, c, error)) { std::puts(error); return 3; }
    FaultRetireSnapshot s; s.seg = {0x28,0x30,0x38,0x40,0x48,0x50};
    s.gpr = {1,2,3,4,5,6,7,8}; s.eflags = 0x202;
    s.retire = 1; s.core_n = 0; s.cycle = 10; s.fetch_pc = o.pc;
    if (mode == "never" || mode == "stale" || mode == "history") s.fetch_pc++;
    if (mode == "missing-first" || mode == "missing-first42" || mode == "missing-first0") {
        s.retire = mode == "missing-first42" ? 42 : mode == "missing-first0" ? 0 : 2;
        assert(!observer.retire(s) && observer.finish_error()); return 42;
    }
    if (mode == "wrong-cs") s.seg[0]++;
    assert(observer.retire(s));
    if (mode == "never" || mode == "wrong-cs") {
        assert(!observer.pending() && observer.finish_error()); return 42;
    }
    if (mode == "stale") {
        s.fetch_pc = o.pc;
        assert(!observer.retire(s) && observer.failed() && observer.finish_error()); return 42;
    }
    if (mode == "filter") {
        for (unsigned n = 2; n <= 5; ++n) {
            s.retire = n; s.core_n = n-1; s.cycle = 10+n;
            s.fetch_pc = n == 4 ? o.pc+1 : o.pc;
            assert(observer.retire(s));
            assert(observer.pending() == (n == 5));
        }
        assert(observer.matches() == 2 && observer.trigger().retire == 5);
        assert(observer.history_count() == 4);
    }
    if (mode == "history") {
        for (unsigned n = 2; n <= 301; ++n) {
            s.retire = n; s.core_n = n-1; s.cycle = 10+n;
            s.fetch_pc = n == 301 ? o.pc : o.pc+1;
            assert(observer.retire(s));
        }
        assert(observer.history_count() == 256);
        assert(observer.history(0).retire == 45 && observer.history(255).retire == 300);
    }
    assert(observer.pending());
    const auto hit = observer.trigger(); const auto history = observer.history_count();
    // V callback in SAME clock must not replace the earlier U match.
    ++s.retire; ++s.core_n; s.fetch_pc = 0xdeadbeef; s.gpr[0] = 0x12345678;
    assert(observer.retire(s));
    assert(observer.trigger().retire == hit.retire && observer.trigger().fetch_pc == o.pc);
    assert(observer.trigger().gpr[0] == 1 && observer.history_count() == history);
    if (mode == "symlink" || mode == "replace" || mode == "hardlink" || mode == "nonempty") {
        if (mode == "symlink") {
            assert(!::unlink(path.c_str()));
            write_payload((path+".victim").c_str());
            assert(!::symlink((path+".victim").c_str(), path.c_str()));
        } else if (mode == "replace") {
            assert(!::rename(path.c_str(), (path+".old").c_str())); write_payload(path.c_str());
        } else if (mode == "hardlink") {
            assert(!::link(path.c_str(), (path+".link").c_str()));
        } else write_payload(path.c_str());
        assert(!observer.prepare_save(s.cycle+1, s.retire, error));
        assert(observer.finish_error()); return 42;
    }
    if (mode == "wrong-save-counter") {
        assert(!observer.prepare_save(s.cycle+1, s.retire-1, error)); return 42;
    }
    assert(observer.prepare_save(s.cycle+2, s.retire, error));
    assert(observer.serialization_path());
    if (mode == "race-symlink" || mode == "race-hardlink") {
        const std::string victim = path + ".victim";
        FILE *f = std::fopen(victim.c_str(), "wb"); assert(f);
        assert(std::fputs("FOREIGN_MATERIAL_PRESERVE", f) >= 0); assert(!std::fclose(f));
        assert(!::unlink(path.c_str()));
        if (mode == "race-symlink") assert(!::symlink(victim.c_str(), path.c_str()));
        else assert(!::link(victim.c_str(), path.c_str()));
        // This is the actual writer's open(...,O_TRUNC) operation, not a
        // mocked ownership check. The reopened descriptor must be our inode.
        write_payload(observer.serialization_path());
        f = std::fopen(victim.c_str(), "rb"); assert(f);
        char bytes[64]{}; assert(std::fread(bytes, 1, sizeof(bytes)-1, f) > 0);
        assert(!std::fclose(f)); assert(std::string(bytes) == "FOREIGN_MATERIAL_PRESERVE");
        assert(!observer.complete_save(s.cycle+2, s.retire, error));
        assert(observer.finish_error()); return 42;
    }
    if (mode != "empty-completion") write_payload(observer.serialization_path());
    if (mode == "post-hardlink") assert(!::link(path.c_str(), (path+".link").c_str()));
    const auto complete_cycle = s.cycle + (mode == "wrong-completion" ? 3 : 2);
    const bool completed = observer.complete_save(complete_cycle, s.retire, error);
    if (mode == "empty-completion" || mode == "post-hardlink" || mode == "wrong-completion") {
        assert(!completed && observer.finish_error()); return 42;
    }
    assert(completed && observer.saved() && !observer.enabled() && !observer.finish_error());
    assert(observer.report(stdout));
    assert(!observer.report(stdout));
    return 0;
}
'''


def limits():
    cap = 768 * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (cap, cap))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class RetirePcSnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(
            prefix="ventium-retire-pc-host.", dir=os.environ.get("RETIRE_PC_TEST_TMPDIR", "/tmp"))
        cls.directory = Path(cls.scratch.name)
        source = cls.directory / "fixture.cpp"
        source.write_text(CPP)
        cls.binary = cls.directory / "fixture"
        result = subprocess.run(
            ["c++", "-std=c++17", "-O0", "-Wall", "-Wextra", "-Werror",
             "-I", str(ROOT / "tools"), str(source), "-o", str(cls.binary)],
            text=True, capture_output=True, timeout=45, preexec_fn=limits)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def run_fixture(self, mode, *args, context="", path=None):
        if path is None:
            path = self.directory / (self.id().split(".")[-1] + "-" + mode + ".snap")
        env = dict(os.environ, SNAPSHOT_PATH=str(path), SNAPSHOT_CONTEXT=context)
        return subprocess.run([str(self.binary), mode, *map(str, args)], env=env,
                              text=True, capture_output=True, timeout=5, preexec_fn=limits)

    def test_disabled_neutral(self):
        self.assertEqual(self.run_fixture("disabled").returncode, 0)

    def test_valid_parse(self):
        r = self.run_fixture("parse", "--save-at-retired-pc", "0028:C002A7BC",
                             "--save-pc-occurrence", "2", "--save-pc-after-retire", "0x100")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn("0028:c002a7bc occurrence=2 after=256", r.stdout)

    def test_zero_pc_and_selector_valid(self):
        self.assertEqual(self.run_fixture("parse", "--save-at-retired-pc", "0:0").returncode, 0)

    def test_save_stop_and_mouse_v4(self):
        for context in ("save-stop", "mouse-v4"):
            with self.subTest(context=context):
                self.assertEqual(self.run_fixture("parse", "--save-at-retired-pc", "28:1",
                                                   context=context).returncode, 0)

    def test_invalid_targets(self):
        for target in ("", "28", ":1", "28:", "28:1:2", "10000:1", "28:100000000",
                       "-1:1", "+28:1", "28: 1", "28:0x", "gg:1"):
            with self.subTest(target=target):
                self.assertEqual(self.run_fixture("parse", "--save-at-retired-pc", target).returncode, 2)

    def test_invalid_integer_options(self):
        for option in ("--save-pc-occurrence", "--save-pc-after-retire"):
            for value in ("", "-1", "+1", " 1", "1.0", "1e2", "0x", "18446744073709551616"):
                with self.subTest(option=option, value=value):
                    self.assertEqual(self.run_fixture("parse", "--save-at-retired-pc", "28:1",
                                                       option, value).returncode, 2)
        for value in ("0", "1000001"):
            self.assertEqual(self.run_fixture("parse", "--save-at-retired-pc", "28:1",
                                               "--save-pc-occurrence", value).returncode, 2)

    def test_missing_and_unrelated_options(self):
        for args in (("--save-at-retired-pc",), ("--save-pc-occurrence",),
                     ("--save-pc-after-retire",), ("--unrelated",)):
            self.assertEqual(self.run_fixture("parse", *args).returncode, 2)

    def test_duplicate_options(self):
        for option, value in (("--save-at-retired-pc", "28:1"),
                              ("--save-pc-occurrence", "1"), ("--save-pc-after-retire", "0")):
            args = [option, value, option, value]
            if option != "--save-at-retired-pc": args = ["--save-at-retired-pc", "28:1", *args]
            self.assertEqual(self.run_fixture("parse", *args).returncode, 2)

    def test_filters_require_target(self):
        for option, value in (("--save-pc-occurrence", "1"), ("--save-pc-after-retire", "0")):
            self.assertEqual(self.run_fixture("parse", option, value).returncode, 2)

    def test_restore_and_trigger_conflicts(self):
        for context in ("restore", "cycle", "periodic", "retire-stop", "mouse"):
            self.assertEqual(self.run_fixture("parse", "--save-at-retired-pc", "28:1",
                                               context=context).returncode, 2)

    def test_existing_symlink_directory_hardlink_output(self):
        original = self.directory / "material"
        original.write_text("preserve me")
        link = self.directory / "material-link"
        link.hardlink_to(original)
        sym = self.directory / "material-symlink"
        sym.symlink_to(original)
        for path in (original, link, sym, self.directory):
            self.assertEqual(self.run_fixture("parse", "--save-at-retired-pc", "28:1", path=path).returncode, 2)
        self.assertEqual(original.read_text(), "preserve me")

    def test_missing_symlink_parent_and_traversal(self):
        parent = self.directory / "parent-symlink"
        parent.symlink_to(self.directory, target_is_directory=True)
        for path in (self.directory / "missing/file", parent / "new.snap", self.directory / "../new.snap"):
            self.assertEqual(self.run_fixture("parse", "--save-at-retired-pc", "28:1", path=path).returncode, 2)

    def test_earliest_U_match_survives_V_same_clock(self):
        path = self.directory / "uv.snap"
        r = self.run_fixture("uv", path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("trigger_cycle=10 trigger_retire=1 save_cycle=12 save_retire=2", r.stdout)
        self.assertIn("cycle_overshoot=2 retire_overshoot=1", r.stdout)
        self.assertIn("PC-TRIGGER cycle=10 retire=1", r.stdout)
        self.assertEqual(r.stdout.count("PC-SNAPSHOT v=1"), 1)

    def test_occurrence_and_exclusive_start_filter(self):
        r = self.run_fixture("filter", self.directory / "filter.snap")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("occurrence=2 after_retire_exclusive=2 trigger_cycle=15 trigger_retire=5", r.stdout)
        self.assertIn("history_count=4", r.stdout)

    def test_history_cap_and_order(self):
        r = self.run_fixture("history", self.directory / "history.snap")
        self.assertEqual(r.returncode, 0, r.stderr)
        history = [line for line in r.stdout.splitlines() if line.startswith("PC-HISTORY ")]
        self.assertEqual(len(history), 256)
        self.assertIn("retire=45 ", history[0])
        self.assertIn("retire=300 ", history[-1])
        self.assertLess(len(r.stdout), 128 * 1024)

    def test_never_stale_and_selector_mismatch_fail(self):
        for mode in ("never", "stale", "wrong-cs", "missing-first", "missing-first42", "missing-first0"):
            r = self.run_fixture(mode, self.directory / (mode + ".snap"))
            self.assertEqual(r.returncode, 42, r.stderr)
            self.assertNotIn("PC-SNAPSHOT", r.stdout)

    def test_reservation_tamper_fails_before_save(self):
        for mode in ("symlink", "replace", "hardlink", "nonempty", "wrong-save-counter"):
            r = self.run_fixture(mode, self.directory / (mode + ".snap"))
            self.assertEqual(r.returncode, 42, r.stderr)
            self.assertNotIn("PC-SNAPSHOT", r.stdout)

    def test_completion_tamper_empty_or_wrong_point_fails(self):
        for mode in ("empty-completion", "post-hardlink", "wrong-completion"):
            r = self.run_fixture(mode, self.directory / (mode + ".snap"))
            self.assertEqual(r.returncode, 42, r.stderr)
            self.assertNotIn("PC-SNAPSHOT", r.stdout)

    def test_leaf_race_never_truncates_foreign_inode(self):
        for mode in ("race-symlink", "race-hardlink"):
            path = self.directory / (mode + ".snap")
            r = self.run_fixture(mode, path)
            self.assertEqual(r.returncode, 42, r.stderr)
            self.assertEqual(Path(str(path) + ".victim").read_text(), "FOREIGN_MATERIAL_PRESERVE")
            self.assertNotIn("PC-SNAPSHOT", r.stdout)


if __name__ == "__main__":
    unittest.main()
