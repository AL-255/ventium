#!/usr/bin/env python3
"""Exercise cycle/CRC attribution and score eligibility independently of RTL."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from run_coremark_matrix import is_accepted, load_plan, parse_clock_window, parse_crc_output, parse_input_settle, parse_memory_shapes, parse_result, parse_verilator_host_optimization, parse_verilator_threads, summarize, validate_host_lto_plan
from gen_model_input_snapshot import generate, input_ports


STDOUT_10 = """2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 1
Total time (secs): 0.001000
Iterations/Sec   : 10000.000000
ERROR! Must execute for at least 10 secs for a valid result!
Iterations       : 10
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0xfcaf
Errors detected
"""
LOG_10 = """tb: stop: FREE-RUN guest exit_group(0) after 3660809 retired in 5622250 clocks
-- clocks by FSM state (only non-zero) --
 state 0 1 0.0%
 state 1 13099 0.2%
 state 28 5609150 99.8%
-- memory pressure by FSM state --
 state 28 req-wait clocks 0
"""
WORKLOAD_10 = {"label": "performance10", "seed": "performance", "iterations": 10, "crcfinal": "fcaf"}
CLOCK_QUERIES = """[clock-cycle] n=1000 nr=403 clock_id=0 cycle=10000
[clock-cycle] n=3600000 nr=403 clock_id=0 cycle=5600000
"""
MEMORY_SHAPES = """-- D-memory producer shape (events, not exclusive clocks) --
    mem-shape site=S_LOAD width=2 low=2 hit=1 events=100 old_dword_bad=1 true_boundary_bad=0
    mem-shape site=S_LOAD width=4 low=3 hit=0 events=2 old_dword_bad=1 true_boundary_bad=1
    mem-producer site=S_LOAD events=102 cells=102 old_dword_bad=102 true_boundary_bad=2 false_old_bad=100 read_misses=2
    mem-producer site=S_LOAD2 events=0 cells=0 old_dword_bad=0 true_boundary_bad=0 false_old_bad=0 read_misses=0
    mem-producer site=S_STORE events=0 cells=0 old_dword_bad=0 true_boundary_bad=0 false_old_bad=0 read_misses=0
    mem-producer site=FAST_READ events=0 cells=0 old_dword_bad=0 true_boundary_bad=0 false_old_bad=0 read_misses=0
    mem-producer site=FAST_WRITE events=0 cells=0 old_dword_bad=0 true_boundary_bad=0 false_old_bad=0 read_misses=0
