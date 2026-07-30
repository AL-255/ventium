#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Interactive, offscreen acceptance checks for Pipeviz.

Unlike verify_examples.py, this drives real Qt controls with QTest and verifies
the linked-view behavior a user relies on.  Screenshots are written only to the
requested output directory (normally /tmp).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

from PySide6.QtCore import QEvent, QPoint, Qt, QTimer
from PySide6.QtGui import QFontMetrics
from PySide6.QtTest import QTest
from PySide6.QtWidgets import (QApplication, QFileDialog, QMessageBox, QPushButton,
                               QToolBar, QToolButton)

import pipeviz.main as main_module
import pipeviz.disasm as disasm_module
import pipeviz.pipeline_view as pipeline_module
import pipeviz.trace_view as trace_module
from pipeviz.backend import Backend, VVCline, VVCycle, VVRetire, VVState
from pipeviz.disasm import C_HALT, C_SYS, STATE_STAGE, stage_of
from pipeviz.main import (DEF_ENTRY, DEF_ESP, MainWindow, _PROGRAM_FILTER, _apply_dark,
                          _load_startup_target, _manifest_address, _read_program,
                          _manifest_bool,
                          _session_progress, _step_notice, _system_load_address,
                          _validate_segments)
from pipeviz.pipeline_view import ROW_H
from pipeviz.regs_view import RegsView
from pipeviz.tables_view import (CycleBreakdown, TablesView, _dcache_per_pc,
                                 _dcache_replay, _mono)


def repo_path(relative):
    path = os.path.join(ROOT, relative)
    if not os.path.isfile(path):
        raise AssertionError(f"required fixture is missing: {path}")
    return path


def default_rtl_state_names():
    """Parse state_e as build.sh's default configuration (no optional defines)."""
    core = open(
        os.path.join(ROOT, "rtl/core/core.sv"),
        encoding="utf-8").read()
    match = re.search(
        r"typedef\s+enum\s+logic\s*\[5:0\]\s*\{(.*?)\}\s*state_e\s*;",
        core, re.DOTALL)
    assert match, "state_e enum was not found"
    active = True
    stack = []
    kept = []
    for line in match.group(1).splitlines():
        directive = line.strip()
        if directive.startswith("`ifdef"):
            stack.append((active, False))
            active = False
        elif directive.startswith("`ifndef"):
            stack.append((active, True))
            active = active
        elif directive.startswith("`else"):
            parent, condition = stack[-1]
            condition = not condition
            stack[-1] = (parent, condition)
            active = parent and condition
        elif directive.startswith("`endif"):
            active, _condition = stack.pop()
        elif active:
            kept.append(line)
    assert not stack
    body = re.sub(r"/\*.*?\*/", "", "\n".join(kept), flags=re.DOTALL)
    body = re.sub(r"//.*", "", body)
    return re.findall(r"\bS_[A-Z0-9_]+\b", body)


def verify_fpd_bridge_layout():
    """Lock C++ packed-field offsets to the current RTL fpd_t declaration."""
    package_path = os.path.join(
        ROOT, "rtl/core/ventium_decode_pkg.sv")
    package = open(package_path, encoding="utf-8").read()
    match = re.search(
        r"typedef\s+struct\s+packed\s*\{(.*?)\}\s*fpd_t\s*;",
        package, re.DOTALL)
    assert match, "fpd_t packed struct was not found"
    fields = re.findall(
        r"\blogic\s*(?:\[(\d+)\s*:\s*(\d+)\])?\s+"
        r"([A-Za-z_]\w*)\s*;",
        re.sub(r"//.*", "", match.group(1)))
    assert fields
    offsets = {}
    bit = 0
    for high, low, name in reversed(fields):
        width = int(high) - int(low) + 1 if high else 1
        offsets[name] = bit
        bit += width

    bridge = open(
        os.path.join(HERE, "ventium_viz.cpp"), encoding="utf-8").read()
    enum_match = re.search(
        r"// ---- fpd_t packed-struct bit offsets.*?"
        r"enum\s*\{(.*?)\};",
        bridge, re.DOTALL)
    assert enum_match, "Pipeviz fpd_t bridge offset enum was not found"
    constants = {
        name: int(value)
        for name, value in re.findall(
            r"\b(FPD_[A-Z_]+)\s*=\s*(\d+)", enum_match.group(1))
    }
    contract = {
        "FPD_FP_OCC_LSB": "fp_occ",
        "FPD_IS_FP_LSB": "is_fp",
        "FPD_FP_KIND_LSB": "fp_kind",
        "FPD_PAIRS_SEC_LSB": "pairs_second",
        "FPD_PAIRS_FIRST_LSB": "pairs_first",
        "FPD_IS_BRANCH_LSB": "is_branch",
        "FPD_IS_LOAD_LSB": "is_load",
        "FPD_ALU_OP_LSB": "alu_op",
        "FPD_LEN_LSB": "len",
        "FPD_SIMPLE_LSB": "simple",
    }
    assert bit == 161, f"review the fpd_t ABI width: now {bit} bits"
    assert set(constants) == set(contract)
    for constant, field in contract.items():
        assert constants[constant] == offsets[field], (
            f"{constant}={constants[constant]}, but RTL {field} starts at "
            f"bit {offsets[field]}")
    return bit


def settle(app, rounds=4):
    for _ in range(rounds):
        app.processEvents()


def click(app, widget, modifiers=Qt.NoModifier, pos=None):
    assert widget.isEnabled(), f"cannot click disabled {widget!r}"
    QTest.mouseClick(widget, Qt.LeftButton, modifiers, pos or widget.rect().center())
    settle(app)


def select_tab(app, tabs, index):
    rect = tabs.tabBar().tabRect(index)
    click(app, tabs.tabBar(), pos=rect.center())
    assert tabs.currentIndex() == index


def select_table_row(app, table, row):
    item = table.item(row, 0)
    assert item is not None
    table.scrollToItem(item)
    settle(app)
    rect = table.visualItemRect(item)
    click(app, table.viewport(), pos=rect.center())
    assert table.currentRow() == row


def set_filter(app, trace, text):
    trace.filt.setFocus()
    QTest.keyClick(trace.filt, Qt.Key_A, Qt.ControlModifier)
    QTest.keyClick(trace.filt, Qt.Key_Backspace)
    if text:
        QTest.keyClicks(trace.filt, text)
    settle(app)
    assert trace.filt.text() == text
    return sum(not trace.tbl.isRowHidden(row) for row in range(trace.tbl.rowCount()))


def save_shot(app, win, outdir, name, min_width=1280, min_height=800):
    settle(app)
    win.repaint()
    settle(app)
    path = os.path.join(outdir, f"{name}.png")
    pix = win.grab()
    assert pix.width() >= min_width and pix.height() >= min_height
    assert pix.save(path), f"failed to write {path}"
    return path


def new_window(app):
    win = MainWindow()
    win.resize(1640, 980)
    win.show()
    settle(app)
    return win


def close_window(win):
    win.stop_run()
    win.backend.close()
    win.close()


