#!/usr/bin/env python3
"""Summarize closed production ROM/cache leaf receipts; no model evaluation."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect_run(artifact, profiles, expect_red):
    artifact = artifact.resolve(strict=True)
    inputs = []
    unavailable_inputs = []
    for line in (artifact / "source.sha256").read_text().splitlines():
        expected_hash, name = line.split(maxsplit=1)
        path = Path(name)
        # The initial qualified receipt recorded the live runner path; retain
        # and check its exact frozen copy, not a subsequently edited runner.
        if path.name == "run-l1axi-ao486-romwrite-gate.sh" and not path.is_relative_to(artifact):
            path = artifact / "src/verif/l1/run-l1axi-ao486-romwrite-gate.sh"
            if not path.exists() and expect_red:
                # The historical clean RED predates runner-copy retention.
                # Preserve its recorded digest, but do not falsely verify it
                # against a newer live script or weaken other input checks.
                unavailable_inputs.append({"recorded_path": name,
                                           "recorded_sha256": expected_hash,
                                           "reason": "historical_runner_copy_not_retained"})
                continue
        actual = digest(path)
        if actual != expected_hash:
            raise ValueError(f"changed frozen input: {path}")
        inputs.append({"path": str(path), "sha256": actual})
    result = {"artifact": str(artifact), "expected_red": expect_red,
              "source_manifest_sha256": digest(artifact / "source.sha256"),
              "verified_frozen_inputs": inputs,
              "unavailable_historical_inputs": unavailable_inputs,
              "complete_source_provenance": not unavailable_inputs, "profiles": {}}
    for profile in profiles:
        log_path = artifact / f"{profile}.run.log"
        log = log_path.read_text()
        rows = re.findall(r"^ROMWRITE-RESULT (.*)$", log, re.M)
        if len(rows) != 1:
            raise ValueError(f"missing/duplicate result: {profile}")
        counts = dict((key, int(value)) for key, value in
                      (item.split("=", 1) for item in rows[0].split()))
        if counts["ram_errors"] != 0:
            raise ValueError(f"RAM control failed: {profile}")
        if not all(f"ROMWRITE-RAM-CONTROL uma={uma} errors=0" in log for uma in (0, 1)):
            raise ValueError(f"UMA RAM control missing: {profile}")
        if expect_red:
            if counts["rom_errors"] <= 0 or "ROMWRITE-CACHE-FAIL" not in log:
                raise ValueError(f"expected actual ROM mismatch absent: {profile}")
        elif counts["errors"] or counts["rom_errors"] or "ROMWRITE-CACHE-OK" not in log:
            raise ValueError(f"candidate not GREEN: {profile}")
        binary = artifact / profile / "test"
        manifest = artifact / profile / "Vtb_l1axi_ao486_romwrite__verFiles.dat"
        defs = artifact / profile / "defines.txt"
        defines = [x for x in defs.read_text().splitlines() if x]
        if ("+define+VEN_L1D_STORE_POLICY" in defines) == expect_red:
            raise ValueError(f"store-policy define disagrees with qualification: {profile}")
        result["profiles"][profile] = {
            "status": "EXPECTED_ROM_VALUE_FAILURE" if expect_red else "PASS",
            "counts": counts, "log_sha256": digest(log_path),
            "binary_sha256": digest(binary), "verilator_manifest_sha256": digest(manifest),
            "defines": defines,
            "compile_log_sha256": digest(artifact / f"{profile}.build.log"),
        }
        cached_log = artifact / f"{profile}.cached-default-smoke.log"
        if cached_log.exists():
            cached = cached_log.read_text()
            cached_rows = re.findall(r"^ROMWRITE-RESULT (.*)$", cached, re.M)
            if expect_red or cached_rows != rows or "ROMWRITE-CACHE-OK" not in cached:
                raise ValueError(f"cached-content recheck disagrees: {profile}")
            result["profiles"][profile]["cached_content_recheck"] = {
                "status": "PASS_IDENTICAL_COUNTS_NO_REBUILD",
                "log_sha256": digest(cached_log),
            }
        lint_log = artifact / "lint-finalflags" / f"{profile}.log"
        if lint_log.exists():
            lint = lint_log.read_text()
            if expect_red or re.search(r"^%Error", lint, re.M):
                raise ValueError(f"final-flags lint failed: {profile}")
            result["profiles"][profile]["final_flags_lint"] = {
                "status": "PASS_LINT_ONLY_NO_CPP_REBUILD",
                "log_sha256": digest(lint_log),
                "warning_classes": sorted(set(re.findall(r"^%Warning-(\w+):", lint, re.M))),
            }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--green", type=Path, required=True)
    parser.add_argument("--red", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = {"schema": "ventium-romwrite-contract-v1", "qualification": "FOCUSED_LEAF_ONLY",
              "full_suite_pass": False, "gameplay_ipc_measured": False,
              "readonly_analysis": True, "model_launched_by_summary": False,
              "green": inspect_run(args.green, ("packed", "banked", "banked_pair"), False)}
    runner = Path(__file__).with_name("run-l1axi-ao486-romwrite-gate.sh")
    runner_text = runner.read_text()
    if "STORE_POLICY:-1" not in runner_text or "STORE_POLICY:-0" in runner_text:
        raise ValueError("current runner must default to the GREEN feature-on gate")
    result["current_runner"] = {"path": str(runner.resolve()), "sha256": digest(runner),
                                "default_store_policy": 1, "default_expect_red": 0,
                                "only_general_warning_suppression": "UNUSED",
                                "frozen_executed_runner_is_recorded_separately": True}
    if args.red:
        # The preserved initial clean RED predates the paired/extra controls.
        result["red"] = inspect_run(args.red, ("packed", "banked"), True)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    args.out.write_text(text)
    print(f"ROMWRITE-RECEIPT-OK {args.out}")


if __name__ == "__main__":
    main()