"""


class CoreMarkMatrixTests(unittest.TestCase):
    @staticmethod
    def accepted_result():
        workload = dict(WORKLOAD_10, iterations=1500, crcfinal="25b5")
        stdout = STDOUT_10.replace("0.001000", "22.010000").replace("Iterations       : 10", "Iterations       : 1500")
        stdout = stdout.replace("0xfcaf", "0x25b5").replace("Errors detected", "Correct operation validated")
        stdout = stdout.replace("ERROR! Must execute for at least 10 secs for a valid result!\n", "")
        result = parse_result(LOG_10, stdout, workload)
        result.update(returncode=0, binary_unchanged=True, image_unchanged=True,
                      compile_record_unchanged=True, generated_headers_unchanged=True)
        return result, stdout, workload

    def test_correctness_acceptance_is_not_performance_eligibility(self):
        result, _, _ = self.accepted_result()
        self.assertTrue(is_accepted(result))
        result.update(score_eligible=False, clock_window_score_eligible=False,
                      cm_per_mhz_total_program=0.01, p54_fidelity_rejections=["VEN_UOPCACHE"])
        self.assertTrue(is_accepted(result))

    def test_valid_crc_and_exit_zero_cannot_hide_guest_error_or_short_run(self):
        result, stdout, workload = self.accepted_result()
        for changed in (stdout + "ERROR!\n", stdout + "Errors detected\n",
                        stdout.replace("22.010000", "0.001000"),
                        stdout.replace("Correct operation validated", "validation missing")):
            with self.subTest(changed=changed):
                failed = dict(result, **parse_result(LOG_10, changed, workload))
                self.assertTrue(failed["crc_ok"])
                self.assertEqual(failed["returncode"], 0)
                self.assertFalse(is_accepted(failed))

    def test_graceful_timeout_zero_and_other_incomplete_results_are_rejected(self):
        result, _, _ = self.accepted_result()
        for key, value in (("timed_out", True), ("interrupted", True), ("stopping", True),
                           ("failure", "failed observation"), ("returncode", 1),
                           ("returncode", False), ("returncode", None)):
            with self.subTest(key=key, value=value):
                self.assertFalse(is_accepted(dict(result, **{key: value})))
        for key in ("complete", "crc_ok", "iterations_ok", "dataset_ok", "coremark_report_validated",
                    "guest_duration_ok", "binary_unchanged", "image_unchanged",
                    "compile_record_unchanged", "generated_headers_unchanged", "returncode"):
            with self.subTest(missing=key):
                missing = dict(result)
                del missing[key]
                self.assertFalse(is_accepted(missing))

    def test_explicit_one_hour_limit_preserves_existing_plan_deadlines(self):
        with tempfile.TemporaryDirectory(prefix="ventium-coremark-plan-test.") as directory:
            root = Path(directory)
            image = root / "image.json"
            image.write_text("{}\n")
            plan_file = root / "plan.json"
            workload = dict(WORKLOAD_10, image=str(image), max_insn=10000000,
                            max_cycles=30000000)
            profile = {"model_threads": 1, "input_snapshot_capable": False}
            with patch("run_coremark_matrix.compile_profile", return_value=profile):
                for deadline in (1, 600, 1800, 1801, 3600):
                    with self.subTest(deadline=deadline):
                        plan_file.write_text(json.dumps({
                            "version": 1,
                            "cases": [{"label": "test", "binary": sys.executable}],
                            "workloads": [dict(workload, timeout_seconds=deadline)]}))
                        loaded = load_plan(plan_file)
                        self.assertEqual(loaded["workloads"][0]["timeout_seconds"], deadline)
                for deadline in (0, -1, True, "3600", 3600.0, 3601):
                    with self.subTest(deadline=deadline):
                        plan_file.write_text(json.dumps({
                            "version": 1,
                            "cases": [{"label": "test", "binary": sys.executable}],
                            "workloads": [dict(workload, timeout_seconds=deadline)]}))
                        with self.assertRaises(ValueError):
                            load_plan(plan_file)

    def test_plan_cannot_mislabel_host_lto_binary(self):
        validate_host_lto_plan({"label": "legacy"})
        for actual in (False, True):
            validate_host_lto_plan({"label": "matching", "host_lto_serial": actual,
                                    "profile": {"host_lto_serial": actual}})
            for requested in (not actual, 0, 1, "true"):
                with self.subTest(actual=actual, requested=requested):
                    with self.assertRaises(ValueError):
                        validate_host_lto_plan({"label": "bad", "host_lto_serial": requested,
                                               "profile": {"host_lto_serial": actual}})

    def test_prefix13_and_pair9_bins_remain_exclusive(self):
        log = """tb: stop: FREE-RUN guest exit_group(0) after 3660809 retired in 100 clocks
-- clocks by FSM state (only non-zero) --
 state 0 1 1.0%
 state 21 99 99.0%
-- memory pressure by FSM state --
  S_PIPE clocks 99   NON-S_PIPE (slow FSM) clocks 1
  -- S_PIPE clocks by FIRST bail arm (priority order) --
    [12] 90 90.0% ISSUE             (retired 1 or 2 this clock)
    [13] 9 9.0% PREFIX_D1         (paid operand-size prefix clock)
  -- V-slot result for U-side ISSUE clocks (sums to ISSUE) --
    10 !pipe_pair_ok      (P5 U/V pairing rule/hazard)
    60 PAIRED             (U + V retired)
    20 prefix V subset   (register/Jcc V only)
  -- pairing-rule first rejection (sums to !pipe_pair_ok) --
    10 U-to-V RAW
  -- unrelated next profile --
