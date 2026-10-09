#!/usr/bin/env python3
"""Private, explicit qualification profile; does not modify canonical tb_main.

Unlike the fixed-point auditor this DOES allow elision, but only with the
original direct-user-mode guard and continuous inactive AXI/debug checks.
No architectural state is loaded or changed. Optional final dumps are for
byte-exact A/B comparison, never acceptance via resume.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
from prepare_settle_audit import replace_once


def prepare(text):
    text = replace_once(text, '#include "model_input_snapshot.h"', '''#include "model_input_snapshot.h"
#include "inactive_board_settle_guard.h"
#include "settle_fixed_point_audit.h"
#include "fault_delivery_counter.h"
#if !defined(VEN_L1_AXI) || !defined(VEN_DBG_CORE) || !defined(VEN_KV260_SOC)
#error "inactive-board qualification requires the complete board/debug harness"
#endif''')
    text = replace_once(text, '#if defined(VEN_L1_AXI) || defined(VEN_DBG_CORE) || defined(VEN_DOS_MODELS)',
                        '#if defined(VEN_DOS_MODELS)')
    # Keep every original runtime option rejection. Permit only two pinned,
    # observer-only env vars; no hook, IRQ, latency or public-state injection.
    text = replace_once(text, '    // Do this after parsing', '''    if (args.skip_unchanged_settle) {
        extern char** environ;
        if (!inactive_board_settle_environment(environ)) {
            std::fprintf(stderr, "tb: inactive-board elision rejects device/probe environment\\n");
            return 2;
        }
    }
    // Do this after parsing''')
    text = replace_once(text, '    auto same_clock_settle = [&]() {', '''    auto same_clock_settle = [&]() {
        if (args.skip_unchanged_settle) require_inactive_board_settle(*top);''')
    text = replace_once(text, '    ModelInputSnapshot input_snapshot;', '''    // The FPGA counter resets to zero; no startup-PC inference or forced state.
    FaultDeliveryCounter fault_deliveries(top->rootp->ventium_top__DOT__u_core__DOT__dbg_fault_cnt_q);
    ModelInputSnapshot input_snapshot;''')
    text = replace_once(text, '            static uint32_t prev_fpc = 0xFFFFFFFFu;',
                        '            // Actual exception-delivery event, including repeated identical PCs.')
    text = replace_once(text, '            if (fpc != prev_fpc) {', '''            if (fault_deliveries.observe(
                    top->rootp->ventium_top__DOT__u_core__DOT__dbg_fault_cnt_q)) {''')
    text = replace_once(text, '                prev_fpc = fpc;', '')
    text = replace_once(text, '    top->final();', '''    if (const char* prefix = std::getenv("TB_SETTLE_FINAL_STATE")) {
        SettleAuditStream image;
        image.capture(*top);
        const std::string model_path = std::string(prefix) + ".model";
        const std::string memory_path = std::string(prefix) + ".memory";
        FILE* model_file = std::fopen(model_path.c_str(), "wx");
        FILE* memory_file = std::fopen(memory_path.c_str(), "wx");
        if (!model_file || !memory_file) return 2;
        if (std::fwrite(image.bytes.data(), 1, image.bytes.size(), model_file) != image.bytes.size()) return 2;
        mem.snapshot(memory_file);
        const bool failed = std::ferror(model_file) || std::ferror(memory_file);
        const int model_close = std::fclose(model_file);
        const int memory_close = std::fclose(memory_file);
        if (failed || model_close || memory_close) return 2;
    }
    std::fprintf(stderr, "[fault-deliveries] actual=%llu\\n",
                 (unsigned long long)fault_deliveries.total());
    top->final();''')
    return text


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if not re.fullmatch(r'tb_inactive_settle_[a-z0-9_]+\.cpp', args.output.name):
        p.error('use a private model-specific tb_inactive_settle_<tag>.cpp basename')
    source = args.source.resolve(strict=True)
    text = source.read_text()
    generated = prepare(text)
    runtime = text[text.index('        if (args.system || args.cosim'):text.index('    // Do this after parsing')]
    assert runtime in generated
    with args.output.open('x') as out:
        out.write(generated)
    sha = lambda b: hashlib.sha256(b).hexdigest()
    with args.output.with_suffix('.json').open('x') as out:
        json.dump(dict(source=str(source), source_sha256=sha(source.read_bytes()),
                       output=str(args.output.resolve()), output_sha256=sha(args.output.read_bytes()),
                       runtime_guard_unchanged=True, continuous_inactive_board_check=True,
                       canonical_harness_modified=False), out, indent=2)


if __name__ == '__main__':
    main()