def scenario_startup(app, outdir):
    assert _session_progress(212, 120, 1) == (212, 120, 212 / 120)
    assert _session_progress(
        1_000_001, 5001, 5001, 1_000_000, snapshot=True) == (1, 1, 1.0)
    assert _step_notice(1) == "Advanced 1 clock"
    assert _step_notice(1384, done=True) == (
        "Advanced 1384 clocks · program stopped")
    assert _step_notice(7, True, 10, 11) == (
        "Advanced 7 clocks · reached next retirement")
    assert _step_notice(4, True, 10, 10, done=True) == (
        "Advanced 4 clocks · program stopped before another retirement")
    assert _step_notice(200000, True, 10, 10, done=False) == (
        "Advanced 200000 clocks · no retirement before the safety limit")
    assert _manifest_bool(True, "system") is True
    try:
        _manifest_bool(1, "system")
    except TypeError:
        pass
    else:
        raise AssertionError("numeric manifest mode was accepted as a boolean")

    # The current bridge snapshots x87 on every retirement, but the view also
    # accepts partial/legacy records. Prove an unavailable snapshot cannot leak
    # stale live values under a different pinned time point.
    probe_regs = RegsView()
    probe_regs.start_session()
    missing_fp = VVRetire()
    missing_fp.n = 91
    missing_fp.cyc = 23
    assert not missing_fp.x87_valid
    probe_regs.show_retire(missing_fp, None)
    assert probe_regs.fphdr.text().startswith("x87 n/a")
    assert all(hexv.text() == "n/a"
               for _tag, hexv, _value in probe_regs.st_lbls)
    live_regs = VVState()
    live_regs.ftop = 3
    live_regs.fptag = 0xff
    probe_regs.update_from(live_regs)
    assert probe_regs.fphdr.text().startswith("TOP=3")
    assert all(hexv.text() != "n/a"
               for _tag, hexv, _value in probe_regs.st_lbls)
    probe_regs.close()
    probe_regs.deleteLater()

    # Backend readiness includes the model inputs, not only the C++ bridge:
    # changed RTL must not leave the GUI confidently visualizing an old ignored
    # shared object. Exercise --check in a disposable fake repository.
    launcher_root = os.path.join(outdir, "launcher_probe")
    launcher_dir = os.path.join(launcher_root, "tools", "pipeviz")
    rtl_dir = os.path.join(launcher_root, "rtl", "core")
    os.makedirs(launcher_dir, exist_ok=True)
    os.makedirs(rtl_dir, exist_ok=True)
    launcher_copy = os.path.join(launcher_dir, "run.sh")
    shutil.copy2(repo_path("tools/pipeviz/run.sh"), launcher_copy)
    fake_backend = os.path.join(launcher_dir, "libventium_viz.so")
    fake_rtl = os.path.join(rtl_dir, "core.sv")
    with open(fake_backend, "wb") as backend_file:
        backend_file.write(b"probe")
    with open(fake_rtl, "w", encoding="utf-8") as rtl_file:
        rtl_file.write("module core; endmodule\n")
    os.utime(fake_rtl, (1_000_000, 1_000_000))
    os.utime(fake_backend, (2_000_000, 2_000_000))
    launcher_env = dict(os.environ, PIPEVIZ_PYTHON=sys.executable)
    ready = subprocess.run(
        ["bash", launcher_copy, "--check"], cwd=launcher_root,
        env=launcher_env, text=True, capture_output=True, check=False)
    assert ready.returncode == 0 and "backend ready" in ready.stdout

    fake_soc_filelist = os.path.join(launcher_root, "rtl", "ventium_soc.f")
    fake_soc_backend = os.path.join(
        launcher_dir, "libventium_viz_soc.so")
    with open(fake_soc_filelist, "w", encoding="utf-8") as soc_file:
        soc_file.write("ventium_soc.sv\n")
    with open(fake_soc_backend, "wb") as soc_backend:
        soc_backend.write(b"soc-probe")
    os.utime(fake_soc_filelist, (1_000_000, 1_000_000))
    os.utime(fake_soc_backend, (2_000_000, 2_000_000))
    soc_ready = subprocess.run(
        ["bash", launcher_copy, "--check", "--soc"], cwd=launcher_root,
        env=launcher_env, text=True, capture_output=True, check=False)
    assert soc_ready.returncode == 0
    assert "SoC backend ready" in soc_ready.stdout
    os.remove(fake_soc_backend)
    soc_missing = subprocess.run(
        ["bash", launcher_copy, "--check", "--soc"], cwd=launcher_root,
        env=launcher_env, text=True, capture_output=True, check=False)
    assert soc_missing.returncode == 2
    assert "SoC backend is missing" in soc_missing.stderr
    assert "--build --soc" in soc_missing.stderr

    # `run.sh --build --soc` used to drop --soc when invoking build.sh while
    # still forwarding it to the GUI. Use inert fake build/Python commands to
    # prove both destinations receive the flag without compiling or opening Qt.
    fake_build = os.path.join(launcher_dir, "build.sh")
    with open(fake_build, "w", encoding="utf-8") as build_file:
        build_file.write(
            "#!/usr/bin/env bash\n"
            "HERE=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n"
            "printf '%s\\n' \"$@\" > \"$HERE/build.args\"\n"
            ": > \"$HERE/libventium_viz.so\"\n"
            ": > \"$HERE/libventium_viz_soc.so\"\n")
    os.chmod(fake_build, 0o755)
    fake_python = os.path.join(launcher_dir, "fake-python")
    with open(fake_python, "w", encoding="utf-8") as python_file:
        python_file.write(
            "#!/usr/bin/env bash\n"
            "if [ \"${1:-}\" = '-c' ]; then exit 0; fi\n"
            "HERE=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n"
            "printf '%s\\n' \"$@\" > \"$HERE/python.args\"\n")
    os.chmod(fake_python, 0o755)
    build_env = dict(os.environ, PIPEVIZ_PYTHON=fake_python)
    built_soc = subprocess.run(
        ["bash", launcher_copy, "--build", "--soc", "probe.bin"],
        cwd=launcher_root, env=build_env, text=True,
        capture_output=True, check=False)
    assert built_soc.returncode == 0
    with open(os.path.join(launcher_dir, "build.args"),
              encoding="utf-8") as build_args_file:
        assert build_args_file.read().splitlines() == ["--soc"]
    with open(os.path.join(launcher_dir, "python.args"),
              encoding="utf-8") as python_args_file:
        python_args = python_args_file.read().splitlines()
    assert python_args == ["-m", "pipeviz.main", "--soc", "probe.bin"]

    os.utime(fake_build, (1_000_000, 1_000_000))
    os.utime(fake_backend, (2_000_000, 2_000_000))
    os.utime(fake_rtl, (3_000_000, 3_000_000))
    stale = subprocess.run(
        ["bash", launcher_copy, "--check"], cwd=launcher_root,
        env=launcher_env, text=True, capture_output=True, check=False)
    assert stale.returncode == 2
    assert "backend stale" in stale.stderr and "core.sv changed" in stale.stderr
    assert "--build" in stale.stderr

    # Help needs Python imports but no model. Even an explicit --build must not
    # invoke build.sh or require an existing backend merely to print argparse.
    os.remove(fake_backend)
    build_args_path = os.path.join(launcher_dir, "build.args")
    python_args_path = os.path.join(launcher_dir, "python.args")
    for transient in (build_args_path, python_args_path):
        if os.path.exists(transient):
            os.remove(transient)
    help_only = subprocess.run(
        ["bash", launcher_copy, "--build", "--help"],
        cwd=launcher_root, env=build_env, text=True,
        capture_output=True, check=False)
    assert help_only.returncode == 0
    assert not os.path.exists(build_args_path)
    with open(python_args_path, encoding="utf-8") as python_args_file:
        assert python_args_file.read().splitlines() == [
            "-m", "pipeviz.main", "--help"]

    probe_cycle = type("ProbeCycle", (), {
        "mispred_bubbles": 0, "retU": 0, "retV": 0,
    })()
    assert CycleBreakdown._classify("S_FETCH", probe_cycle) == "front end"
    assert CycleBreakdown._classify("S_EXEC", probe_cycle) == "slow path"

    # Memory displays physical BFM bytes. Lock legacy page translation, segment
    # selection, and address-size overrides before exercising the real model.
    class PageMemory:
        translate_linear = Backend.translate_linear
        mem_read_linear = Backend.mem_read_linear

        def __init__(self):
            self.bytes = {}

        def put_u32(self, address, value):
            for offset in range(4):
                self.bytes[address + offset] = (value >> (8 * offset)) & 0xFF

        def mem_read(self, address, count):
            return bytes(self.bytes.get(address + offset, 0)
                         for offset in range(count))

    pager = PageMemory()
    pager.put_u32(0x1004, 0x2003)  # PDE[1] -> page table
    pager.put_u32(0x2004, 0x9003)  # PTE[1] -> frame 0x9000
    assert pager.translate_linear(0x00401234, 0, 0, 0) == 0x00401234
    assert pager.translate_linear(
        0x00401234, 1 << 31, 0x1000, 0) == 0x00009234
    pager.bytes[0x9234] = 0x90
    assert pager.mem_read_linear(
        0x00401234, 1, 1 << 31, 0x1000, 0) == b"\x90"
    pager.put_u32(0x1008, 0x01400083)  # PDE[2], present + 4 MiB page
    assert pager.translate_linear(
        0x00805678, 1 << 31, 0x1000, 1 << 4) == 0x01405678
    assert pager.translate_linear(
        0x00C00000, 1 << 31, 0x1000, 0) is None
    assert pager.translate_linear(
        0x00401234, 1 << 31, 0x1000, 1 << 5) is None

    class PagedLiveBackend(PageMemory):
        @staticmethod
        def state_name(_state):
            return "S_FETCH"

    live_backend = PagedLiveBackend()
    live_backend.bytes.update(pager.bytes)
    live = VVState()
    live.eip = 0x00401234
    live.cs_d = 1
    live.cr0 = 1 << 31
    live.cr3 = 0x1000
    live_board = pipeline_module.StageBoard()
    assert live_board.focusPolicy() == Qt.NoFocus
    live_board.set_state(live, live_backend, 32)
    assert live_board._cells["U"][1] == "nop"
    assert live_board.focusPolicy() == Qt.StrongFocus
    live_board.reset()
    assert live_board.focusPolicy() == Qt.NoFocus
    live_board.deleteLater()

    # Retired timing rows must decode the immutable bytes captured with that
    # retirement. A current-memory re-read can see a self-modified opcode or
    # use the wrong post-transition segment/page mapping.
    retire = VVRetire()
    retire.n = 7
    retire.cyc = 1
    retire.pc = 0x00401234
    retire.d32 = 1
    retire.nbytes = 1
    retire.bytes[0] = 0x40                       # inc eax
    cycle = VVCycle()
    cycle.cyc = 1
    cycle.retU = 1
    cycle.nU = retire.n
    cycle.pcU = retire.pc

    class RetiredBytesBackend:
        @staticmethod
        def state_name(_state):
            return "S_PIPE"

        @staticmethod
        def get_cycles(_since, _maximum):
            return [cycle]

        @staticmethod
        def get_retires(_since, _maximum):
            return [retire]

        @staticmethod
        def mem_read(_address, _count):
            raise AssertionError(
                "timing decode re-read mutable/current program memory")

    retired_backend = RetiredBytesBackend()
    retired_plot = pipeline_module._KonataPlot()
    retired_plot.reset(retired_backend, 32)
    assert retired_plot.ingest(retired_backend, 1) == 1
    assert retired_plot.insns[0]["mnem"] == "inc eax"
    assert retired_plot.insns[0]["reads"] == [0]
    assert retired_plot.insns[0]["writes"] == [0]
    assert retired_plot.insns[0]["rfl"] is False
    assert retired_plot.insns[0]["wfl"] is True
    retired_plot.deleteLater()

    bp16 = disasm_module.mem_operand(b"\x8b\x46\x10", bits=16)
    assert bp16[6:] == (1, 0xFFFF)  # BP defaults to SS, 16-bit address
    eax_override = disasm_module.mem_operand(b"\x67\x8b\x00", bits=16)
    assert eax_override[6:] == (2, 0xFFFFFFFF)  # 0x67 -> 32-bit DS:EAX
    fs_absolute = disasm_module.mem_operand(
        b"\x64\xa1\x00\x10\x00\x00", bits=32)
    assert fs_absolute[6:] == (4, 0xFFFFFFFF)

    prior = VVRetire()
    prior.n, prior.cyc, prior.pc = 0, 1, 0x08048000
    prior.d32, prior.nbytes, prior.bytes[0] = 1, 1, 0x90
    prior.gpr[6] = 0x20
    prior.seg_base[2] = 0x1000
    access_record = VVRetire()
    access_record.n, access_record.cyc, access_record.pc = 1, 2, 0x08048001
    access_record.d32, access_record.nbytes = 1, 2
    access_record.bytes[0], access_record.bytes[1] = 0x8B, 0x06  # mov eax,[esi]
    access_record.gpr[6] = 0x20
    access_record.seg_base[2] = 0x1000

    class SegmentedRetireBackend:
        records = [prior, access_record]

        @staticmethod
        def retire_count():
            return 2

        @classmethod
        def get_retires(cls, since_n, maximum):
            return [
                record for record in cls.records
                if int(record.n) >= since_n][:maximum]

        @staticmethod
        def translate_linear(linear, _cr0, _cr3, _cr4):
            return int(linear)

    segmented_trace = trace_module.TraceView()
    segmented_trace.update_from(SegmentedRetireBackend())
    assert len(segmented_trace.accesses) == 1
    segmented_access = segmented_trace.accesses[0]
    assert segmented_access[2] == 0x20       # D$ effective offset
    assert segmented_access[6] == 0x1020     # DS base + offset
    assert segmented_access[7] == 0x1020     # paging-off physical
    assert segmented_trace.last_access == (0x1020, 4)
    segmented_trace.deleteLater()

    # Snapshot sessions must begin D-cache replay from resident tags and the
    # exact MRU order, not fabricate a cold cache. A new conflicting tag evicts
    # the seeded LRU while the seeded MRU remains a hit.
    seed = [
        (0, 1, 0x20, 0),  # deliberately listed before the MRU way
        (0, 0, 0x10, 0),
    ]
    seeded_accesses = [
        (0, 1, 0x30 << 12, 0, 4, 0x08048000),
        (1, 2, 0x10 << 12, 0, 4, 0x08048004),
    ]
    assert _dcache_replay(seeded_accesses, seed) == (2, 1, 1, 0, 1)
    seeded_pc = _dcache_per_pc(seeded_accesses, seed)
    assert seeded_pc[0x08048000] == [1, 1]
    assert seeded_pc[0x08048004] == [1, 0]
    resident_access = [(0, 1, 0x10 << 12, 0, 4, 0x08048008)]
    assert _dcache_replay(resident_access, seed) == (1, 1, 0, 0, 0)

    seed_lines = []
    for s, way, tag, mru_way in seed:
        line = VVCline()
        line.set, line.way, line.tag, line.lru = s, way, tag, mru_way
        seed_lines.append(line)

    class SnapshotCacheBackend:
        @staticmethod
        def cycle_count():
            return 5000

        @staticmethod
        def dcache():
            return seed_lines

    seeded_tables = TablesView()
    seeded_tables.start_session(SnapshotCacheBackend())
    assert seeded_tables._dcache_seed == seed
    seeded_tables.dc_lbl.setText("snapshot residency")
    seeded_tables.set_dcache_replay(resident_access)
    assert "0% miss" in seeded_tables.dc_lbl.text()
    assert "replay [seed 2]" in seeded_tables.dc_lbl.text()
    assert "2 resident session-start lines" in seeded_tables.dc_lbl.toolTip()
    seeded_tables.set_hotspots([{
        "pc": 0x08048008, "c0": 1, "c1": 1, "mnem": "mov eax, [esi]",
    }], resident_access, captured_span=1)
    assert seeded_tables.hot.item(0, 4).text() == "0/1"
    seeded_tables.deleteLater()

    # Synthetic fast-path shadows must stay inside the capture and must never
    # duplicate a real front-end phase that occurs after an initial stall.
    synthetic = pipeline_module._add_frontend(
        [(12, "X", "#fff")], history_start=11)
    assert [cell[:2] for cell in synthetic] == [(11, "D"), (12, "X")]
    real_frontend = [(10, "=", "#aaa"), (11, "L", "#bbb"), (12, "X", "#fff")]
    assert pipeline_module._add_frontend(real_frontend, 1) == real_frontend

    class CycleSample:
        def __init__(self, cyc):
            self.cyc = cyc
            self.state = 2
            self.retU = 0
            self.retV = 0
            self.mispred_bubbles = 0
            self.stall_cnt = 0
            self.pending_mem_pen = 0

    class CycleBackend:
        def __init__(self, count):
            self.records = [CycleSample(cyc) for cyc in range(1, count + 1)]
            self.current = 0

        def cycle_count(self):
            return self.current

        def get_cycles(self, since_cyc, maximum):
            end = min(self.current, since_cyc - 1 + maximum)
            return self.records[since_cyc - 1:end]

        @staticmethod
        def state_name(_state):
            return "S_DECODE"

    cycle_backend = CycleBackend(9000)  # deliberately exceeds one 8192-sample read
    original_cycle_cap = pipeline_module._KONATA_CYCLE_CAP
    pipeline_module._KONATA_CYCLE_CAP = 100
    try:
        overflow_konata = pipeline_module.Konata()
        overflow_konata.reset(cycle_backend, 32)
        cycle_backend.current = len(cycle_backend.records)
        overflow_konata.update_from(cycle_backend)
        assert overflow_konata._last_cyc == 9000
        assert overflow_konata.plot.history_start == 8901
        assert "latest 100 of 9,000 cycles" in overflow_konata.title.text()
    finally:
        pipeline_module._KONATA_CYCLE_CAP = original_cycle_cap
        overflow_konata.deleteLater()
    overflow_spark = pipeline_module.SparklineStrip()
    assert overflow_spark.focusPolicy() == Qt.NoFocus
    overflow_spark.CAP = 100
    cycle_backend.current = 0
    overflow_spark.reset(cycle_backend)
    cycle_backend.current = len(cycle_backend.records)
    overflow_spark.ingest()
    assert overflow_spark._last_cyc == 9000
    assert len(overflow_spark.ret) == len(overflow_spark.ev) == 100
    assert overflow_spark.focusPolicy() == Qt.StrongFocus
    overflow_cycles = CycleBreakdown()
    cycle_backend.current = 0
    overflow_cycles.reset(cycle_backend)
    cycle_backend.current = len(cycle_backend.records)
    overflow_cycles.ingest(cycle_backend)
    assert overflow_cycles._last_cyc == 9000
    assert sum(overflow_cycles.counts.values()) == 9000
    overflow_spark.deleteLater()
    overflow_cycles.deleteLater()

    class SnapshotClock:
        @staticmethod
        def cycle_count():
            return 5000

    snapshot_clock = SnapshotClock()
    snapshot_konata = pipeline_module.Konata()
    snapshot_konata.reset(snapshot_clock, 32)
    assert snapshot_konata.plot.history_start == 5001
    assert snapshot_konata._last_cyc == 5000
    assert not snapshot_konata._history_truncated
    snapshot_spark = pipeline_module.SparklineStrip()
    snapshot_spark.reset(snapshot_clock)
    assert snapshot_spark._last_cyc == 5000 and not snapshot_spark.ret
    assert snapshot_spark.focusPolicy() == Qt.NoFocus
    snapshot_cycles = CycleBreakdown()
    snapshot_cycles.reset(snapshot_clock)
    assert snapshot_cycles._last_cyc == 5000
    assert sum(snapshot_cycles.counts.values()) == 0
    snapshot_konata.deleteLater()
    snapshot_spark.deleteLater()
    snapshot_cycles.deleteLater()

    class RetireBackend:
        def __init__(self, count):
            self.records = []
            for n in range(count):
                record = VVRetire()
                record.n = n
                record.cyc = n + 1
                record.pc = 0x08048000 + n
                record.d32 = 1
                record.nbytes = 1
                record.bytes[0] = 0x90
                record.gpr[0] = n
                record.eflags = 2
                self.records.append(record)

        def retire_count(self):
            return len(self.records)

        def get_retires(self, since_n, maximum):
            return self.records[since_n:since_n + maximum]

    original_trace_cap = trace_module._MAX_ROWS
    trace_module._MAX_ROWS = 10
    try:
        overflow_trace = trace_module.TraceView()
        overflow_trace.update_from(RetireBackend(15))
        assert overflow_trace.tbl.rowCount() == 10
        assert overflow_trace.tbl.item(0, 0).text() == "5"
        assert overflow_trace.tbl.item(9, 0).text() == "14"
        assert overflow_trace._seen == 15
        assert "latest 10 of 15" in overflow_trace.title.text()
        assert overflow_trace._prev_gpr[0] == 14
    finally:
        trace_module._MAX_ROWS = original_trace_cap
        overflow_trace.deleteLater()

    offset_record = VVRetire()
    offset_record.n = 1_000_000
    offset_record.cyc = 5001
    offset_record.pc = 0x08048000
    offset_record.d32 = 1
    offset_record.nbytes = 1
    offset_record.bytes[0] = 0x90
    offset_record.eflags = 2

    class OffsetRetireBackend:
        def __init__(self):
            self.calls = []

        @staticmethod
        def retire_count():
            return 1_000_001

        def get_retires(self, since_n, maximum):
            self.calls.append((since_n, maximum))
            return [offset_record] if since_n <= offset_record.n else []

    offset_backend = OffsetRetireBackend()
    offset_trace = trace_module.TraceView()
    offset_trace.update_from(offset_backend)
    assert offset_trace.tbl.rowCount() == 1
    assert offset_trace.tbl.item(0, 0).text() == "1000000"
    assert offset_trace.title.text() == "Retired-instruction trace"
    assert offset_trace._session_first_n == 1_000_000
    assert all(since in (0, 1_000_000) for since, _maximum in offset_backend.calls)
    offset_trace.deleteLater()

    assert _system_load_address(0x10000) == 0x000F0000
    for invalid_size in (0, 0x100001):
        try:
            _system_load_address(invalid_size)
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid system-image size accepted: {invalid_size}")
    _validate_segments([(0xFFFFFFF0, b"\0" * 16)])
    try:
        _validate_segments([(0xFFFFFFF0, b"\0" * 17)])
    except ValueError:
        pass
    else:
        raise AssertionError("32-bit-crossing segment accepted")
    assert "*.rom" in _PROGRAM_FILTER and "*.exe" not in _PROGRAM_FILTER
    assert _manifest_address(0x08048000, "entry") == 0x08048000
    assert _manifest_address("0x08048000", "entry") == 0x08048000
    for invalid in (True, -1, 0x1_0000_0000, None):
        try:
            _manifest_address(invalid, "entry")
        except (TypeError, ValueError):
            pass
        else:
            raise AssertionError(f"invalid manifest address accepted: {invalid!r}")
    invalid_dir = os.path.join(outdir, "invalid_programs")
    os.makedirs(invalid_dir, exist_ok=True)
    empty_program = os.path.join(invalid_dir, "empty.flat")
    mz_program = os.path.join(invalid_dir, "unsupported.exe")
    with open(empty_program, "wb"):
        pass
    with open(mz_program, "wb") as program_file:
        program_file.write(b"MZ" + b"\0" * 62)
    for path, message in ((empty_program, "empty"),
                          (mz_program, "DOS/PE")):
        try:
            _read_program(path)
        except ValueError as error:
            assert message in str(error)
        else:
            raise AssertionError(f"unsupported program accepted: {path}")

    class StartupRecorder:
        def __init__(self):
            self.images = []
            self.snapshots = []

        def load_image(self, path):
            self.images.append(path)

        def load_snapshot(self, path):
            self.snapshots.append(path)

    recorder = StartupRecorder()
    assert _load_startup_target(
        recorder, image="/missing/explicit-program.elf") == "image"
    assert recorder.images == ["/missing/explicit-program.elf"]
    assert recorder.snapshots == []
    recorder = StartupRecorder()
    assert _load_startup_target(
        recorder, snapshot="/tmp/checkpoint") == "snapshot"
    assert recorder.snapshots == ["/tmp/checkpoint"] and not recorder.images
    recorder = StartupRecorder()
    assert _load_startup_target(recorder) == "demo"
    assert len(recorder.images) == 1 and not recorder.snapshots
    conflict = subprocess.run(
        [sys.executable, "-m", "pipeviz.main", "program.flat",
         "--snapshot", "checkpoint"],
        cwd=HERE, text=True, capture_output=True)
    assert conflict.returncode == 2
    assert "mutually exclusive" in conflict.stderr
    conflict = subprocess.run(
        [sys.executable, "-m", "pipeviz.main", "--snapshot", "checkpoint",
         "--system"],
        cwd=HERE, text=True, capture_output=True)
    assert conflict.returncode == 2
    assert "cannot be combined" in conflict.stderr
    launcher_env = os.environ.copy()
    launcher_env["PIPEVIZ_PYTHON"] = sys.executable
    launcher = subprocess.run(
        ["bash", os.path.join(HERE, "run.sh"), "--help"],
        cwd=HERE, env=launcher_env, text=True, capture_output=True)
    assert launcher.returncode == 0
    assert "Ventium pipeline visualizer" in launcher.stdout
    launcher_env["PIPEVIZ_PYTHON"] = "/missing/pipeviz-python"
    launcher = subprocess.run(
        ["bash", os.path.join(HERE, "run.sh"), "--build", "--help"],
        cwd=HERE, env=launcher_env, text=True, capture_output=True)
    assert launcher.returncode == 1
    assert "set PIPEVIZ_PYTHON=/path/to/python" in launcher.stderr
    assert "[run] building backend" not in launcher.stdout

    win = new_window(app)
    try:
        # Every ambiguous focus stop must announce its purpose without relying
        # on an adjacent visual label. The plot owns pipeline keyboard input;
        # its QScrollArea wrapper must not add an unlabeled inert stop first.
        accessible_controls = {
            win.entry_e: "Program entry address",
            win.load_e: "Flat-image load address",
            win.esp_e: "Initial stack pointer",
            win.stepn: "Step clock count",
            win.speed: "Run clocks per timer tick",
            win.event_kind: "Pipeline event type",
            win.evprev_btn: "Previous pipeline event",
            win.evnext_btn: "Next pipeline event",
            win.workspace.tabBar(): "Workspace tabs",
            win.pipeline.konata.plot: "Pipeline timing diagram",
            win.pipeline.konata.zoom_out_btn: "Zoom pipeline cycles out",
            win.pipeline.konata.zoom_reset_btn: "Reset pipeline cycle zoom",
            win.pipeline.konata.zoom_in_btn: "Zoom pipeline cycles in",
            win.trace.filt: "Retired instruction filter",
            win.trace.tbl: "Retired instruction trace",
            win.tables.tabs.tabBar(): "Analysis view tabs",
            win.tables.analysis_selector: "Analysis view selector",
            win.tables.ic: "Instruction cache lines",
            win.tables.ic_map: "Instruction cache occupancy map",
            win.tables.dc: "Data cache lines",
            win.tables.dc_map: "Data cache occupancy map",
            win.tables.tlb: "Translation lookaside buffer entries",
            win.tables.hot: "Instruction hotspots",
            win.tables.br: "Branch behavior",
            win.tables.mix: "Instruction mix",
            win.tables.cyc: "Cycle attribution",
            win.tables.mem.addr_e: "Physical memory address",
            win.tables.mem.follow_lbl: "Physical memory navigation state",
            win.tables.mem.dump: "Physical memory hex and ASCII dump",
            win.regs._compact_tabs.tabBar(): "Register group tabs",
            win.assembly.editor: "Assembly source editor",
            win.c_source.editor: "C source editor",
        }
        for control, expected_name in accessible_controls.items():
            assert control.accessibleName() == expected_name, (
                type(control).__name__, control.accessibleName(), expected_name)
        semantic_tables = (
            win.tables.ic, win.tables.dc, win.tables.tlb, win.tables.hot,
            win.tables.br, win.tables.mix, win.trace.tbl)
        for table in semantic_tables:
            for column in range(table.columnCount()):
                item = table.horizontalHeaderItem(column)
                assert item is not None and item.toolTip(), (
                    table.accessibleName(), column,
                    item.text() if item is not None else None)
        assert "user / writable / present" in (
            win.tables.tlb.horizontalHeaderItem(5).toolTip())
        assert "previous retirement" in (
            win.trace.tbl.horizontalHeaderItem(2).toolTip())
        assert "normalized" in (
            win.tables.mix.horizontalHeaderItem(3).toolTip())
        assert "all 128 sets" in win.tables.ic_map.accessibleDescription()
        assert "No program loaded" in (
            win.tables.cyc.accessibleDescription())
        assert win.pipeline.konata.scroll.focusPolicy() == Qt.NoFocus
        assert win.stepn.toolTip() and win.speed.toolTip()

        old_backend = win.backend
        old_backend_class = main_module.Backend
        old_critical = QMessageBox.critical
        old_warning = QMessageBox.warning
        reset_errors = []

        def fail_backend(*_args, **_kwargs):
            raise RuntimeError("synthetic construction failure")

        try:
            main_module.Backend = fail_backend
            QMessageBox.critical = (
                lambda _parent, title, text:
                reset_errors.append((title, text)))
            assert not win._fresh_backend(False)
        finally:
            main_module.Backend = old_backend_class
            QMessageBox.critical = old_critical
        assert win.backend is old_backend and old_backend.h
        assert reset_errors == [
            ("Backend reset failed", "synthetic construction failure")]

        class FailSocFallback:
            @staticmethod
            def supports_snapshot(_libpath, soc=False):
                return not soc

            def __init__(self, *_args, **_kwargs):
                raise RuntimeError("synthetic fallback construction failure")

        fallback_messages = []
        win.sys_cb.setChecked(True)
        win.soc_cb.setChecked(True)
        try:
            main_module.Backend = FailSocFallback
            QMessageBox.warning = (
                lambda _parent, title, text:
                fallback_messages.append((title, text)))
            QMessageBox.critical = (
                lambda _parent, title, text:
                fallback_messages.append((title, text)))
            assert not win._fresh_backend(True)
        finally:
            main_module.Backend = old_backend_class
            QMessageBox.warning = old_warning
            QMessageBox.critical = old_critical
        assert win.backend is old_backend and old_backend.h
        assert win.soc_cb.isChecked() and win.sys_cb.isChecked()
        assert [title for title, _text in fallback_messages] == [
            "SoC model missing", "Backend reset failed"]
        win.soc_cb.setChecked(False)
        win.sys_cb.setChecked(False)

        assert "no image loaded" in win.status_lbl.text()
        assert "its arrow" in win.status_lbl.text()
        assert win.cyc_cb.text() == "U/V issue"
        assert all(not widget.isEnabled() for widget in win._config_widgets)
        assert not win.reset_btn.isEnabled()
        assert not win.step1_btn.isEnabled()
        assert not win.run_btn.isEnabled()
        assert "Open a program or choose a built example" in (
            win.run_btn.toolTip())
        assert win.run_btn.accessibleDescription() == win.run_btn.toolTip()
        assert "available after opening" in win.reset_btn.toolTip()
        assert "Open a program or choose a built example" in (
            win.evnext_btn.toolTip())
        assert "QCheckBox:disabled{color:#586069;}" in app.styleSheet()
        assert win.regs._session_hint.isVisible()
        assert not win.regs.state_banner.isVisible()
        assert not win.regs.unpin_btn.isVisible()
        assert not win.regs._wide_host.isVisible()
        assert "No program loaded" in win.regs._session_hint.text()
        assert "its arrow" in win.regs._session_hint.text()
        assert win.trace.tbl._empty_hint.isVisible()
        assert "No program loaded" in win.trace.tbl._empty_hint.text()
        assert "its arrow" in win.trace.tbl._empty_hint.text()
        assert win.trace.tbl._empty_hint.accessibleName() == (
            "Empty retired instruction trace explanation")
        assert "No program loaded" in (
            win.trace.tbl.accessibleDescription())
        assert win.trace.match_lbl.accessibleName() == (
            "Retired instruction filter result")
        assert "no program loaded" in (
            win.pipeline.konata.plot.empty_message.lower())
        assert "its arrow" in win.pipeline.konata.plot.empty_message
        assert win.pipeline.spark.backend is None
        assert win.pipeline.board.focusPolicy() == Qt.NoFocus
        assert win.pipeline.spark.focusPolicy() == Qt.NoFocus
        assert "No occupied source-linked lane" in (
            win.pipeline.board.accessibleDescription())
        assert "No program loaded" in (
            win.pipeline.spark.accessibleDescription())
        assert "no program loaded" in (
            win.pipeline.konata.plot.accessibleDescription().lower())
        assert win.pipeline.konata.plot.width() >= (
            win.pipeline.konata.scroll.viewport().width())
        assert win.pipeline.konata.plot.height() >= (
            win.pipeline.konata.scroll.viewport().height())
        assert win.tables.ic._hint.isVisible()
        assert "no program loaded" in win.tables.ic._hint.text().lower()
        assert "its arrow" in win.tables.ic._hint.text()
        assert "no program loaded" in (
            win.tables.ic.accessibleDescription().lower())
        assert win.tables.ic._hint.accessibleName() == (
            "Empty analysis table explanation")
        assert "No program loaded" in win.tables.pf.info.text()
        assert "No program loaded" in (
            win.tables.pf.accessibleDescription())
        assert win.tables.pf.info.accessibleName() == "Prefetch address state"
        assert win.tables.pf.decode.accessibleName() == (
            "Prefetch buffer decode")
        assert all(
            byte.accessibleName() == f"Prefetch buffer byte {index}"
            for index, byte in enumerate(win.tables.pf.byte_lbls))
        assert all(not control.isEnabled()
                   for control in win.tables.mem._session_controls)
        assert all(not button.isEnabled()
                   for button in win.tables.mem.page_buttons)
        assert not win.tables.mem.access_btn.isEnabled()
        assert "No program loaded" in win.tables.mem.follow_lbl.text()
        win.soc_cb.setChecked(True)
        assert win.sys_cb.isChecked()
        win.sys_cb.setChecked(False)
        assert not win.soc_cb.isChecked()
        for widget in (win.reset_btn, win.step1_btn, win.stepi_btn, win.stepn_btn,
                       win.run_btn, win.evprev_btn, win.evnext_btn):
            assert not widget.isEnabled(), f"{widget.text()} active before a program is loaded"
        menu_actions = [
            action for menu in (win._file_menu, win._view_menu, win._help_menu)
            for action in menu.actions()
        ]
        shortcuts = {
            action.shortcut().toString()
            for action in [*win.actions(), *menu_actions]
        }
        for expected in ("F5", "Ctrl+O", "Ctrl+S", "Ctrl+Shift+O", "Ctrl+Shift+R",
                         "Ctrl+Q", "Ctrl+0", "R", "."):
            assert expected in shortcuts, f"missing global shortcut {expected}"
        file_actions = {action.text() for action in win._file_menu.actions()}
        assert {"Open program…", "Save source", "Open snapshot…",
                "Reload program from disk", "Open example", "Quit"} <= file_actions
        assert not win.save_source_action.isEnabled()
        assert not win.reload_action.isEnabled()
        enabled_examples = {
            action.text() for action in win._examples_menu.actions()
            if action.isEnabled()
        }
        assert isinstance(win.program_open_btn, QToolButton)
        assert (win.program_open_btn.popupMode()
                == QToolButton.MenuButtonPopup)
        assert win.program_open_btn.menu() is win._examples_menu
        assert win._examples_menu.toolTipsVisible()
        assert "main button" in (
            win.program_open_btn.accessibleDescription())
        assert "arrow menu" in (
            win.program_open_btn.accessibleDescription())
        example_popup_seen = []

        def close_example_popup():
            example_popup_seen.append(win._examples_menu.isVisible())
            win._examples_menu.close()

        QTimer.singleShot(50, close_example_popup)
        QTest.mouseClick(
            win.program_open_btn, Qt.LeftButton, Qt.NoModifier,
            QPoint(win.program_open_btn.width() - 4,
                   win.program_open_btn.height() // 2))
        settle(app)
        assert example_popup_seen == [True]
        assert not win._examples_menu.isVisible()
        keyboard_popup_seen = []

        def close_keyboard_popup():
            keyboard_popup_seen.append(win._examples_menu.isVisible())
            win._examples_menu.close()

        win.program_open_btn.setFocus(Qt.ShortcutFocusReason)
        QTimer.singleShot(50, close_keyboard_popup)
        QTest.keyClick(win.program_open_btn, Qt.Key_Down)
        settle(app)
        assert keyboard_popup_seen == [True]
        assert not win._examples_menu.isVisible()
        assert {"Dual issue and branches", "D-cache pressure",
                "x87 overlap"} <= enabled_examples
        real_example_lookup = main_module._first_repo_file
        try:
            main_module._first_repo_file = lambda _candidates: None
            win._refresh_example_actions()
            assert all(not action.isEnabled()
                       for action, _candidates in win._example_actions)
            assert all(
                action.toolTip().startswith("Not built; expected ")
                for action, _candidates in win._example_actions)
            assert all(
                candidate in action.toolTip()
                for action, candidates in win._example_actions
                for candidate in candidates)
        finally:
            main_module._first_repo_file = real_example_lookup
            win._refresh_example_actions()
        assert {"Dual issue and branches", "D-cache pressure",
                "x87 overlap"} <= {
            action.text() for action, _candidates in win._example_actions
            if action.isEnabled()}
        view_actions = {action.text() for action in win._view_menu.actions()}
        assert win._view_menu.title() == "Vie&w"
        assert {"Workspace", "Reset panel layout", "Show session toolbar",
                "Show transport toolbar", "Show status toolbar",
                "Analysis tab"} <= view_actions
        assert [action.text() for action in win._workspace_actions] == [
            "Visualizer", "Assembly", "C source"]
        assert [action.shortcut().toString() for action in win._workspace_actions] == [
            "Alt+V", "Alt+A", "Alt+C"]
        assert "Assembly and C workbenches" in {
            action.text() for action in win._help_menu.actions()}
        assert [action.text() for action in win._analysis_actions] == [
            win.tables.tabs.tabText(i) for i in range(win.tables.tabs.count())]
        assert [action.shortcut().toString() for action in win._analysis_actions] == [
            "Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5",
            "Alt+6", "Alt+7", "Alt+8", "Alt+9", "Alt+0"]
        QTest.keyClick(win, Qt.Key_9, Qt.AltModifier)
        settle(app)
        assert win.tables.tabs.currentIndex() == 8
        QTest.keyClick(win, Qt.Key_0, Qt.AltModifier)
        settle(app)
        assert win.tables.tabs.currentIndex() == 9
        assert app.focusWidget() is win.tables.tabs.tabBar()
        assert win.tables.accmap.focusPolicy() == Qt.NoFocus
        QTest.keyClick(win, Qt.Key_1, Qt.AltModifier)
        settle(app)
        assert win.tables.tabs.currentIndex() == 0
        assert app.focusWidget() is win.tables.ic
        win.trace.filt.setText("mov")
        win.tables.tabs.setFocus()
        QTest.keyClick(win.tables.tabs, Qt.Key_Slash)
        settle(app)
        assert win.trace.filt.selectedText() == "mov"
        win.trace.filt.clear()
        help_actions = {action.text() for action in win._help_menu.actions()}
        assert {"User Guide", "How to read the Pipeline View",
                "Keyboard and mouse shortcuts"} <= help_actions
        assert any(action.shortcut().toString() == "F1"
                   for action in win._help_menu.actions())
        QTest.keyClick(win, Qt.Key_F1)
        settle(app)
        assert win._guide_dialog is not None and win._guide_dialog.isVisible()
        assert win._guide_dialog.index.count() >= 8
        assert win._guide_dialog.index.accessibleName() == "User guide topic index"
        assert win._guide_dialog.page.accessibleName() == "User guide topic content"
        guide_screen = win._guide_dialog.screen().availableGeometry()
        assert win._guide_dialog.width() <= guide_screen.width() - 48
        assert win._guide_dialog.height() <= guide_screen.height() - 64
        assert 170 <= win._guide_dialog.index.width() <= 205
        assert win._guide_dialog.page.width() >= 400
        assert "Ctrl+F" in win._guide_dialog.page.accessibleDescription()
        assert app.focusWidget() is win._guide_dialog.index
        assert win._guide_dialog.index.currentItem().text() == "Getting started"
        QTest.keyClick(win._guide_dialog.index, Qt.Key_Down)
        settle(app)
        assert win._guide_dialog.index.currentItem().text() == "Loading programs"
        assert "PT_LOAD" in win._guide_dialog.page.toPlainText()
        loading_row = next(i for i in range(win._guide_dialog.index.count())
                           if win._guide_dialog.index.item(i).text()
                           == "Loading programs")
        win._guide_dialog.index.setCurrentRow(loading_row)
        settle(app)
        assert "PT_LOAD" in win._guide_dialog.page.toPlainText()
        assert "Ctrl+Shift+R" in win._guide_dialog.page.toPlainText()
        assert "exact repository build path" in (
            win._guide_dialog.page.toPlainText())
        assert "pauses continuous Run" in (
            win._guide_dialog.page.toPlainText())
        pipeline_row = next(i for i in range(win._guide_dialog.index.count())
                            if win._guide_dialog.index.item(i).text()
                            == "Reading the Pipeline View")
        win._guide_dialog.index.setCurrentRow(pipeline_row)
        settle(app)
        pipeline_guide = win._guide_dialog.page.toPlainText()
        assert "Stage glyphs" in pipeline_guide
        assert "Ctrl+-" in pipeline_guide
        assert "Tab to the board" in pipeline_guide
        assert "Page Up/Page Down for 64 cycles" in pipeline_guide
        assert "left-drag across the strip" in pipeline_guide
        QTest.keyClick(win._guide_dialog, Qt.Key_F, Qt.ControlModifier)
        settle(app)
        assert win._guide_dialog.find_bar.isVisible()
        assert app.focusWidget() is win._guide_dialog.find_edit
        win._guide_dialog.find_edit.setText("cycle")
        settle(app)
        find_count = re.fullmatch(
            r"1 of ([0-9]+)", win._guide_dialog.find_result.text())
        assert find_count and int(find_count.group(1)) > 1
        find_shot = os.path.join(outdir, "00_help_find.png")
        assert win._guide_dialog.grab().save(find_shot)
        first_match = win._guide_dialog.page.textCursor().selectionStart()
        QTest.keyClick(win._guide_dialog.find_edit, Qt.Key_Return)
        settle(app)
        assert win._guide_dialog.page.textCursor().selectionStart() > first_match
        QTest.keyClick(win._guide_dialog.find_edit, Qt.Key_F3,
                       Qt.ShiftModifier)
        settle(app)
        assert win._guide_dialog.page.textCursor().selectionStart() == first_match
        win._guide_dialog.find_edit.setText("definitely absent phrase")
        settle(app)
        assert win._guide_dialog.find_result.text() == "No matches"
        assert not win._guide_dialog.find_prev.isEnabled()
        assert not win._guide_dialog.find_next.isEnabled()
        QTest.keyClick(win._guide_dialog.find_edit, Qt.Key_Escape)
        settle(app)
        assert not win._guide_dialog.find_bar.isVisible()
        assert not win._guide_dialog.find_edit.text()
        assert not win._guide_dialog.find_result.text()
        assert not win._guide_dialog.page.textCursor().hasSelection()
        assert not win._guide_dialog.find_prev.isEnabled()
        assert not win._guide_dialog.find_next.isEnabled()
        assert app.focusWidget() is win._guide_dialog.index
        authoring_row = next(i for i in range(win._guide_dialog.index.count())
                             if win._guide_dialog.index.item(i).text()
                             == "Assembly and C workbenches")
        win._guide_dialog.index.setCurrentRow(authoring_row)
        settle(app)
        guide_text = win._guide_dialog.page.toPlainText()
        assert "Ctrl+Space" in guide_text and "Compile → Assembly" in guide_text
        assert "source badge" in guide_text
        assert "press Enter, or double-click it" in guide_text
        authoring_shot = os.path.join(
            outdir, "00_help_authoring_guide.png")
        assert win._guide_dialog.grab().save(authoring_shot)
        win._guide_dialog.index.setCurrentRow(pipeline_row)
        settle(app)
        guide_shot = os.path.join(outdir, "00_help_pipeline_guide.png")
        assert win._guide_dialog.grab().save(guide_shot)
        QTest.keyClick(win._guide_dialog.index, Qt.Key_Escape)
        settle(app)
        assert not win._guide_dialog.isVisible()
        win._clear_notice()  # keep the startup reference capture transient-free
        save_shot(app, win, outdir, "00_startup")
        branch_example = next(
            action for action in win._examples_menu.actions()
            if action.text() == "Dual issue and branches")
        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        win.assembly.editor.setFocus(Qt.OtherFocusReason)
        settle(app)
        assert all(toolbar.isHidden() for toolbar in (
            win.session_toolbar, win.transport_toolbar, win.status_toolbar))
        branch_example.trigger()
        settle(app)
        assert win.workspace.currentWidget() is win.visualizer_tab
        assert win.pipeline.konata.plot.isVisible()
        assert win.image_path and "mb_brloop" in os.path.basename(win.image_path)
        assert win.reload_action.isEnabled() and win.step1_btn.isEnabled()
        assert all(widget.isEnabled() for widget in win._config_widgets)
        assert not win.regs._session_hint.isVisible()
        assert win.regs.state_banner.isVisible()
        assert win.regs.state_banner.text().startswith("LIVE")
        assert not win.regs.unpin_btn.isVisible()
        assert win.regs._wide_host.isVisible()
        assert win.trace.tbl._empty_hint.isVisible()
        assert "No instructions retired" in win.trace.tbl._empty_hint.text()
        assert "No retirements yet" in win.pipeline.konata.plot.empty_message
        assert win.pipeline.spark.backend is win.backend
        assert "no program loaded" not in win.tables.ic._hint.text().lower()
        assert all(control.isEnabled()
                   for control in win.tables.mem._session_controls)
        assert not win.tables.mem.access_btn.isEnabled()

        # A program dropped over either source editor is also an external load:
        # reveal the resulting debugger instead of replacing its backend behind
        # hidden transport/status chrome.
        loaded_example = win.image_path
        win.workspace.setCurrentWidget(win.c_source)
        settle(app)
        assert win._load_dropped_path(loaded_example)
        settle(app)
        assert win.workspace.currentWidget() is win.visualizer_tab
        assert win.pipeline.konata.plot.isVisible()
        assert win.backend.retire_count() == 0

        manifest_dir = os.path.join(outdir, "numeric_manifest")
        os.makedirs(manifest_dir, exist_ok=True)
        manifest_image = os.path.join(manifest_dir, "tiny.flat")
        manifest_bytes = b"\x90\xf4"
        with open(manifest_image, "wb") as image_file:
            image_file.write(manifest_bytes)
        with open(os.path.join(manifest_dir, "manifest.json"), "w",
                  encoding="utf-8") as manifest_file:
            json.dump({"entry": 0x00100000,
                       "load_addr": "0x00100000",
                       "esp": "0x001ff000",
                       "uv_issue": False,
                       "system": False,
                       "soc": False}, manifest_file)
        win.load_image(manifest_image)
        assert int(win.entry_e.text(), 0) == 0x00100000
        assert int(win.load_e.text(), 0) == 0x00100000
        assert int(win.esp_e.text(), 0) == 0x001ff000
        assert not win.cyc_cb.isChecked()
        assert not win.sys_cb.isChecked() and not win.soc_cb.isChecked()
        assert win.backend.state().eip == 0x00100000
        assert win.backend.mem_read(0x00100000, 2) == manifest_bytes

        invalid_manifest_dir = os.path.join(outdir, "invalid_manifest")
        os.makedirs(invalid_manifest_dir, exist_ok=True)
        invalid_manifest_image = os.path.join(
            invalid_manifest_dir, "partial.flat")
        with open(invalid_manifest_image, "wb") as image_file:
            image_file.write(manifest_bytes)
        with open(os.path.join(invalid_manifest_dir, "manifest.json"), "w",
                  encoding="utf-8") as manifest_file:
            # The valid early entry must not leak through when a later launch
            # field invalidates the manifest.
            json.dump({"entry": "0x00100000", "system": 1}, manifest_file)
        manifest_warnings = []
        original_warning = main_module.QMessageBox.warning
        main_module.QMessageBox.warning = (
            lambda _parent, title, message:
            manifest_warnings.append((title, message)))
        try:
            win.load_image(invalid_manifest_image)
        finally:
            main_module.QMessageBox.warning = original_warning
        assert manifest_warnings and manifest_warnings[0][0] == "Manifest ignored"
        assert "system must be true or false" in manifest_warnings[0][1]
        assert int(win.entry_e.text(), 0) == DEF_ENTRY
        assert int(win.load_e.text(), 0) == DEF_ENTRY

        explicit_system_dir = os.path.join(outdir, "manifest_system")
        os.makedirs(explicit_system_dir, exist_ok=True)
        explicit_system_image = os.path.join(
            explicit_system_dir, "firmware.bin")
        with open(explicit_system_image, "wb") as system_file:
            system_file.write(b"\0" * 0x8000)
        with open(os.path.join(explicit_system_dir, "manifest.json"), "w",
                  encoding="utf-8") as manifest_file:
            json.dump({"system": True, "uv_issue": True}, manifest_file)
        win.load_image(explicit_system_image)
        assert win.sys_cb.isChecked() and not win.soc_cb.isChecked()
        assert win.cyc_cb.isChecked()
        assert int(win.load_e.text(), 0) == 0x000F8000
        assert all(not field.isEnabled()
                   for field in (win.entry_e, win.load_e, win.esp_e))

        # `.bin` alone must not force an ordinary large flat program into BIOS
        # boot, and a different workload must receive a fresh default stack.
        large_user = os.path.join(outdir, "large_user.bin")
        with open(large_user, "wb") as user_file:
            user_file.write(b"\xf4" + b"\0" * (0x8000 - 1))
        win.load_image(large_user)
        assert not win.sys_cb.isChecked() and not win.soc_cb.isChecked()
        assert all(field.isEnabled()
                   for field in (win.entry_e, win.load_e, win.esp_e))
        assert int(win.esp_e.text(), 0) == DEF_ESP

        long_loop = os.path.join(outdir, "long_refresh.flat")
        with open(long_loop, "wb") as loop_file:
            # mov eax,eax; mov ebx,ebx; jmp back to the first mov
            loop_file.write(b"\x89\xc0\x89\xdb\xeb\xfa")
        win.load_image(long_loop)
        win.do_step(9000, False)
        total_retired = win.backend.retire_count()
        assert win.backend.cycle_count() == 9000
        assert win.pipeline.konata._last_cyc == 9000
        assert win.pipeline.spark._last_cyc == 9000
        assert win.tables.cyc._last_cyc == 9000
        assert sum(win.tables.cyc.counts.values()) == 9000
        assert len(win.pipeline.spark.ret) == 9000
        assert total_retired > trace_module._MAX_ROWS
        assert win.trace.tbl.rowCount() == trace_module._MAX_ROWS
        assert int(win.trace.tbl.item(0, 0).text()) == (
            total_retired - trace_module._MAX_ROWS)
        assert int(win.trace.tbl.item(
            win.trace.tbl.rowCount() - 1, 0).text()) == total_retired - 1
        assert f"of {total_retired:,}" in win.trace.title.text()
        print("OK startup/help/load: disabled transport, shortcuts, indexed "
              "Pipeline guide, honest empty states, examples, numeric manifest, "
              "9k-clock refresh")
    finally:
        close_window(win)


def scenario_branch_transport(app, outdir):
    win = new_window(app)
    try:
        win.load_image(repo_path("build/verify/mb_brloop.cycle.flat"))
        settle(app)
        assert win.image_kind == "flat image" and win._has_session()
        assert win.step1_btn.isEnabled() and not win.sys_cb.isChecked()

        # A nested file chooser must not let a running model race ahead behind
        # an obscured debugger. Cancel leaves execution paused and consumes no
        # extra clock; resuming remains explicit.
        win.on_run_toggle()
        assert win._running and win.timer.isActive()
        assert win.run_btn.toolTip() == "Pause continuous execution (F5)"
        assert win.run_btn.accessibleDescription() == win.run_btn.toolTip()
        menu_cycle = win.backend.cycle_count()
        menu_seen = []

        def close_running_example_menu():
            menu_seen.append(win._examples_menu.isVisible())
            win._examples_menu.close()

        QTimer.singleShot(50, close_running_example_menu)
        win.program_open_btn.showMenu()
        settle(app)
        assert menu_seen == [True]
        assert not win._running and not win.timer.isActive()
        assert win.backend.cycle_count() == menu_cycle
        assert "before opening the example menu" in win.action_hint.text()

        win.on_run_toggle()
        assert win._running and win.timer.isActive()
        chooser_cycle = win.backend.cycle_count()
        real_open_dialog = QFileDialog.getOpenFileName
        QFileDialog.getOpenFileName = staticmethod(
            lambda *_args, **_kwargs: ("", ""))
        try:
            win.on_open()
        finally:
            QFileDialog.getOpenFileName = real_open_dialog
        assert not win._running and not win.timer.isActive()
        assert win.backend.cycle_count() == chooser_cycle
        assert "before opening the program chooser" in win.action_hint.text()

        # A load that fails before Reset must still pause first; otherwise its
        # modal error would hide a model that continues to advance.
        win.on_run_toggle()
        failed_cycle = win.backend.cycle_count()
        failed_loads = []
        old_critical = QMessageBox.critical
        QMessageBox.critical = staticmethod(
            lambda _parent, title, text:
            failed_loads.append((title, text)))
        try:
            assert not win.load_image(
                os.path.join(outdir, "missing-program.flat"))
        finally:
            QMessageBox.critical = old_critical
        assert failed_loads and failed_loads[0][0] == "Open failed"
        assert not win._running and not win.timer.isActive()
        assert win.backend.cycle_count() == failed_cycle
        assert "before loading a program" in win.action_hint.text()

        win.on_run_toggle()
        snapshot_cycle = win.backend.cycle_count()
        snapshot_backend = win.backend
        failed_snapshots = []
        QMessageBox.critical = staticmethod(
            lambda _parent, title, text:
            failed_snapshots.append((title, text)))
        try:
            assert not win.load_snapshot(
                os.path.join(outdir, "missing-checkpoint.aux"))
        finally:
            QMessageBox.critical = old_critical
        assert failed_snapshots
        assert failed_snapshots[0][0] == "Snapshot restore failed"
        assert win.backend is snapshot_backend and win.backend.h
        assert win.backend.cycle_count() == snapshot_cycle
        assert not win._running and not win.timer.isActive()
        assert "before loading a snapshot" in win.action_hint.text()

        dropped_assembly = os.path.join(outdir, "running-drop.S")
        with open(dropped_assembly, "w", encoding="utf-8") as source_file:
            source_file.write(
                ".intel_syntax noprefix\n.global _start\n_start:\n    hlt\n")
        win.on_run_toggle()
        drop_cycle = win.backend.cycle_count()
        assert win._load_dropped_path(dropped_assembly)
        settle(app)
        assert not win._running and not win.timer.isActive()
        assert win.backend.cycle_count() == drop_cycle
        assert win.workspace.currentWidget() is win.assembly
        assert win.assembly.editor.toPlainText().endswith("    hlt\n")
        win.workspace.setCurrentWidget(win.visualizer_tab)
        settle(app)

        # Bad reset addresses are rejected visibly before replacing the backend.
        old_backend = win.backend
        invalid_seen = []

        def dismiss_invalid():
            for widget in app.topLevelWidgets():
                if isinstance(widget, QMessageBox):
                    invalid_seen.append(widget.windowTitle())
                    widget.accept()

        invalid_timer = QTimer()
        invalid_timer.timeout.connect(dismiss_invalid)
        invalid_timer.start(5)
        win.entry_e.setText("not-hex")
        win.on_reset()
        invalid_timer.stop()
        settle(app)
        assert invalid_seen == ["Invalid address"]
        assert win.backend is old_backend
        assert "#f85149" in win.entry_e.styleSheet()
        win.entry_e.setText("0x08048000")
        win.on_reset()
        assert not win.entry_e.styleSheet()
        win.cyc_cb.setChecked(False)
        assert "Apply + Reset" in win.reset_btn.text()
        assert "#e3b341" in win.reset_btn.styleSheet()
        assert "Pending: U/V issue" in win.reset_btn.toolTip()
        assert win.reset_btn.accessibleDescription() == (
            win.reset_btn.toolTip())
        assert win.action_hint.text().startswith("Pending: U/V issue")
        save_shot(app, win, outdir, "01a_pending_uv_reset")
        win.cyc_cb.setChecked(True)
        assert win.reset_btn.text().strip() == "Reset"
        assert not win.reset_btn.styleSheet()
        assert "Pending:" not in win.reset_btn.toolTip()
        assert "no reset needed" in win.action_hint.text()
        applied_entry = win.entry_e.text()
        win.entry_e.setText("0x08048001")
        win.entry_e.textEdited.emit(win.entry_e.text())
        assert "Apply + Reset" in win.reset_btn.text()
        assert "Pending: entry" in win.reset_btn.toolTip()
        assert win.action_hint.text().startswith("Pending: entry")
        win.entry_e.setText(applied_entry.upper())
        win.entry_e.textEdited.emit(win.entry_e.text())
        assert win.reset_btn.text().strip() == "Reset"
        assert not win.reset_btn.styleSheet()
        win.on_reset()
        assert win.reset_btn.text().strip() == "Reset"
        assert not win.reset_btn.styleSheet()

        win.sys_cb.setChecked(True)
        assert "Pending: system mode" in win.reset_btn.toolTip()
        pending_tip = win.reset_btn.toolTip().split("Pending:", 1)[1]
        assert "entry" not in pending_tip
        assert "ESP" not in pending_tip
        assert "load" not in pending_tip
        win.sys_cb.setChecked(False)
        assert win.reset_btn.text().strip() == "Reset"

        c0 = win.backend.state().core_cyc
        click(app, win.step1_btn)
        assert win.backend.state().core_cyc == c0 + 1
        r0 = win.backend.retire_count()
        step_cycle = win.backend.cycle_count()
        click(app, win.stepi_btn)
        assert win.backend.retire_count() > r0
        elapsed = win.backend.cycle_count() - step_cycle
        assert win.action_hint.text() == (
            f"Advanced {elapsed} clock"
            f"{'' if elapsed == 1 else 's'} · reached next retirement")
        assert "instruction boundary" not in win.action_hint.text()

        assert win.reload_action.isEnabled()
        win.esp_e.setText("0x40c34000")
        win.reload_action.trigger()
        settle(app)
        assert win.backend.retire_count() == 0
        assert sum(win.tables.cyc.counts.values()) == 0
        assert win.esp_e.text() == "0x40c34000"
        assert win.backend.state().gpr[4] == 0x40c34000
        click(app, win.reset_btn)
        assert win.backend.retire_count() == 0
        win.stepn.setValue(120)
        click(app, win.stepn_btn)
        assert win.backend.state().core_cyc == 120
        assert win.backend.retire_count() >= 180
        live = win.backend.state()
        u_size, u_mnemonic, _u_ops, _u_bytes = (
            pipeline_module.disasm.disasm_one(
                win.backend.mem_read(live.cs_base + live.eip, 16),
                live.eip, 32))
        v_pc = live.eip + u_size
        v_size, v_mnemonic, _v_ops, _v_bytes = (
            pipeline_module.disasm.disasm_one(
                win.backend.mem_read(live.cs_base + v_pc, 16),
                v_pc, 32))
        assert (u_mnemonic, u_size, live.ud_len) == ("dec", 1, 1)
        assert (v_mnemonic, v_size, live.vd_len) == ("jne", 2, 2)
        assert not live.ud_is_branch and live.vd_is_branch
        assert win.pipeline.board._cells["V"][1].startswith("jne ")
        board_description = win.pipeline.board.accessibleDescription()
        assert "S_PIPE" in board_description
        assert f"V: PC 0x{v_pc:08x}, jne " in board_description
        assert "Keyboard lane U selected" in board_description
        lifecycles = win.pipeline.konata.plot.insns
        assert min(item["c0"] for item in lifecycles) >= 1
        assert max(item["c1"] for item in lifecycles) <= live.core_cyc
        stats = win.pipeline.waterfall.stats()
        assert stats["vret"] >= 80 and stats["mispred"] > 0
        assert "pair(win)" not in win.status_lbl.text()
        assert "captured session" in win.status_lbl.toolTip()
        win.pipeline.konata._history_truncated = True
        win._refresh_status(win.backend.state())
        expected_pair = round(
            200 * stats["vret"] / (stats["uret"] + stats["vret"]))
        assert "pair(win)" in win.status_lbl.text()
        assert f"&nbsp;{expected_pair}%" in win.status_lbl.text()
        assert "current program/restore session" in win.status_lbl.toolTip()
        win.pipeline.konata._history_truncated = False
        win._refresh_status(win.backend.state())
        assert win.tables.br.rowCount() >= 1 and win.tables.mix.rowCount() >= 2
        # The newest row is a JNE whose successor has not retired yet. It is a
        # hit, not a fabricated not-taken outcome: resolved loop iterations are
        # all taken and therefore remain 100%.
        assert win.tables.br.item(0, 3).text() == "105"
        assert win.tables.br.item(0, 4).text() == "104/104"
        assert win.tables.br.item(0, 5).text() == "100"
        assert "104/105 outcomes resolved" in win.tables.br_lbl.text()
        assert win.tables.br.horizontalHeaderItem(4).text() == "taken/resolved"
        assert win.tables.br.horizontalHeaderItem(5).text() == "taken %"
        assert win.tables.br.horizontalHeaderItem(6).text() == "bias bar"
        assert "capture-tail" in win.tables.br.horizontalHeaderItem(5).toolTip()
        assert "taken decile" in (
            win.tables.br.horizontalHeaderItem(6).toolTip())
        assert len(win.pipeline.konata.plot.insns) == win.trace.tbl.rowCount()

        # A retire cycle can contain both U and V. Clicking either Trace row
        # must select that exact timing row, not whichever lane happened to be
        # last in the cycle->row lookup.
        plot = win.pipeline.konata.plot
        paired_rows = next(
            ((index - 1, index)
             for index in range(1, len(plot.insns))
             if (plot.insns[index - 1]["c1"] == plot.insns[index]["c1"]
                 and {plot.insns[index - 1]["pipe"],
                      plot.insns[index]["pipe"]} == {"U", "V"})),
            None)
        assert paired_rows is not None
        trace_row_for_n = {
            int(win.trace.tbl.item(row, 0).text()): row
            for row in range(win.trace.tbl.rowCount())
        }
        pair_cycle = plot.insns[paired_rows[0]]["c1"]
        for timing_row in paired_rows:
            exact_n = plot.insns[timing_row]["n"]
            select_table_row(app, win.trace.tbl, trace_row_for_n[exact_n])
            assert plot.sel_row == timing_row
            assert plot.insns[plot.sel_row]["n"] == exact_n
            assert plot.playhead == pair_cycle
            assert win._pinned_n == exact_n
            assert win.action_hint.text().startswith(
                f"Pinned retirement n={exact_n} · cycle {pair_cycle} · ")
            assert f"Selected retirement n={exact_n}" in (
                plot.accessibleDescription())

        # Escape is the keyboard equivalent of Unpin, but only after the
        # narrower Trace-filter Escape behavior has nothing to clear.
        escape_cycle = win.backend.state().core_cyc
        plot.setFocus()
        QTest.keyClick(plot, Qt.Key_Escape)
        settle(app)
        assert win.backend.state().core_cyc == escape_cycle
        assert win._pinned_n is None
        assert win.regs.state_banner.text().startswith("LIVE")
        assert win.trace.tbl.currentRow() < 0 and plot.sel_row is None

        # Reload validates preserved setup before touching the running session.
        old_backend = win.backend
        old_retired = win.backend.retire_count()
        old_rows = win.trace.tbl.rowCount()
        invalid_seen.clear()
        invalid_timer.start(5)
        win.entry_e.setText("not-hex")
        win.reload_action.trigger()
        invalid_timer.stop()
        settle(app)
        assert invalid_seen == ["Invalid address"]
        assert win.backend is old_backend
        assert win.backend.retire_count() == old_retired
        assert win.trace.tbl.rowCount() == old_rows
        win.entry_e.setText("0x08048000")

        # A placement that crosses 4 GiB is rejected before the live model is
        # closed, just like malformed address text.
        invalid_seen.clear()
        invalid_timer.start(5)
        win.load_e.setText("0xfffffff0")
        win.on_reset()
        invalid_timer.stop()
        settle(app)
        assert invalid_seen == ["Invalid program placement"]
        assert win.backend is old_backend
        assert win.backend.retire_count() == old_retired
        win.load_e.setText("0x08048000")

        visible_v = set_filter(app, win.trace, "pipe:V")
        assert 50 <= visible_v < win.trace.tbl.rowCount()
        assert f"{visible_v}/{win.trace.tbl.rowCount()} match" == win.trace.match_lbl.text()
        assert (
            f"{visible_v} of {win.trace.tbl.rowCount()} retirements match"
            in win.trace.match_lbl.accessibleDescription())
        assert win.trace.filt.accessibleDescription() == (
            win.trace.match_lbl.accessibleDescription())
        assert (
            f"{win.trace.tbl.rowCount()} retirement rows"
            in win.trace.tbl.accessibleDescription())
        assert win.trace.prev_match_btn.isVisible()
        assert win.trace.next_match_btn.isVisible()
        QTest.keyClick(win.trace.filt, Qt.Key_Return)
        settle(app)
        first_match = win.trace.tbl.currentRow()
        assert first_match >= 0
        assert win.trace.tbl.item(first_match, 3).text() == "V"
        QTest.keyClick(win.trace.filt, Qt.Key_F3)
        settle(app)
        second_match = win.trace.tbl.currentRow()
        assert second_match > first_match
        assert win.trace.tbl.item(second_match, 3).text() == "V"
        QTest.keyClick(win.trace.filt, Qt.Key_F3, Qt.ShiftModifier)
        settle(app)
        assert win.trace.tbl.currentRow() == first_match
        selected_match_n = win.trace.tbl.item(first_match, 0).text()
        set_filter(app, win.trace, "")
        assert win.trace.tbl.currentRow() == first_match
        assert win.trace.tbl.item(first_match, 0).text() == selected_match_n
        pc_matches = set_filter(app, win.trace, "pc:0804800a")
        assert pc_matches > 50
        assert all(
            win.trace.tbl.isRowHidden(row)
            or win.trace.tbl.item(row, 4).text() == "0804800a"
            for row in range(win.trace.tbl.rowCount())
        )
        n_matches = set_filter(app, win.trace, "n>=200")
        assert n_matches == 12
        assert all(
            win.trace.tbl.isRowHidden(row)
            or int(win.trace.tbl.item(row, 0).text()) >= 200
            for row in range(win.trace.tbl.rowCount())
        )
        # Structured typos are not legitimate zero-result searches: explain
        # the syntax and retain all rows as context while the query is fixed.
        total_rows = win.trace.tbl.rowCount()
        assert set_filter(app, win.trace, "n>200") == total_rows
        assert win.trace.match_lbl.text() == "invalid filter"
        assert "use >=" in win.trace.filt.toolTip()
        assert "Invalid trace filter" in (
            win.trace.match_lbl.accessibleDescription())
        assert f"All {total_rows} rows remain visible" in (
            win.trace.match_lbl.accessibleDescription())
        assert not win.trace.next_match_btn.isEnabled()
        assert set_filter(app, win.trace, "pc:xyz") == total_rows
        assert "hexadecimal PC" in win.trace.filt.toolTip()
        save_shot(app, win, outdir, "01a_invalid_trace_filter")
        assert set_filter(app, win.trace, "n>=0200") == 12
        set_filter(app, win.trace, "not-a-real-retirement")
        assert not win.trace.next_match_btn.isEnabled()
        assert "#f85149" in win.trace.filt.styleSheet()
        QTest.keyClick(win.trace.filt, Qt.Key_Escape)
        settle(app)
        assert not win.trace.filt.text()
        assert not win.trace.next_match_btn.isVisible()
        win.trace.filt.setText("mov")
        win.trace.tbl.setFocus()
        QTest.keyClick(win.trace.tbl, Qt.Key_Slash)
        settle(app)
        # Offscreen Qt does not reactivate a parent window after a modal closes,
        # so focusWidget() is unreliable here; selectAll proves the slash handler
        # reached the editor and is exactly what a visible session presents.
        assert win.trace.filt.selectedText() == "mov"
        win.trace.filt.clear()

        row = win.trace.tbl.rowCount() - 5
        select_table_row(app, win.trace.tbl, row)
        selected_n = int(win.trace.tbl.item(row, 0).text())
        selected_rec = next(
            rec for rec in win.backend.get_retires(selected_n, 1)
            if rec.n == selected_n)
        assert win._pinned_n == selected_n
        assert win.regs.mode_lbl.text() == (
            f"{'SYS' if selected_rec.sys_mode else 'USER'}  "
            f"CPL={selected_rec.cpl}"
            f"{'  SMM' if selected_rec.smm_active else ''}")
        assert win.regs.state_banner.text().startswith(
            f"PINNED n={selected_n} ·")
        assert "post-commit" in win.regs.state_banner.toolTip()
        assert "pre-execution" in win.regs.state_banner.toolTip()
        assert win.regs.unpin_btn.isVisible()
        assert "without advancing" in win.regs.unpin_btn.toolTip()
        assert selected_rec.x87_valid
        assert win.regs.fphdr.text().startswith("logical")
        assert win.pipeline.konata.plot.playhead is not None

        plot = win.pipeline.konata.plot
        anchor_row = max(0, plot.sel_row - 4)
        anchor_cyc = plot.insns[anchor_row]["c1"]
        QTest.mouseClick(plot, Qt.LeftButton, Qt.ShiftModifier,
                         QPoint(max(1, plot._x(anchor_cyc) + 2), anchor_row * ROW_H + ROW_H // 2))
        settle(app)
        assert plot.anchor == anchor_cyc

        # The timing diagram is a debugger surface, not a static picture: it
        # must be traversable from the keyboard and keep Trace/Registers linked.
        plot.setFocus()
        retire_reads = []
        real_get_retires = win.backend.get_retires
        win.backend.get_retires = lambda *args: (
            retire_reads.append(args), real_get_retires(*args))[1]
        try:
            QTest.keyClick(plot, Qt.Key_End)
            settle(app)
        finally:
            win.backend.get_retires = real_get_retires
        assert len(retire_reads) == 1, (
            f"Pipeline selection performed {len(retire_reads)} pin reads")
        assert plot.sel_row == len(plot.insns) - 1
        assert win._pinned_n == plot.insns[-1]["n"]
        QTest.keyClick(plot, Qt.Key_Up)
        settle(app)
        assert plot.sel_row == len(plot.insns) - 2
        assert int(win.trace.tbl.item(win.trace.tbl.currentRow(), 0).text()) == (
            plot.insns[plot.sel_row]["n"])
        QTest.keyClick(plot, Qt.Key_PageUp)
        settle(app)
        assert plot.sel_row == len(plot.insns) - 12
        QTest.keyClick(plot, Qt.Key_Home)
        settle(app)
        assert plot.sel_row == 0 and win._pinned_n == plot.insns[0]["n"]

        # Cycle zoom changes geometry, keeps the selected cycle visible, and
        # restores exactly to the default scale.
        zoom = win.pipeline.konata
        assert plot.cell_w == 20 and zoom.zoom_reset_btn.text() == "100%"
        default_width = plot.width()
        click(app, zoom.zoom_out_btn)
        assert plot.cell_w == 12 and zoom.zoom_reset_btn.text() == "60%"
        assert plot.width() < default_width
        play_x = plot._x(plot.playhead)
        hb = zoom.scroll.horizontalScrollBar()
        assert hb.value() <= play_x <= hb.value() + zoom.scroll.viewport().width()
        click(app, zoom.zoom_reset_btn)
        assert plot.cell_w == 20 and plot.width() == default_width
        QTest.keyClick(plot, Qt.Key_Minus, Qt.ControlModifier)
        settle(app)
        assert plot.cell_w == 12
        QTest.keyClick(plot, Qt.Key_Equal, Qt.ControlModifier)
        settle(app)
        assert plot.cell_w == 20

        old_playhead = plot.playhead
        spark = win.pipeline.spark
        pinned_n = win._pinned_n
        selected_row = plot.sel_row
        selected_pc = plot.sel_pc
        trace_n = int(win.trace.tbl.item(
            win.trace.tbl.currentRow(), 0).text())
        first_cyc = spark._last_cyc - len(spark.ev) + 1
        assert spark._cyc_at(spark._LABELW - 1) is None
        assert spark._cyc_at(spark._LABELW) is not None
        assert spark._cyc_at(spark.width() - 4) is None
        QTest.mouseMove(spark, QPoint(spark._LABELW - 1, 8))
        assert spark.cursor().shape() == Qt.ArrowCursor
        before_label_click = plot.playhead
        QTest.mouseClick(
            spark, Qt.LeftButton, Qt.NoModifier,
            QPoint(spark._LABELW - 1, 8))
        assert plot.playhead == before_label_click
        QTest.mouseMove(spark, QPoint(spark._LABELW + 2, 8))
        assert spark.cursor().shape() == Qt.SizeHorCursor
        assert spark.next_event(first_cyc - 1, -1) is None
        assert spark.next_event(spark._last_cyc + 1, 1) is None
        spark.setFocus()
        settle(app)
        QTest.keyClick(spark, Qt.Key_Left)
        settle(app)
        assert spark._kbd_cyc == spark._last_cyc - 1
        assert plot.playhead == spark._kbd_cyc
        assert win.action_hint.text() == (
            f"Pipeline cycle {spark._kbd_cyc} selected · "
            f"retirement pin n={pinned_n} unchanged")
        assert f"Cycle {spark._kbd_cyc} selected" in (
            spark.accessibleDescription())
        assert f"Playhead cycle {spark._kbd_cyc}" in (
            plot.accessibleDescription())
        QTest.keyClick(spark, Qt.Key_PageUp)
        settle(app)
        assert spark._kbd_cyc == max(first_cyc, spark._last_cyc - 65)
        assert plot.playhead == spark._kbd_cyc
        QTest.keyClick(spark, Qt.Key_Home)
        settle(app)
        assert spark._kbd_cyc == first_cyc and plot.playhead == first_cyc
        hb = win.pipeline.konata.scroll.horizontalScrollBar()
        assert (
            hb.value()
            <= plot._x(first_cyc)
            <= hb.value() + win.pipeline.konata.scroll.viewport().width())
        QTest.keyClick(spark, Qt.Key_End)
        QTest.keyClick(spark, Qt.Key_Return)
        settle(app)
        assert spark._kbd_cyc == spark._last_cyc
        assert plot.playhead == spark._last_cyc
        assert (
            hb.value()
            <= plot._x(spark._last_cyc)
            <= hb.value() + win.pipeline.konata.scroll.viewport().width())
        # Cycle seek never invents one exact instruction from an ambiguous U/V
        # retire cycle or desynchronizes the existing linked pin.
        assert win._pinned_n == pinned_n == trace_n
        assert plot.sel_row == selected_row
        assert plot.sel_pc == selected_pc
        assert int(win.trace.tbl.item(
            win.trace.tbl.currentRow(), 0).text()) == trace_n
        drag_start = QPoint(spark._LABELW + 2, 8)
        drag_end = QPoint(spark.width() - 8, 8)
        drag_start_cycle = spark._cyc_at(drag_start.x())
        drag_end_cycle = spark._cyc_at(drag_end.x())
        assert (
            drag_start_cycle is not None
            and drag_end_cycle is not None
            and drag_start_cycle < drag_end_cycle)
        QTest.mousePress(spark, Qt.LeftButton, Qt.NoModifier, drag_start)
        assert spark._dragging
        QTest.mouseMove(spark, drag_end)
        QTest.mouseRelease(spark, Qt.LeftButton, Qt.NoModifier, drag_end)
        settle(app)
        assert not spark._dragging
        assert spark._kbd_cyc == drag_end_cycle
        assert plot.playhead == drag_end_cycle
        assert win._pinned_n == pinned_n
        assert plot.sel_row == selected_row and plot.sel_pc == selected_pc
        assert win.action_hint.text() == (
            f"Pipeline cycle {drag_end_cycle} selected · "
            f"retirement pin n={pinned_n} unchanged")
        assert f"Cycle {drag_end_cycle} selected" in (
            spark.accessibleDescription())
        plot.setFocus()
        old_playhead = plot.playhead
        click(app, win.evprev_btn)
        assert plot.playhead is not None and plot.playhead <= old_playhead
        click(app, win.evnext_btn)
        assert plot.playhead is not None
        mispred_idx = win.event_kind.findData("m")
        assert mispred_idx >= 0
        win.event_kind.setCurrentIndex(mispred_idx)
        plot.playhead = None
        click(app, win.evprev_btn)
        event_i = (
            len(win.pipeline.spark.ev) - 1
            - (win.pipeline.spark._last_cyc - plot.playhead))
        assert win.pipeline.spark.ev[event_i] == "m"
        assert "mispredict event at cycle" in win.action_hint.text()
        walk_idx = win.event_kind.findData("w")
        win.event_kind.setCurrentIndex(walk_idx)
        plot.playhead = None
        click(app, win.evnext_btn)
        assert "No later page-walk" in win.action_hint.text()
        win.event_kind.setCurrentIndex(win.event_kind.findData("any"))
        QTest.keyClick(plot, Qt.Key_End)
        settle(app)

        set_filter(app, win.trace, "no-visible-hotspot-row")
        select_tab(app, win.tables.tabs, 4)
        win.tables.hot.setCurrentCell(0, 0)
        win.tables.hot.setFocus()
        QTest.keyClick(win.tables.hot, Qt.Key_Return)
        settle(app)
        selected_pc = int(win.tables.hot.item(0, 0).text(), 16)
        assert int(win.trace.tbl.item(win.trace.tbl.currentRow(), 4).text(), 16) == selected_pc
        assert not win.trace.filt.text()
        assert win.trace.tbl.currentRow() >= win.trace.tbl.rowCount() - 10
        assert win.trace.select_pc(0xDEADBEEF) is False

        # Analysis retains Pipeline's longer window. Force the exact condition
        # where its PC has fallen out of Trace and require a visible, pinned
        # Pipeline fallback instead of a silent no-op.
        fallback_pc = plot.insns[0]["pc"]
        candidates = [
            row for row, insn in enumerate(plot.insns)
            if insn["pc"] == fallback_pc]
        expected_row = min(
            candidates, key=lambda row: abs(row - plot.sel_row))
        real_select_pc = win.trace.select_pc
        win.trace.select_pc = lambda _pc: False
        try:
            win._select_pc_origin(fallback_pc)
        finally:
            win.trace.select_pc = real_select_pc
        assert plot.sel_row == expected_row
        assert win._pinned_n == plot.insns[expected_row]["n"]
        assert "outside Trace" in win.action_hint.text()
        win._select_pc_origin(0xDEADBEEF)
        assert "outside the retained Trace/Pipeline windows" in win.action_hint.text()

        click(app, win.reset_btn)
        settle(app)
        assert win.regs.state_banner.text().startswith("LIVE")
        assert win.pipeline.konata.plot.width() >= (
            win.pipeline.konata.scroll.viewport().width())
        assert win.pipeline.konata.plot.height() >= (
            win.pipeline.konata.scroll.viewport().height())
        assert win.pipeline.konata.scroll.horizontalScrollBar().maximum() == 0
        win.speed.setValue(8)
        before = win.backend.state().core_cyc
        click(app, win.run_btn)
        QTest.qWait(100)
        settle(app)
        assert win.run_btn.text().strip() == "Pause"
        assert win.run_btn.toolTip() == "Pause continuous execution (F5)"
        click(app, win.run_btn)
        assert not win._running and win.backend.state().core_cyc > before
        assert win.run_btn.toolTip() == "Run continuous execution (F5)"
        save_shot(app, win, outdir, "01_branch_transport")
        print(f"OK branch/transport: V rows={visible_v}, stats={stats}")
    finally:
        close_window(win)


def scenario_dcache_memory(app, outdir):
    win = new_window(app)
    try:
        win.load_image(repo_path("build/verify/mb_dmiss.cycle.flat"))
        win.stepn.setValue(160)
        click(app, win.stepn_btn)
        accesses = win.trace.accesses
        assert len(win.backend.dcache()) >= 10
        assert len(accesses) >= 10 and win.trace.last_access is not None
        assert all(
            len(access) == 8
            and access[2] == access[6] == access[7]
            for access in accesses)
        assert "[blocked]" in win.pipeline.board._status
        assert "[paired]" not in win.pipeline.board._status
        held = win.pipeline.board._cells["U"][1]
        assert held.startswith("stall · ") and held != "stall · "

        stalls = set_filter(app, win.trace, "stall")
        assert stalls > 0
        mem_rows = set_filter(app, win.trace, "@")
        assert mem_rows >= 10
        set_filter(app, win.trace, "")
        trace_scroll = win.trace.tbl.verticalScrollBar()
        assert win.trace.tbl.currentRow() < 0
        assert trace_scroll.value() == trace_scroll.maximum()
        assert win.trace.tbl.rowAt(
            win.trace.tbl.viewport().height() - 1
        ) == win.trace.tbl.rowCount() - 1

        select_tab(app, win.tables.tabs, 1)
        assert win.tables.dc.rowCount() >= 10
        assert "miss" in win.tables.dc_lbl.text().lower()
        assert "replay [empty]" in win.tables.dc_lbl.text()
        assert "14 cold fills" in win.tables.dc_lbl.toolTip()
        prefetch_accessible = win.tables.pf.accessibleDescription()
        assert "Linear fetch address 0x" in prefetch_accessible
        assert "Sixteen buffer bytes:" in prefetch_accessible
        assert (
            "Buffer idle" in prefetch_accessible
            or "Buffer decodes at EIP" in prefetch_accessible)
        assert win.tables.dc.accessibleDescription() == "14 populated rows."
        cache_map_accessible = win.tables.dc_map.accessibleDescription()
        assert "14 of 256 cache line slots resident" in cache_map_accessible
        assert "set " in cache_map_accessible and "way " in cache_map_accessible
        cache_line = win.backend.dcache()[0]
        cache_map = win.tables.dc_map
        cache_map.repaint()
        settle(app)
        plot_width = cache_map.width() - cache_map.LX - 4
        hover_y = (
            cache_map.TOP + int(cache_line.way) * cache_map.WAYH
            + cache_map.WAYH // 2)
        hover_points = [
            QPoint(x, hover_y)
            for x in range(cache_map.LX, cache_map.LX + plot_width)
            if cache_map._cell_at(QPoint(x, hover_y))
            == (int(cache_line.set), int(cache_line.way))]
        assert hover_points
        QTest.mouseMove(cache_map, hover_points[len(hover_points) // 2])
        settle(app)
        line_address = (
            (int(cache_line.tag) << 12) | (int(cache_line.set) << 5))
        assert f"set {int(cache_line.set)}" in cache_map.toolTip()
        assert f"way {int(cache_line.way)}" in cache_map.toolTip()
        assert f"line 0x{line_address:08x}" in cache_map.toolTip()
        assert "Hovered set" in cache_map.accessibleDescription()
        hovered_row = win.tables.dc.currentRow()
        assert hovered_row >= 0
        assert win.tables.dc.item(hovered_row, 0).text() == str(cache_line.set)
        assert (
            win.tables.dc.item(hovered_row, 1).text().rstrip("*")
            == str(cache_line.way))
        save_shot(app, win, outdir, "02aa_dcache_map_hover")
        QApplication.sendEvent(cache_map, QEvent(QEvent.Leave))
        settle(app)
        assert not win.tables.dc.selectedIndexes()
        assert win.tables.dc.currentRow() < 0
        assert cache_map.toolTip().startswith("Hover a set/way cell")
        assert "Hovered set" not in cache_map.accessibleDescription()
        cycle_accessible = win.tables.cyc.accessibleDescription()
        assert (
            f"{sum(win.tables.cyc.counts.values())} captured clocks"
            in cycle_accessible)
        assert "IPC " in cycle_accessible and "slow path" in cycle_accessible
        save_shot(app, win, outdir, "02a_dcache_replay")

        select_tab(app, win.tables.tabs, 4)
        assert "instruction-cycles" in win.tables.hot_lbl.text()
        assert "retired span 154/160 captured cycles" in win.tables.hot_lbl.text()
        assert "in-flight tail" in win.tables.hot_lbl.toolTip()
        assert win.tables.hot.horizontalHeaderItem(2).text() == "Σ lat"
        assert win.tables.hot.horizontalHeaderItem(4).text() == "D$ miss/access"
        assert win.tables.hot.horizontalHeaderItem(5).text() == "Σlat bar"
        assert "misses / explicit memory accesses" in (
            win.tables.hot.horizontalHeaderItem(4).toolTip())
        assert "normalized" in win.tables.hot.horizontalHeaderItem(5).toolTip()
        assert all(
            win.tables.hot.item(row, 3).text().endswith("%")
            for row in range(win.tables.hot.rowCount()))

        QTest.keyClick(win, Qt.Key_9, Qt.AltModifier)
        settle(app)
        assert win.tables.tabs.currentIndex() == 8
        assert app.focusWidget() is win.tables.mem.addr_e
        old_addr = win.tables.mem.addr
        win.tables.mem.addr_e.setText("not-hex")
        win.tables.mem._go()
        assert win.tables.mem.addr == old_addr
        assert "#f85149" in win.tables.mem.addr_e.styleSheet()
        assert "invalid" in win.tables.mem.follow_lbl.text()
        assert "Invalid 32-bit" in (
            win.tables.mem.follow_lbl.accessibleDescription())
        access_button = next(b for b in win.tables.mem.findChildren(QPushButton)
                             if b.text() == "→access")
        assert access_button.accessibleName() == (
            "Follow latest data access in physical memory")
        click(app, access_button)
        assert not win.tables.mem.addr_e.styleSheet()
        assert win.tables.mem.follow == "access"
        assert win.tables.mem.addr == (win.trace.last_access[0] & 0xfffffff0)
        assert "following ACCESS" in win.tables.mem.follow_lbl.text()
        dump_accessible = win.tables.mem.dump.accessibleDescription()
        assert f"0x{win.tables.mem.addr:08x}" in dump_accessible
        assert "Access marker at" in dump_accessible
        assert "ASCII" in dump_accessible
        assert win.tables.mem.follow_lbl.accessibleDescription() == (
            win.tables.mem.follow_lbl.text())
        access_page = win.tables.mem.addr
        page_span = win.tables.mem.dump.page_span()
        assert page_span == (
            len(win.tables.mem.dump.data) // 16) * 16
        win.tables.mem.addr_e.setFocus()
        QTest.keyClick(win.tables.mem.addr_e, Qt.Key_PageDown)
        settle(app)
        assert win.tables.mem.addr == access_page + page_span
        assert win.tables.mem.follow is None
        QTest.keyClick(win.tables.mem.addr_e, Qt.Key_PageUp)
        settle(app)
        assert win.tables.mem.addr == access_page
        click(app, access_button)
        assert win.tables.mem.follow == "access"
        save_shot(app, win, outdir, "02_dcache_memory_follow")

        QTest.keyClick(win.tables.mem.addr_e, Qt.Key_0, Qt.AltModifier)
        settle(app)
        assert win.tables.tabs.currentIndex() == 9
        assert app.focusWidget() is win.tables.accmap
        assert win.tables.accmap.focusPolicy() == Qt.StrongFocus
        win.tables.accmap.repaint()
        settle(app)
        assert len(win.tables.accmap._pts) == len(accesses)
        map_image = win.tables.accmap.grab().toImage()
        point_x, point_y, point_i = win.tables.accmap._pts[0]
        expected_point_color = (
            "#e3b341" if accesses[point_i][3] else "#79c0ff")
        assert map_image.pixelColor(point_x + 2, point_y).name() == (
            expected_point_color)
        assert win.tables.accmap.accessibleName() == "Memory access map"
        assert "Left and Right" in win.tables.accmap.accessibleDescription()
        win.tables.accmap.setFocus()
        QTest.keyClick(win.tables.accmap, Qt.Key_Home)
        settle(app)
        assert win.tables.accmap.sel_n == accesses[0][0]
        assert win._pinned_n == accesses[0][0]
        assert f"Selected retirement n={accesses[0][0]}" in (
            win.tables.accmap.accessibleDescription())
        QTest.keyClick(win.tables.accmap, Qt.Key_Right)
        settle(app)
        assert win.tables.accmap.sel_n == accesses[1][0]
        assert win._pinned_n == accesses[1][0]
        assert win.tables.mem._click_hl == (accesses[1][7], accesses[1][4])
        QTest.keyClick(win.tables.accmap, Qt.Key_End)
        settle(app)
        assert win.tables.accmap.sel_n == accesses[-1][0]
        QTest.keyClick(win.tables.accmap, Qt.Key_Return)
        settle(app)
        assert win._pinned_n == accesses[-1][0]
        px, py, idx = win.tables.accmap._pts[len(win.tables.accmap._pts) // 2]
        chosen = accesses[idx]
        click(app, win.tables.accmap, pos=QPoint(px, py))
        assert win.tables.accmap.sel_n == chosen[0]
        assert win._pinned_n == chosen[0]
        assert win.tables.mem._click_hl == (chosen[7], chosen[4])
        assert int(win.trace.tbl.item(win.trace.tbl.currentRow(), 0).text()) == chosen[0]
        save_shot(app, win, outdir, "03_dcache_memmap_drilldown")
        # An untranslated selection must clear, not retain, the prior physical
        # Memory highlight. Exercise the signal path without mutating Trace.
        untranslated = list(chosen)
        untranslated[7] = None
        win.tables.accmap.set_accesses([tuple(untranslated)])
        win.tables.accmap._activate_index(0)
        settle(app)
        assert win.tables.mem._click_hl is None
        assert "untranslated" in win.tables.accmap.accessibleDescription()
        win.tables.accmap.set_accesses(accesses)
        selected_cycle = win.backend.state().core_cyc
        click(app, win.regs.unpin_btn)
        settle(app)
        assert win.backend.state().core_cyc == selected_cycle
        assert win.tables.accmap.sel_n is None
        assert win.tables.mem._click_hl is None
        assert win._pinned_n is None and win.trace.tbl.currentRow() < 0
        win.tables.accmap.set_accesses([])
        assert win.tables.accmap.focusPolicy() == Qt.NoFocus
        print(f"OK D-cache/memory: lines={len(win.backend.dcache())}, "
              f"accesses={len(accesses)}, stalls={stalls}")
    finally:
        close_window(win)


def scenario_x87(app, outdir):
    win = new_window(app)
    try:
        # Compare the complete default RTL enum to the bridge; a newly inserted
        # state must not silently shift Cycles/status/stuck classifications.
        assert verify_fpd_bridge_layout() == 161
        rtl_states = default_rtl_state_names()
        assert rtl_states == [
            win.backend.state_name(index) for index in range(len(rtl_states))]
        assert win.backend.state_name(len(rtl_states)) == "S_?"
        assert set(rtl_states) == set(STATE_STAGE)
        for state_name in rtl_states:
            lane, stage, color, description = stage_of(state_name)
            assert lane in {"U", "V", "FP", "MEM", "FE", "SYS"}
            assert stage and description
            if state_name not in {"S_HALT", "S_HLTWAIT", "S_F00F_HANG"}:
                assert color != C_HALT, (
                    f"active RTL state {state_name} was styled as halt")
        assert stage_of("S_FUTURE_OPTIONAL")[2] == C_SYS

        # The live board must not disappear during a valid slow/system state.
        # Exercise every enum member using a detached state snapshot before the
        # real x87 workload replaces it.
        probe = win.backend.state()
        probe.eip = 0x08048000
        probe.q_pc = 0x08048000
        probe.q_pc2 = 0x08048002
        probe.walk_for_d = 0
        for index, state_name in enumerate(rtl_states):
            probe.state = index
            win.pipeline.board.set_state(probe, win.backend, 32)
            occupied = any(
                stages for stages, _text in win.pipeline.board._cells.values())
            assert occupied == (state_name != "S_RESET"), (
                f"live stage board is blank in {state_name}")
        win.load_image(repo_path("build/verify/mb_fpindep.cycle.flat"))
        win.stepn.setValue(420)
        click(app, win.stepn_btn)
        fp_state = win.backend.state()
        logical_empty = sum(
            ((fp_state.fptag >> ((fp_state.ftop + i) & 7)) & 1) << i
            for i in range(8))
        assert f"empty={logical_empty:02x}" in win.regs.fphdr.text()
        assert "bit i = 1" in win.regs.fphdr.toolTip()
        fp_rows = [r for r in range(win.trace.tbl.rowCount())
                   if win.trace.tbl.item(r, 6).text().lower().startswith("f")]
        assert len(fp_rows) >= 80
        select_table_row(app, win.trace.tbl, fp_rows[-4])
        chosen_n = int(win.trace.tbl.item(fp_rows[-4], 0).text())
        assert win._pinned_n == chosen_n
        assert win.regs.state_banner.text().startswith(
            f"PINNED n={chosen_n} ·")
        assert win.regs.fphdr.text().startswith("logical ctrl=")
        assert win.regs.fphdr.fontMetrics().horizontalAdvance(
            win.regs.fphdr.text()) <= win.regs.fphdr.width()
        chosen_rec = next(
            rec for rec in win.backend.get_retires(chosen_n, 1)
            if rec.n == chosen_n)
        assert win.regs.mode_lbl.text() == (
            f"{'SYS' if chosen_rec.sys_mode else 'USER'}  CPL={chosen_rec.cpl}"
            f"{'  SMM' if chosen_rec.smm_active else ''}")
        assert f"empty={chosen_rec.ftag & 0xff:02x}" in win.regs.fphdr.text()
        assert "already rotated" in win.regs.fphdr.toolTip()
        assert all(tag.text().endswith("·") == bool((chosen_rec.ftag >> i) & 1)
                   for i, (tag, _hexv, _value) in enumerate(win.regs.st_lbls))
        assert all(("empty" in tag.toolTip()) == bool(
                       (chosen_rec.ftag >> i) & 1)
                   for i, (tag, _hexv, _value) in enumerate(win.regs.st_lbls))
        assert any(ins["mnem"].lower().startswith("f")
                   for ins in win.pipeline.konata.plot.insns)

        select_tab(app, win.tables.tabs, 6)
        classes = {win.tables.mix.item(r, 0).text().lower()
                   for r in range(win.tables.mix.rowCount())}
        assert "fp" in classes
        select_tab(app, win.tables.tabs, 7)
        assert sum(win.tables.cyc.counts.values()) >= 400
        assert win.tables.cyc.counts["halt"] == 0
        assert win.tables.cyc.counts["retire"] > 0
        assert win.tables.cyc.counts["I-fill"] > 0
        save_shot(app, win, outdir, "04_x87_pinned")

        click(app, win.step1_btn)
        assert win._pinned_n is None
        assert win.trace.tbl.currentRow() < 0
        assert win.pipeline.konata.plot.sel_row is None
        print(f"OK x87: fp trace rows={len(fp_rows)}, cycle samples="
              f"{sum(win.tables.cyc.counts.values())}")
    finally:
        close_window(win)


def scenario_elf_and_random_branches(app, outdir):
    win = new_window(app)
    try:
        win.load_image(repo_path("build/verify/mb_brrandom.cycle.elf"))
        assert win.image_kind == "ELF"
        assert len(win.image_segments) >= 2
        assert not win.load_e.isEnabled()
        assert win.entry_e.isEnabled() and win.esp_e.isEnabled()
        assert int(win.entry_e.text(), 0) == 0x08048000
        win.stepn.setValue(800)
        click(app, win.stepn_btn)
        stats = win.pipeline.waterfall.stats()
        assert win.backend.retire_count() >= 400
        assert stats["mispred"] >= 50
        assert win.tables.br.rowCount() >= 40
        select_tab(app, win.tables.tabs, 5)
        total_branch_hits = sum(int(win.tables.br.item(r, 3).text())
                                for r in range(win.tables.br.rowCount()))
        outcomes = {int(win.tables.br.item(r, 4).text().split("/", 1)[0])
                    for r in range(win.tables.br.rowCount())}
        assert total_branch_hits >= 40 and outcomes == {0, 1}
        save_shot(app, win, outdir, "05_elf_random_branches")
        print(f"OK ELF/random branches: segments={len(win.image_segments)}, "
              f"retired={win.backend.retire_count()}, mispred={stats['mispred']}")
    finally:
        close_window(win)


def scenario_system_and_switch(app, outdir):
    win = new_window(app)
    try:
        win.load_image(repo_path("verif/sys/tests/ppage/ppage.bin"))
        assert win.sys_cb.isChecked() and not win.soc_cb.isChecked()
        assert win.load_e.text().lower() == "0x000f0000"
        assert all(not field.isEnabled()
                   for field in (win.entry_e, win.load_e, win.esp_e))
        assert all(mode.isEnabled()
                   for mode in (win.cyc_cb, win.sys_cb, win.soc_cb))
        assert "F000:FFF0" in win.entry_e.toolTip()
        assert "top-aligned" in win.load_e.toolTip()
        reset_state = win.backend.state()
        assert reset_state.eip == 0xFFF0 and reset_state.cs_base == 0x000F0000
        assert win.tables.mem.addr == 0x000FFFF0
        assert win.backend.mem_read(win.tables.mem.addr, 4) != b"\0\0\0\0"
        assert (
            win.tables.mem.follow_lbl.text()
            == "EIP off 0000fff0 → phys 000ffff0")
        select_tab(app, win.tables.tabs, 8)
        save_shot(app, win, outdir, "06a_system_reset_vector_memory")
        win.stepn.setValue(1200)
        click(app, win.stepn_btn)
        state = win.backend.state()
        assert not win.backend.is_done() and win.run_btn.isEnabled()
        assert "halted — waiting for interrupt" in (
            win.pipeline.spark._idle_status())
        assert "waiting for interrupt" in (
            win.pipeline.spark.accessibleDescription())
        assert state.sys_mode and "SYS" in win.regs.mode_lbl.text()
        assert win.backend.retire_count() >= 100
        assert len(win.backend.icache()) >= 3 and len(win.backend.dcache()) >= 1
        valid_tlb = [entry for side in (0, 1) for entry in win.backend.tlb(side)
                     if entry.valid]
        assert len(valid_tlb) >= 2
        select_tab(app, win.tables.tabs, 2)
        save_shot(app, win, outdir, "06_system_paging")

        # A pinned system retirement must expose the translation context that
        # made its linked bytes meaningful. The record's source PC and
        # pre-execution bases/CRs are explicitly starred; unavailable fields
        # remain honest instead of inheriting stale live values.
        pin_row = win.trace.tbl.rowCount() - 1
        select_table_row(app, win.trace.tbl, pin_row)
        pin_n = int(win.trace.tbl.item(pin_row, 0).text())
        pin_rec = next(
            rec for rec in win.backend.get_retires(pin_n, 1)
            if rec.n == pin_n)
        assert win._pinned_n == pin_n
        assert win.regs.state_banner.text().startswith(
            f"PINNED n={pin_n} ·")
        assert win.regs.eip_name_lbl.text() == "PC*"
        assert "next EIP is not captured" in win.regs.eip_name_lbl.toolTip()
        assert win.regs.eip_lbl.text() == f"{pin_rec.pc:08x}"
        assert win.regs.seg_base_hdr.text() == "base*"
        assert [
            base.text() for _sel, base, _limit in win.regs.seg_lbls.values()
        ] == [f"{pin_rec.seg_base[i]:08x}" for i in range(6)]
        assert all(limit.text() == "n/a"
                   for _sel, _base, limit in win.regs.seg_lbls.values())
        for name in ("CR0", "CR3", "CR4"):
            assert win.regs.cr_lbls[name].text() == (
                f"{getattr(pin_rec, name.lower()):08x}")
        assert win.regs.cr_lbls["CR2"].text() == "n/a"
        assert win.regs.mode_lbl.text() == (
            f"{'SYS' if pin_rec.sys_mode else 'USER'}  CPL={pin_rec.cpl}"
            f"{'  SMM' if pin_rec.smm_active else ''}")
        assert "pre-execution" in win.regs.mode_lbl.toolTip()
        if win.regs._compact:
            win.regs._compact_tabs.setCurrentIndex(1)
        save_shot(app, win, outdir, "06b_system_pinned_translation")

        # Switching workload classes must discard all system/memory/transient state.
        assert set_filter(app, win.trace, "mov") > 0
        win.tables.mem.follow = None
        win.tables.mem.addr = 0xDEADBEE0
        win.tables.mem._refresh()
        win.load_image(repo_path("build/verify/mb_brloop.cycle.flat"))
        settle(app)
        assert not win.sys_cb.isChecked() and not win.soc_cb.isChecked()
        assert all(field.isEnabled()
                   for field in (win.entry_e, win.load_e, win.esp_e))
        assert not win.backend.state().sys_mode
        assert sum(win.tables.cyc.counts.values()) == 0
        assert win.trace.tbl.rowCount() == 0
        assert not win.trace.filt.text() and not win.trace._tokens
        assert win.trace.accesses == [] and win.tables.mem._click_hl is None
        assert win.tables.mem.follow == "eip"
        assert win.tables.mem.addr == (win.backend.state().eip & 0xFFFFFFF0)
        print("OK system/switch: real-mode placement, clean filter/memory user-mode reload")
    finally:
        close_window(win)


def scenario_stale_soc_fallback(app, outdir):
    image = repo_path("ventium-refs/09-external-cpu-tests/test386.asm/test386.bin")
    win = new_window(app)
    try:
        seen = []

        def dismiss_warning():
            for widget in app.topLevelWidgets():
                if isinstance(widget, QMessageBox):
                    seen.append((widget.windowTitle(), widget.text()))
                    widget.accept()

        timer = QTimer()
        timer.timeout.connect(dismiss_warning)
        timer.start(5)
        win.load_image(image)
        timer.stop()
        settle(app)
        assert seen and seen[0][0] == "SoC model missing"
        assert not win.soc_cb.isChecked() and not win.backend.soc
        assert win.sys_cb.isChecked()
        assert win._has_session() and win.step1_btn.isEnabled()
        save_shot(app, win, outdir, "07_stale_soc_safe_fallback")
        print("OK stale SoC: recoverable warning and core/system fallback (no process abort)")
    finally:
        close_window(win)


def scenario_layout(app, outdir):
    win = new_window(app)
    try:
        win.load_image(repo_path("build/verify/mb_dmiss.cycle.flat"))
        win.do_step(160, False)
        win.resize(900, 620)
        settle(app, 8)
        assert win.width() == 900, (
            f"true-minimum request expanded to {win.width()}px")
        assert win.minimumSizeHint().width() <= 900
        for toolbar in win.findChildren(QToolBar):
            overflow = toolbar.findChild(QToolButton, "qt_toolbar_ext_button")
            assert overflow is None or not overflow.isVisible(), (
                f"{toolbar.windowTitle()} toolbar overflowed at true minimum")
        open_corner = win.program_open_btn.mapTo(
            win, win.program_open_btn.rect().bottomRight())
        assert 0 <= open_corner.x() < win.width()
        assert win.program_open_btn.menu() is win._examples_menu
        assert win.outer_split.sizes()[0] >= 690
        assert win.outer_split.sizes()[1] >= 170
        status_html = win.status_lbl.text()
        assert status_html.index(">cyc</span>") < status_html.index(">eip</span>")
        assert "mb_dmiss.cycle.flat" not in status_html
        assert "mb_dmiss.cycle.flat" in win.status_lbl.toolTip()
        assert "fills" in status_html and "walks" in status_html
        assert "cycle 160" in win.status_lbl.toolTip()
        assert "EIP 0x08048015" in win.status_lbl.toolTip()
        assert "I$ 1/256" in win.status_lbl.toolTip()
        assert win.tables.ic_lbl.displayText() == (
            "I$ 1/256 · 0% · 8K/2w/32B")
        assert not win.tables.ic_lbl.displayText().endswith("…")
        assert win.tables.ic_lbl.fontMetrics().horizontalAdvance(
            win.tables.ic_lbl.displayText()) <= (
                win.tables.ic_lbl.contentsRect().width())
        assert "8 KB, 2-way, 32-byte line, 128 sets" in (
            win.tables.ic_lbl.accessibleDescription())
        QTest.keyClick(win, Qt.Key_2, Qt.AltModifier)
        settle(app)
        assert win.tables.dc_lbl.displayText() == (
            "D$ 14/256 · [empty] · 100% miss")
        assert not win.tables.dc_lbl.displayText().endswith("…")
        assert win.tables.dc_lbl.fontMetrics().horizontalAdvance(
            win.tables.dc_lbl.displayText()) <= (
                win.tables.dc_lbl.contentsRect().width())
        assert "replay [empty] 100% miss (14/14)" in (
            win.tables.dc_lbl.accessibleDescription())
        QTest.keyClick(win, Qt.Key_4, Qt.AltModifier)
        settle(app)
        prefetch = win.tables.pf
        assert win.tables.tabs.currentIndex() == 3
        assert win.tables._compact_navigation
        assert win.tables.analysis_selector.isVisible()
        assert not win.tables.tabs.tabBar().isVisible()
        assert win.tables.analysis_selector.currentText() == "Alt+4 · Prefetch"
        assert win.tables.analysis_selector.count() == 10
        assert all(
            win.tables.analysis_selector.itemData(index, Qt.ToolTipRole)
            == win.tables.tabs.tabToolTip(index)
            for index in range(win.tables.tabs.count()))
        assert app.focusWidget() is win.tables.analysis_selector
        assert "Selected analysis view Prefetch" in (
            win.tables.analysis_selector.accessibleDescription())
        QTest.keyClick(win.tables.analysis_selector, Qt.Key_Up)
        settle(app)
        assert win.tables.tabs.currentIndex() == 2
        assert win.tables.analysis_selector.currentText() == "Alt+3 · TLB"
        QTest.keyClick(win, Qt.Key_4, Qt.AltModifier)
        settle(app)
        assert app.focusWidget() is win.tables.analysis_selector
        assert prefetch._compact
        assert prefetch.info.displayText() == (
            "F:08048015 E:08048015 W:0")
        assert not prefetch.info.displayText().endswith("…")
        for index, byte in enumerate(prefetch.byte_lbls):
            row, column, _row_span, _column_span = (
                prefetch.grid.getItemPosition(
                    prefetch.grid.indexOf(byte)))
            assert row == (index // 8) * 2 + 1
            assert column == index % 8
            assert byte.contentsRect().width() >= (
                byte.fontMetrics().horizontalAdvance(byte.text()))
        assert prefetch.decode.text().startswith(
            "@EIP: lea esi, [0x8049000]")
        assert prefetch.decode.text().endswith("· 6B")
        assert "6 bytes" in prefetch.decode.accessibleDescription()
        save_shot(
            app, win, outdir, "08d_true_minimum_prefetch",
            min_width=900, min_height=620)
        QTest.keyClick(win, Qt.Key_8, Qt.AltModifier)
        settle(app)
        cycles = win.tables.cyc
        assert win.tables.tabs.currentIndex() == 7
        assert win.tables.analysis_selector.currentText() == "Alt+8 · Cycles"
        assert app.focusWidget() is win.tables.analysis_selector
        row_rects = cycles._row_rects(cycles.width())
        assert all(
            rect.left() >= 0 and rect.right() < cycles.width()
            for rect in row_rects)
        assert row_rects[0].width() >= 83  # complete "issue-stall" + bearing
        assert row_rects[1].width() >= 28  # three-digit count
        assert row_rects[3].width() >= 44  # measured "100.0%"
        assert cycles._title_text(160, 57, 57 / 160, True) == (
            "cyc160 · ret57 · IPC.356")
        save_shot(
            app, win, outdir, "08h_true_minimum_cycles",
            min_width=900, min_height=620)
        compact_summaries = (
            (3, win.tables.tlb_lbl,
             "TLB 0 valid · 16 I/D · lin[15:12]"),
            (5, win.tables.hot_lbl,
             "7 PCs · Σlat 291 · span 154/160"),
            (6, win.tables.br_lbl,
             "1 branch · resolved 13/13"),
            (7, win.tables.mix_lbl,
             "57 ret · U30 V27 · V 47%"),
            (0, win.tables.accmap_lbl,
             "Mem ops · offset × retire order"),
        )
        for key, label, expected in compact_summaries:
            QTest.keyClick(
                win, Qt.Key_0 if key == 0 else getattr(Qt, f"Key_{key}"),
                Qt.AltModifier)
            settle(app)
            assert label.displayText() == expected
            assert not label.displayText().endswith("…")
            assert label.fontMetrics().horizontalAdvance(
                label.displayText()) <= label.contentsRect().width()
            assert label.accessibleName()
        QTest.keyClick(win, Qt.Key_1, Qt.AltModifier)
        settle(app)
        assert win.regs.state_banner.text() == "LIVE · current state"
        assert win.regs.state_banner.fullText() == (
            "LIVE · current architectural state")
        assert (
            win.regs.state_banner.fontMetrics().horizontalAdvance(
                win.regs.state_banner.text())
            <= win.regs.state_banner.contentsRect().width())
        assert "most recent model clock" in (
            win.regs.state_banner.accessibleDescription())
        assert win.regs.flags_lbl.wordWrap()
        assert "&nbsp;" not in win.regs.flags_lbl.text()
        assert win.regs._flags_side
        assert win.regs.flags_lbl.height() >= (
            5 * win.regs.flags_lbl.fontMetrics().height())
        flag_corner = win.regs.flags_lbl.mapTo(
            win.regs.int_pane, win.regs.flags_lbl.rect().bottomRight())
        assert flag_corner.x() < win.regs.int_pane.width()
        assert flag_corner.y() < win.regs.int_pane.height()
        assert win.regs.flags_lbl.accessibleName() == "Decoded EFLAGS"
        for flag in ("CF", "PF", "AF", "ZF", "SF", "TF", "IF", "DF", "OF"):
            assert f"{flag}=" in win.regs.flags_lbl.accessibleDescription()
        win.regs._compact_tabs.setCurrentIndex(1)
        settle(app)
        assert win.regs.seg_group.isHidden()
        assert win.regs.control_group.isHidden()
        assert not win.regs.seg_compact_group.isHidden()
        segment_lines = win.regs.seg_compact_lbl.text().splitlines()
        assert len(segment_lines) == 11
        assert segment_lines[0] == "CS 0000 00000000 ffffffff"
        assert segment_lines[-1] == "USER  CPL=0"
        assert win.regs.seg_compact_lbl.height() >= (
            len(segment_lines)
            * win.regs.seg_compact_lbl.fontMetrics().height())
        assert max(
            win.regs.seg_compact_lbl.fontMetrics().horizontalAdvance(line)
            for line in segment_lines
        ) <= win.regs.seg_compact_lbl.contentsRect().width()
        assert "CR4: 00000000" in (
            win.regs.seg_compact_lbl.accessibleDescription())
        save_shot(
            app, win, outdir, "08e_true_minimum_segments",
            min_width=900, min_height=620)
        win.regs._compact_tabs.setCurrentIndex(2)
        settle(app)
        assert win.regs.fp_reg_hdr.isHidden()
        assert win.regs.fp_hex_hdr.isHidden()
        assert win.regs.fp_value_hdr.isHidden()
        assert win.regs.fphdr.height() >= (
            win.regs.fphdr.heightForWidth(win.regs.fphdr.width()))
        assert win.regs.fphdr.height() >= (
            2 * win.regs.fphdr.fontMetrics().height())
        for index, (_tag, raw, decoded) in enumerate(win.regs.st_lbls):
            assert decoded.isHidden()
            assert raw.fontMetrics().horizontalAdvance(raw.text()) <= (
                raw.contentsRect().width())
            assert raw.height() >= raw.fontMetrics().height()
            assert f"Logical ST({index})" in raw.accessibleDescription()
            assert "raw 80-bit value" in raw.accessibleDescription()
            assert "decoded value" in raw.accessibleDescription()
        save_shot(
            app, win, outdir, "08f_true_minimum_x87",
            min_width=900, min_height=620)
        win.regs._compact_tabs.setCurrentIndex(0)
        settle(app)
        QTest.keyClick(win, Qt.Key_9, Qt.AltModifier)
        settle(app)
        memory = win.tables.mem
        assert win.tables.tabs.currentIndex() == 8
        assert memory._navigation_mode == "narrow"
        assert memory.addr_e.width() == 96
        for button in (
                memory.go_btn, memory.eip_btn, memory.esp_btn,
                memory.access_btn):
            assert button.width() >= (
                button.fontMetrics().horizontalAdvance(button.text()) + 8)
        for control in memory._nav_widgets:
            top_left = control.mapTo(memory, control.rect().topLeft())
            bottom_right = control.mapTo(memory, control.rect().bottomRight())
            assert top_left.x() >= 0
            assert bottom_right.x() < memory.width()
        assert memory.follow_lbl.width() >= 90
        assert memory.follow_lbl.wordWrap()
        assert memory.follow_lbl.accessibleDescription() == (
            memory.follow_lbl.text())
        dump = memory.dump
        bytes_per_row, show_ascii, _cw, _hx, _asc, painted_end = (
            dump._layout())
        assert bytes_per_row == 4
        assert show_ascii, (
            f"compact dump lost ASCII at width {dump.width()}: "
            f"{dump._layout()}")
        assert painted_end + 2 <= dump.width()
        assert len(dump.data) == (
            max(8, dump.height() // dump.ROW_H) * bytes_per_row)
        assert dump.page_span() <= len(dump.data)
        assert dump.page_span() >= len(dump.data) - 15
        dump_description = dump.accessibleDescription()
        assert f"0x{dump.base:08x}" in dump_description
        assert "ASCII" in dump_description
        for test_width, expected in (
                (600, (16, True)), (450, (16, False)),
                (350, (8, True)), (250, (8, False)),
                (180, (4, True)), (150, (4, False))):
            layout = dump._layout(test_width)
            assert layout[:2] == expected
            assert layout[-1] + 2 <= test_width
        save_shot(
            app, win, outdir, "08b_true_minimum_memory",
            min_width=900, min_height=620)
        QTest.keyClick(win, Qt.Key_0, Qt.AltModifier)
        settle(app)
        assert win.tables.tabs.currentIndex() == 9
        assert app.focusWidget() is win.tables.accmap
        access_map = win.tables.accmap
        header = access_map._header_text()
        header_font = _mono(8)
        header_font.setBold(True)
        assert QFontMetrics(header_font).horizontalAdvance(header) <= (
            access_map.width() - 8)
        assert not header.endswith("…")
        assert "Δ+20 100%" in header
        assert "effective-address range" in (
            access_map.accessibleDescription())
        assert "dominant stride +0x20 (100 percent)" in (
            access_map.accessibleDescription())
        left, right, top, bottom, tick_count, plot_rect = (
            access_map._plot_geometry())
        assert tick_count == 3
        assert plot_rect.left() >= 0 and plot_rect.right() < access_map.width()
        assert plot_rect.top() >= 0 and plot_rect.bottom() < access_map.height()
        tick_rects = access_map._x_tick_rects(
            access_map.width(), access_map.height(),
            left, right, bottom, tick_count)
        assert all(
            rect.left() >= 0 and rect.right() < access_map.width()
            for _x, rect, _alignment in tick_rects)
        prior_selection = access_map.sel_n
        first_access = access_map.accesses[0]
        access_map.sel_n = first_access[0]
        selected_header = access_map._header_text()
        assert f"@{int(first_access[2]):08x}" in selected_header
        assert QFontMetrics(header_font).horizontalAdvance(
            selected_header) <= access_map.width() - 8
        access_map.sel_n = prior_selection
        access_map._sync_accessible_description()
        save_shot(
            app, win, outdir, "08i_true_minimum_memmap",
            min_width=900, min_height=620)
        QTest.keyClick(win, Qt.Key_1, Qt.AltModifier)
        settle(app)
        assert win.tables.tabs.currentIndex() == 0
        assert app.focusWidget() is win.tables.ic
        cache_map = win.tables.ic_map
        ticks = cache_map._axis_ticks()
        assert [cache_set for cache_set, _x, _rect, _align in ticks] == [
            0, 32, 64, 96, 127]
        assert all(
            rect.left() >= 0 and rect.right() < cache_map.width()
            for _cache_set, _x, rect, _align in ticks)
        assert all(
            ticks[index][2].right() < ticks[index + 1][2].left()
            for index in range(len(ticks) - 1))
        left_cell = cache_map._cell_rect(0, 0)
        right_cell = cache_map._cell_rect(127, 1)
        assert left_cell.left() == cache_map.LX
        assert right_cell.right() < cache_map.width()
        assert cache_map._cell_at(left_cell.center()) == (0, 0)
        assert cache_map._cell_at(right_cell.center()) == (127, 1)
        compact_cells = [
            cache_map._cell_rect(cache_set, 0)
            for cache_set in range(cache_map.SETS)]
        assert all(
            compact_cells[index].right() + 1
            == compact_cells[index + 1].left()
            for index in range(cache_map.SETS - 1))
        assert all(
            cache_map._cell_at(cell.center()) == (cache_set, 0)
            for cache_set, cell in enumerate(compact_cells))
        assert [
            cache_set
            for cache_set, _x, _rect, _align
            in cache_map._axis_ticks(400)
        ] == [*range(0, 128, 16), 127]
        save_shot(
            app, win, outdir, "08a_true_minimum_layout",
            min_width=900, min_height=620)

        win.resize(1280, 800)
        settle(app, 8)
        assert win.width() == 1280, (
            f"compact request expanded to {win.width()}px")
        assert win.minimumSizeHint().width() <= 1280
        assert win.regs._compact and win.regs._compact_tabs.count() == 3
        assert not win.regs._flags_side
        assert "<br>" not in win.regs.flags_lbl.text()
        assert not win.regs.seg_group.isHidden()
        assert not win.regs.control_group.isHidden()
        assert win.regs.seg_compact_group.isHidden()
        assert not win.regs.fp_value_hdr.isHidden()
        assert not win.regs.fp_reg_hdr.isHidden()
        assert not win.regs.fp_hex_hdr.isHidden()
        assert win.regs.fphdr.minimumHeight() == (
            win.regs.fphdr.fontMetrics().height())
        assert all(not decoded.isHidden()
                   for _tag, _raw, decoded in win.regs.st_lbls)
        assert [win.regs._compact_tabs.tabText(i) for i in range(3)] == [
            "Integer", "Segments", "x87"]
        # A selected compact category survives a wide/compact transition.
        win.regs._compact_tabs.setCurrentIndex(2)
        win.resize(1640, 800)
        settle(app, 6)
        assert not win.regs._compact
        assert all(pane.isVisible() for pane, _label, _tip in win.regs._panes)
        assert "mb_dmiss.cycle.flat" in win.status_lbl.text()
        assert win.regs.fp_pane.width() > win.regs.int_pane.width()
        assert win.regs.fp_pane.width() > win.regs.seg_pane.width()
        assert win.regs.flags_lbl.width() >= win.regs.flags_lbl.sizeHint().width()
        assert all(hexv.width() >= hexv.sizeHint().width()
                   for _tag, hexv, _val in win.regs.st_lbls)
        win.resize(1280, 800)
        settle(app, 6)
        assert win.width() == 1280 and win.regs._compact
        assert win.regs._compact_tabs.currentIndex() == 2
        assert not win.tables._compact_navigation
        assert not win.tables.analysis_selector.isVisible()
        assert win.tables.tabs.tabBar().isVisible()
        for toolbar in win.findChildren(QToolBar):
            overflow = toolbar.findChild(QToolButton, "qt_toolbar_ext_button")
            assert overflow is None or not overflow.isVisible(), (
                f"{toolbar.windowTitle()} toolbar overflowed at compact size")
        tab_bar = win.tables.tabs.tabBar()
        assert tab_bar.tabRect(win.tables.tabs.count() - 1).right() < tab_bar.width(), (
            "analysis tabs overflowed at compact size")
        for panel in (win.pipeline, win.trace, win.tables, win.regs):
            top_left = panel.mapTo(win, panel.rect().topLeft())
            bottom_right = panel.mapTo(win, panel.rect().bottomRight())
            assert top_left.x() >= 0 and top_left.y() >= 0
            assert bottom_right.x() < win.width() and bottom_right.y() < win.height()
            assert panel.width() >= 300 and panel.height() >= 180
        assert win.trace.width() >= 690, (
            f"compact layout collapsed the trace to {win.trace.width()}px")
        assert win.trace._compact_columns
        assert win.trace.tbl.columnWidth(5) == 104
        assert win.trace.tbl.columnWidth(7) == 150
        assert win.trace.tbl.columnWidth(6) >= 180, (
            f"compact instruction column is only "
            f"{win.trace.tbl.columnWidth(6)}px")
        assert win.tables.width() >= 570
        QTest.keyClick(win, Qt.Key_4, Qt.AltModifier)
        settle(app)
        assert not win.tables.pf._compact
        row, column, _row_span, _column_span = (
            win.tables.pf.grid.getItemPosition(
                win.tables.pf.grid.indexOf(
                    win.tables.pf.byte_lbls[15])))
        assert (row, column) == (1, 15)
        QTest.keyClick(win, Qt.Key_1, Qt.AltModifier)
        settle(app)
        QTest.keyClick(win, Qt.Key_9, Qt.AltModifier)
        settle(app)
        assert win.tables.mem._navigation_mode == "wide"
        assert (
            win.tables.mem.follow_lbl.fontMetrics().horizontalAdvance(
                win.tables.mem.follow_lbl.text())
            <= win.tables.mem.follow_lbl.contentsRect().width())
        QTest.keyClick(win, Qt.Key_1, Qt.AltModifier)
        settle(app)
        assert win.status_lbl.width() >= 1000 and "IPC" in win.status_lbl.text()
        status_text = win.status_lbl.text()
        assert status_text.index("eip") < status_text.index("ret")
        assert "EIP 0x" in win.status_lbl.toolTip()
        assert "I$ " in win.status_lbl.toolTip()
        assert win.status_lbl.accessibleName() == "Simulation status"
        assert win.status_lbl.accessibleDescription() == win.status_lbl.toolTip()
        assert win.action_hint.accessibleName() == "Last action"
        assert win.action_hint.toolTip() == win.action_hint.text()
        assert win.action_hint.width() <= 260
        assert win.trace.tbl.verticalHeader().defaultSectionSize() == 20
        assert win.trace.tbl.fontMetrics().height() <= 14
        assert (
            win.trace.tbl.verticalHeader().defaultSectionSize()
            - win.trace.tbl.fontMetrics().height()
        ) >= 6

        # Pin state must remain unmistakable on every compact register page.
        # The former badge lived only inside Segments, so x87 could silently
        # look live while it actually showed an old retirement.
        pin_row = win.trace.tbl.rowCount() - 1
        select_table_row(app, win.trace.tbl, pin_row)
        pin_n = int(win.trace.tbl.item(pin_row, 0).text())
        assert win._pinned_n == pin_n
        assert win.regs._compact_tabs.currentIndex() == 2
        assert win.regs.state_banner.isVisible()
        assert win.regs.state_banner.text().startswith(
            f"PINNED n={pin_n} ·")
        save_shot(app, win, outdir, "08a_compact_pinned_state")
        win.resize(900, 620)
        settle(app, 6)
        assert win.regs.unpin_btn.text() == "×"
        assert win.regs.unpin_btn.width() == 24
        assert win.regs.unpin_btn.accessibleName() == "Unpin registers"
        assert win.regs.state_banner.text().startswith(
            f"PIN n={pin_n} · c=")
        assert win.regs.state_banner.fullText().startswith(
            f"PINNED n={pin_n} · retire cyc=")
        assert (
            win.regs.state_banner.fontMetrics().horizontalAdvance(
                win.regs.state_banner.text())
            <= win.regs.state_banner.contentsRect().width())
        assert f"Pinned retirement n={pin_n}" in (
            win.regs.state_banner.accessibleDescription())
        save_shot(
            app, win, outdir, "08c_true_minimum_pinned_state",
            min_width=900, min_height=620)
        win.resize(1280, 800)
        settle(app, 6)
        assert win.regs.unpin_btn.text() == "× Unpin"
        assert win.regs.state_banner.text().startswith(
            f"PINNED n={pin_n} ·")
        pinned_cycle = win.backend.state().core_cyc
        pinned_map = dict(win._assembly_source_map)
        click(app, win.regs.unpin_btn)
        assert win.backend.state().core_cyc == pinned_cycle
        settle(app)
        assert win._pinned_n is None
        assert win.regs._compact_tabs.currentIndex() == 2
        assert win.regs.state_banner.text().startswith("LIVE")
        assert not win.regs.unpin_btn.isVisible()
        assert win.pipeline.konata.plot.playhead is None
        assert win.pipeline.konata.plot.sel_row is None
        assert win.pipeline.konata.plot.sel_pc is None
        assert not win.pipeline.konata.plot._dep_edges
        assert win.trace.tbl.currentRow() < 0
        assert not win.trace.tbl.selectedIndexes()
        assert win.regs.eip_name_lbl.text() == "EIP"
        assert win.regs.eip_lbl.text() == (
            f"{win.backend.state().eip:08x}")
        assert win.regs.fphdr.text().startswith("TOP=")
        assert all(hexv.text() != "n/a"
                   for _tag, hexv, _value in win.regs.st_lbls)
        assert win._assembly_source_map == pinned_map
        assert "linked selection cleared" in win.action_hint.text()
        assert win.action_hint.displayText().endswith("…")
        assert win.action_hint.displayText() != win.action_hint.text()
        assert win.action_hint.toolTip() == win.action_hint.text()
        assert "mb_dmiss.cycle.flat" not in win.status_lbl.text()
        assert "mb_dmiss.cycle.flat" in win.status_lbl.toolTip()
        save_shot(app, win, outdir, "08_compact_layout")
        print(f"OK layout: true minimum=900x620, supported compact="
              f"{win.width()}x{win.height()}, responsive trace/register "
              "columns, all panels in bounds")
    finally:
        close_window(win)


def scenario_fibonacci_uv(app, outdir):
    source = repo_path("tools/pipeviz/examples/fibonacci_uv.c")
    common = [
        "gcc", "-m32", "-march=pentium", "-O2", "-ffreestanding",
        "-fno-pic", "-fno-pie", "-fno-stack-protector", "-nostdlib", "-static",
        "-Wl,--build-id=none", "-Wl,-Ttext=0x08048000", "-Wl,-e,_start",
    ]
    images = {}
    for mode in ("single", "dual"):
        image = os.path.join(outdir, f"fibonacci_{mode}.elf")
        define = "0" if mode == "single" else "1"
        subprocess.run(common + [f"-DDUAL={define}", "-o", image, source],
                       check=True, cwd=ROOT)
        images[mode] = image

    def expected_pair(a, b, count=120):
        for _ in range(count):
            a, b = b, (a + b) & 0xffffffff
        return a, b

    expected = expected_pair(0, 1) + expected_pair(2, 3)
    metrics = {}
    for cycle_mode in (False, True):
        label = "uv" if cycle_mode else "single_issue"
        win = new_window(app)
        try:
            win.cyc_cb.setChecked(cycle_mode)
            win.load_image(images["dual"])
            assert win.cyc_cb.isChecked() == cycle_mode
            win.stepn.setValue(600)
            click(app, win.stepn_btn)
            save_shot(app, win, outdir, f"09_fibonacci_{label}_active")
            win.stepn.setValue(5000)
            click(app, win.stepn_btn)
            assert win.backend.is_done()
            assert "quiesced — program stopped" in (
                win.pipeline.spark._idle_status())
            assert "quiesced — program stopped" in (
                win.pipeline.spark.accessibleDescription())
            assert "program stopped" in win.action_hint.text()
            assert "[DONE]" in win.status_lbl.text()
            assert win.status_lbl.text().index("[DONE]") < (
                win.status_lbl.text().index(">eip</span>"))
            assert "program stopped" in win.status_lbl.toolTip()
            assert win.status_lbl.accessibleDescription() == (
                win.status_lbl.toolTip())
            assert win.reset_btn.isEnabled()
            assert not win.step1_btn.isEnabled() and not win.run_btn.isEnabled()
            assert win.evprev_btn.isEnabled() and win.evnext_btn.isEnabled()
            for control in (
                    win.step1_btn, win.stepi_btn, win.stepn,
                    win.stepn_btn, win.run_btn, win.speed):
                assert "Program has stopped. Use Reset (R)" in (
                    control.toolTip())
                assert control.accessibleDescription() == control.toolTip()
            assert "Program has stopped" not in win.evnext_btn.toolTip()
            if cycle_mode:
                save_shot(
                    app, win, outdir, "09a_fibonacci_uv_quiesced")
            # The global F5 shortcut remains addressable even while its toolbar
            # button is disabled; it must not restart a terminal session.
            win.on_run_toggle()
            assert not win._running and not win.timer.isActive()
            state = win.backend.state()
            stats = win.pipeline.waterfall.stats()
            retired = win.backend.retire_count()
            result_bytes = win.backend.mem_read(0x0804a004, 16)
            results = tuple(int.from_bytes(result_bytes[i:i + 4], "little")
                            for i in range(0, 16, 4))
            assert results == expected
            metrics[cycle_mode] = {
                "cycles": state.core_cyc,
                "retired": retired,
                "ipc": retired / state.core_cyc,
                "pair": 2 * stats["vret"] / retired * 100,
                "vret": stats["vret"],
            }
        finally:
            close_window(win)

    scalar, uv = metrics[False], metrics[True]
    assert scalar["vret"] == 0 and uv["vret"] >= 400
    assert uv["cycles"] <= scalar["cycles"] * 0.82
    assert uv["ipc"] >= scalar["ipc"] * 1.20
    assert uv["pair"] >= 80
    print("OK dual Fibonacci: same 2-chain result; "
          f"single={scalar['cycles']} cyc/{scalar['ipc']:.3f} IPC, "
          f"U-V={uv['cycles']} cyc/{uv['ipc']:.3f} IPC/{uv['pair']:.1f}% paired")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="/tmp/pipeviz_interactions")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    app = QApplication(sys.argv[:1])
    _apply_dark(app)
    for scenario in (
            scenario_startup,
            scenario_branch_transport,
            scenario_dcache_memory,
            scenario_x87,
            scenario_elf_and_random_branches,
            scenario_system_and_switch,
            scenario_stale_soc_fallback,
            scenario_layout,
            scenario_fibonacci_uv):
        scenario(app, args.out)
    print(f"All interactive scenarios passed; screenshots: {args.out}")


if __name__ == "__main__":
    main()