"""
        result = parse_result(log, STDOUT_10, WORKLOAD_10)
        self.assertTrue(result["pipe_reconciles"])
        self.assertTrue(result["pairing_reconciles"])
        self.assertEqual(result["pipe_first_arm_sum"], 99)
        self.assertEqual(result["pair_first_result_sum"], 90)
        self.assertEqual(result["pair_rule_rejection_sum"], 10)
        self.assertEqual(result["pair_first_result_clocks"]["prefix V subset   (register/Jcc V only)"], 20)
        for original, replacement in (("20 prefix V subset", "21 prefix V subset"),
                                      ("10 U-to-V RAW", "9 U-to-V RAW")):
            bad = parse_result(log.replace(original, replacement), STDOUT_10, WORKLOAD_10)
            self.assertFalse(bad["pairing_reconciles"])
            self.assertIn("V-slot", bad["failure"])

    def test_host_serial_lto_is_not_an_rtl_define(self):
        plain = 'C "--cc -MAKEFLAGS OPT_FAST=-O3 -MAKEFLAGS OPT=-march=native +define+VEN_IC_BRAM"'
        self.assertFalse(parse_verilator_host_optimization(plain)["host_lto_serial"])
        bundle = "-MAKEFLAGS USER_CPPFLAGS=-flto=1 -MAKEFLAGS USER_LDFLAGS=-flto=1 -MAKEFLAGS AR=gcc-ar"
        result = parse_verilator_host_optimization(f'C "--cc {bundle} +define+VEN_IC_BRAM"')
        self.assertTrue(result["host_lto_serial"])
        self.assertEqual(len(result["host_makeflags"]), 3)
        self.assertTrue(parse_verilator_host_optimization(
            f'C "--cc {bundle.replace("-MAKEFLAGS ", "-MAKEFLAGS=")}"')["host_lto_serial"])
        for invalid in (bundle.replace("USER_LDFLAGS=-flto=1", "USER_LDFLAGS=-flto=auto"),
                        bundle.replace("-MAKEFLAGS AR=gcc-ar", ""),
                        bundle + " -MAKEFLAGS USER_CPPFLAGS=-flto=1",
                        bundle + " -CFLAGS -flto=32",
                        "-CFLAGS -flto=1", "-MAKEFLAGS AR=gcc-ar"):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    parse_verilator_host_optimization(f'C "--cc {invalid}"')

    def test_unchanged_input_reports_keep_every_clock_edge(self):
        report = "[input-settle] ports=18 cells=18 mandatory_edge_evals=200 full_settle_evals=3 skipped_settle_evals=197"
        result = parse_input_settle(report, 100, True)
        self.assertTrue(result["input_settle_reconciles"])
        self.assertEqual(result["mandatory_edge_evals"], 200)
        self.assertEqual(result["skipped_settle_evals"], 197)
        self.assertEqual(parse_input_settle("", 100, False), {"input_settle_requested": False})
        invalid = [("", True), (report, False), (report + "\n" + report, True),
                   (report.replace("mandatory_edge_evals=200", "mandatory_edge_evals=199"), True),
                   (report.replace("skipped_settle_evals=197", "skipped_settle_evals=198"), True),
                   (report.replace("ports=18", "ports=0"), True),
                   (report.replace("cells=18", "cells=17"), True),
                   (report.replace("full_settle_evals=3", "full_settle_evals=oops"), True)]
        for text, requested in invalid:
            with self.subTest(text=text, requested=requested):
                with self.assertRaises(ValueError):
                    parse_input_settle(text, 100, requested)

    def test_generated_snapshot_covers_every_input_and_wide_word(self):
        header = """// PORTS
    // Generated reference ports; outputs must not join the snapshot.
    VL_IN8(&clk,0,0);
    VL_IN8(&byte,7,0);
    VL_IN16(&word,15,0);
    VL_IN(&dword,31,0);
    VL_IN64(&qword,63,0);
    VL_INW(&wide,79,0,3);
    VL_OUT8(&ack,0,0);
    VL_OUTW(&result,95,0,3);
// CELLS
"""
        self.assertEqual([port["name"] for port in input_ports(header)],
                         ["clk", "byte", "word", "dword", "qword", "wide"])
        output = generate(header)
        for name in ("clk", "byte", "word", "dword", "qword", "wide[0]", "wide[1]", "wide[2]"):
            self.assertIn(f"top.{name})", output)
        self.assertNotIn("top.ack", output)
        self.assertNotIn("top.result", output)
        self.assertIn("input_ports = 6", output)
        self.assertIn("input_cells = 8", output)

    def test_generated_snapshot_fails_closed_on_unknown_ports(self):
        invalid = ["VL_INOUT8(&io,0,0);", "VL_IN128(&a,127,0);",
                   "VL_IN8(&a[4],7,0);", "VL_IN8(&a,15,0);",
                   "VL_INW(&a,79,0,2);", "VL_INW(&a,31,0,1);",
                   "VL_IN(&a,0,7);", "VL_IN8(&clk,0,0);",
                   "unrecognized_input a;", "VL_OUTSTRING(&out);"]
        for line in invalid:
            with self.subTest(line=line):
                with self.assertRaises(ValueError):
                    input_ports(f"// PORTS\nVL_IN8(&clk,0,0);\n{line}\n// CELLS")
        for header in ("", "// PORTS\nVL_IN(&a,31,0);\n// CELLS"):
            with self.assertRaises(ValueError):
                input_ports(header)

    def test_model_concurrency_comes_from_compile_command(self):
        self.assertEqual(parse_verilator_threads('C "--cc --exe"'),
                         {"model_threads": 1, "threads_dpi": "default"})
        for count in (1, 2, 4, 8):
            for separator in (" ", "="):
                record = f'C "--cc --threads{separator}{count} --threads-dpi{separator}none -DVEN_TB_MODEL_THREADS={count}"'
                self.assertEqual(parse_verilator_threads(record),
                                 {"model_threads": count, "threads_dpi": "none"})

    def test_ambiguous_or_concurrent_dpi_profiles_are_rejected(self):
        invalid = ['C "--cc --threads 2"',
                   'C "--cc --threads 4 --threads-dpi all"',
                   'C "--cc --threads 2 --threads-dpi pure"',
                   'C "--cc --threads 3 --threads-dpi none"',
                   'C "--cc --threads 0 --threads-dpi none"',
                   'C "--cc --threads 2 --threads 2 --threads-dpi none"',
                   'C "--cc --threads 2 --threads-dpi none -DVEN_TB_MODEL_THREADS=1"',
                   'C "--cc --threads 2 --threads-dpi none"',
                   'C "--cc --threads 2 --threads-dpi none -DVEN_TB_MODEL_THREADS=2 -DVEN_TB_MODEL_THREADS=2"',
                   'C "--cc --threads-dpi none --threads-dpi none"',
                   'C "--cc --threads"',
                   'C "--cc --threads --threads-dpi none"',
                   'C "--cc"\nC "--cc"', '']
        for record in invalid:
            with self.subTest(record=record):
                with self.assertRaises(ValueError):
                    parse_verilator_threads(record)

    def test_short_run_checks_every_clock_but_cannot_claim_score(self):
        result = parse_result(LOG_10, STDOUT_10, WORKLOAD_10)
        self.assertTrue(result["complete"])
        self.assertTrue(result["crc_ok"])
        self.assertTrue(result["iterations_ok"])
        self.assertTrue(result["dataset_ok"])
        self.assertTrue(result["fsm_reconciles"])
        self.assertEqual(result["fsm_sum"], 5622250)
        self.assertAlmostEqual(result["cm_per_mhz_total_program"], 1.778647338, places=8)
        self.assertFalse(result["score_eligible"])

    def test_validated_full_run_is_score_candidate(self):
        workload = dict(WORKLOAD_10, iterations=1500, crcfinal="25b5")
        stdout = STDOUT_10.replace("0.001000", "22.010000").replace("Iterations       : 10", "Iterations       : 1500")
        stdout = stdout.replace("0xfcaf", "0x25b5").replace("Errors detected", "Correct operation validated")
        stdout = stdout.replace("ERROR! Must execute for at least 10 secs for a valid result!\n", "")
        result = parse_result(LOG_10, stdout, workload)
        self.assertTrue(result["score_eligible"])

    def test_crc_error_invalidates_completed_run(self):
        result = parse_result(LOG_10, STDOUT_10.replace("0xe714", "0xe715"), WORKLOAD_10)
        self.assertTrue(result["complete"])
        self.assertFalse(result["crc_ok"])
        self.assertFalse(result["score_eligible"])

    def test_unbalanced_profile_is_explicit_failure(self):
        result = parse_result(LOG_10.replace("5609150", "5609151"), STDOUT_10, WORKLOAD_10)
        self.assertFalse(result["fsm_reconciles"])
        self.assertIn("do not sum", result["failure"])

    def test_pipe_subpartition_must_reconcile_independently(self):
        log = LOG_10 + """S_PIPE clocks 5609150 NON-S_PIPE (slow FSM) clocks 13100
-- S_PIPE clocks by FIRST bail arm (priority order) --
 [ 0] 2000 0.0% stall_cnt!=0
 [12] 5607150 99.9% ISSUE
-- V-slot result --
"""
        result = parse_result(log, STDOUT_10, WORKLOAD_10)
        self.assertTrue(result["pipe_reconciles"])
        result = parse_result(log.replace("5607150", "5607151"), STDOUT_10, WORKLOAD_10)
        self.assertFalse(result["pipe_reconciles"])
        self.assertIn("bail-arm", result["failure"])

    def test_partial_or_duplicate_exit_does_not_claim_completion(self):
        for log in ("tb: reached --max-cycles", LOG_10 + LOG_10):
            self.assertFalse(parse_result(log, STDOUT_10, WORKLOAD_10)["complete"])

    def test_duplicate_crc_is_ambiguous(self):
        with self.assertRaises(ValueError):
            parse_crc_output(STDOUT_10 + "[0]crclist : 0xe714\n")

    def test_exact_clock_window_is_supplementary_only_for_short_run(self):
        result = parse_result(CLOCK_QUERIES + LOG_10, STDOUT_10, WORKLOAD_10, {"nr": 403, "clock_id": 0})
        self.assertTrue(result["clock_window_valid"])
        self.assertTrue(result["clock_window_requested"])
        self.assertEqual(result["clock_window_clocks"], 5590000)
        self.assertEqual(result["clock_window_retired"], 3599000)
        self.assertAlmostEqual(result["cm_per_mhz_clock_window"], 10_000_000 / 5590000)
        self.assertAlmostEqual(result["cm_per_mhz_total_program"], 10_000_000 / 5622250)
        self.assertFalse(result["clock_window_score_eligible"])

    def test_clock_window_cannot_hide_malformed_or_extra_queries(self):
        invalid = ["", CLOCK_QUERIES.splitlines()[0] + "\n", CLOCK_QUERIES * 2,
                   CLOCK_QUERIES + "[clock-cycle] corrupt extra marker\n",
                   CLOCK_QUERIES.replace("n=1000", "n=oops"),
                   CLOCK_QUERIES.replace("clock_id=0", "clock_id=1"),
                   CLOCK_QUERIES.replace("nr=403", "nr=265"),
                   CLOCK_QUERIES.replace("cycle=5600000", "cycle=6000000"),
                   CLOCK_QUERIES.replace("cycle=5600000", "cycle=10000"),
                   CLOCK_QUERIES.replace("n=3600000", "n=4000000"),
                   CLOCK_QUERIES.replace("n=3600000", "n=1000")]
        for log in invalid:
            with self.subTest(log=log):
                result = parse_result(log + LOG_10, STDOUT_10, WORKLOAD_10, {"nr": 403, "clock_id": 0})
                self.assertFalse(result["clock_window_valid"])
                self.assertFalse(result["clock_window_score_eligible"])
                self.assertNotIn("cm_per_mhz_clock_window", result)
                self.assertIn("clock_window_failure", result)

    def test_legacy_clock_syscall_requires_explicit_matching_expectation(self):
        log = CLOCK_QUERIES.replace("nr=403", "nr=265")
        result = parse_clock_window(log, 3660809, 5622250, 10, expected_nr=265)
        self.assertTrue(result["clock_window_valid"])

    def test_complete_validated_run_can_use_verified_clock_window(self):
        workload = dict(WORKLOAD_10, iterations=1500, crcfinal="25b5")
        stdout = STDOUT_10.replace("0.001000", "22.010000").replace("Iterations       : 10", "Iterations       : 1500")
        stdout = stdout.replace("0xfcaf", "0x25b5").replace("Errors detected", "Correct operation validated")
        stdout = stdout.replace("ERROR! Must execute for at least 10 secs for a valid result!\n", "")
        result = parse_result(CLOCK_QUERIES + LOG_10, stdout, workload, {"nr": 403, "clock_id": 0})
        self.assertTrue(result["score_eligible"])
        self.assertTrue(result["clock_window_score_eligible"])
        result = parse_result(CLOCK_QUERIES * 2 + LOG_10, stdout, workload, {"nr": 403, "clock_id": 0})
        self.assertTrue(result["score_eligible"])
        self.assertFalse(result["clock_window_score_eligible"])

    def test_error_banner_prevents_score_even_with_validation_text(self):
        workload = dict(WORKLOAD_10, iterations=1500, crcfinal="25b5")
        stdout = STDOUT_10.replace("0.001000", "22.010000").replace("Iterations       : 10", "Iterations       : 1500")
        stdout = stdout.replace("0xfcaf", "0x25b5").replace("Errors detected", "Correct operation validated")
        result = parse_result(CLOCK_QUERIES + LOG_10, stdout, workload)
        self.assertFalse(result["score_eligible"])
        self.assertFalse(result["clock_window_score_eligible"])

    def test_compact_memory_producers_reconcile_independently_of_clocks(self):
        result = parse_result(MEMORY_SHAPES + LOG_10, STDOUT_10, WORKLOAD_10)
        self.assertTrue(result["memory_producer_reconciles"])
        self.assertTrue(result["fsm_reconciles"])
        self.assertEqual(result["memory_producer_summary"]["S_LOAD"]["false_old_bad"], 100)
        self.assertEqual(result["memory_producer_summary"]["S_LOAD"]["read_misses"], 2)
        self.assertNotIn("memory_producer_reconciles", parse_result(LOG_10, STDOUT_10, WORKLOAD_10))

    def test_compact_memory_producer_shape_cannot_be_ambiguous(self):
        invalid = [MEMORY_SHAPES.replace("cells=102", "cells=103"),
                   MEMORY_SHAPES.replace("true_boundary_bad=0\n", "true_boundary_bad=1\n", 1),
                   MEMORY_SHAPES + MEMORY_SHAPES,
                   MEMORY_SHAPES.replace("site=FAST_WRITE events=0", "site=WRONG events=0"),
                   MEMORY_SHAPES.replace("width=2 low=2", "width=2 low=9")]
        for log in invalid:
            with self.subTest(log=log):
                result = parse_result(log + LOG_10, STDOUT_10, WORKLOAD_10)
                self.assertFalse(result["memory_producer_reconciles"])
                self.assertFalse(result["score_eligible"])
                self.assertIn("failure", result)

    def test_both_seeds_and_fidelity_are_distinct(self):
        plan = {"cases": [{"label": "example", "profile": {"p54_fidelity_rejections": ["VEN_UOPCACHE"]}}],
                "workloads": [WORKLOAD_10, {"label": "validation10", "seed": "validation"}]}
        result, _, _ = self.accepted_result()
        result.update(case="example", workload="performance10", score_eligible=True,
                      cm_per_mhz_total_program=2.2)
        one = summarize(plan, [result])["candidates"][0]
        self.assertFalse(one["both_standard_seeds_complete"])
        two = summarize(plan, [result, dict(result, workload="validation10")])["candidates"][0]
        self.assertTrue(two["both_standard_seeds_complete"])
        self.assertEqual(two["p54_fidelity_rejections"], ["VEN_UOPCACHE"])
        unscored = summarize(plan, [dict(result, score_eligible=False),
                                   dict(result, workload="validation10", score_eligible=False)])["candidates"][0]
        self.assertTrue(unscored["both_standard_seeds_complete"])
        self.assertIsNone(unscored["minimum_eligible_cm_per_mhz"])
        capped = summarize(plan, [result, dict(result, workload="validation10", timed_out=True,
                                               score_eligible=True, cm_per_mhz_total_program=0.01)])["candidates"][0]
        self.assertFalse(capped["both_standard_seeds_complete"])
        self.assertEqual(capped["minimum_eligible_cm_per_mhz"], 2.2)


if __name__ == "__main__":
    unittest.main()
