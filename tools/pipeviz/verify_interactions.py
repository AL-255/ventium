#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Interactive, offscreen acceptance checks for Pipeviz.

Unlike verify_examples.py, this drives real Qt controls with QTest and verifies
the linked-view behavior a user relies on.  Screenshots are written only to the
requested output directory (normally /tmp).
"""
import argparse
import os
import subprocess
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

from PySide6.QtCore import QPoint, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import (QApplication, QMessageBox, QPushButton,
                               QToolBar, QToolButton)

from pipeviz.main import MainWindow, _apply_dark
from pipeviz.pipeline_view import ROW_H


def repo_path(relative):
    path = os.path.join(ROOT, relative)
    if not os.path.isfile(path):
        raise AssertionError(f"required fixture is missing: {path}")
    return path


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


def save_shot(app, win, outdir, name):
    settle(app)
    win.repaint()
    settle(app)
    path = os.path.join(outdir, f"{name}.png")
    pix = win.grab()
    assert pix.width() >= 1280 and pix.height() >= 800
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
    win = new_window(app)
    try:
        assert "no image loaded" in win.status_lbl.text()
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
        for expected in ("F5", "Ctrl+O", "Ctrl+Shift+O", "Ctrl+Q",
                         "Ctrl+0", "R", "."):
            assert expected in shortcuts, f"missing global shortcut {expected}"
        file_actions = {action.text() for action in win._file_menu.actions()}
        assert {"Open program…", "Open snapshot…", "Quit"} <= file_actions
        view_actions = {action.text() for action in win._view_menu.actions()}
        assert {"Reset panel layout", "Show session toolbar",
                "Show transport toolbar", "Show status toolbar"} <= view_actions
        help_actions = {action.text() for action in win._help_menu.actions()}
        assert {"User Guide", "How to read the Pipeline View",
                "Keyboard and mouse shortcuts"} <= help_actions
        assert any(action.shortcut().toString() == "F1"
                   for action in win._help_menu.actions())
        QTest.keyClick(win, Qt.Key_F1)
        settle(app)
        assert win._guide_dialog is not None and win._guide_dialog.isVisible()
        assert win._guide_dialog.index.count() >= 6
        pipeline_row = next(i for i in range(win._guide_dialog.index.count())
                            if win._guide_dialog.index.item(i).text()
                            == "Reading the Pipeline View")
        win._guide_dialog.index.setCurrentRow(pipeline_row)
        settle(app)
        assert "Stage glyphs" in win._guide_dialog.page.toPlainText()
        guide_shot = os.path.join(outdir, "00_help_pipeline_guide.png")
        assert win._guide_dialog.grab().save(guide_shot)
        win._guide_dialog.close()
        save_shot(app, win, outdir, "00_startup")
        print("OK startup/help: disabled transport, shortcuts, indexed Pipeline guide")
    finally:
        close_window(win)


def scenario_branch_transport(app, outdir):
    win = new_window(app)
    try:
        win.load_image(repo_path("build/verify/mb_brloop.cycle.flat"))
        settle(app)
        assert win.image_kind == "flat image" and win._has_session()
        assert win.step1_btn.isEnabled() and not win.sys_cb.isChecked()

        c0 = win.backend.state().core_cyc
        click(app, win.step1_btn)
        assert win.backend.state().core_cyc == c0 + 1
        r0 = win.backend.retire_count()
        click(app, win.stepi_btn)
        assert win.backend.retire_count() > r0

        click(app, win.reset_btn)
        assert win.backend.retire_count() == 0
        win.stepn.setValue(120)
        click(app, win.stepn_btn)
        assert win.backend.state().core_cyc == 120
        assert win.backend.retire_count() >= 180
        stats = win.pipeline.waterfall.stats()
        assert stats["vret"] >= 80 and stats["mispred"] > 0
        assert win.tables.br.rowCount() >= 1 and win.tables.mix.rowCount() >= 2
        assert len(win.pipeline.konata.plot.insns) == win.trace.tbl.rowCount()

        visible_v = set_filter(app, win.trace, "pipe:V")
        assert 50 <= visible_v < win.trace.tbl.rowCount()
        assert f"{visible_v}/{win.trace.tbl.rowCount()} match" == win.trace.match_lbl.text()
        set_filter(app, win.trace, "")

        row = win.trace.tbl.rowCount() - 5
        select_table_row(app, win.trace.tbl, row)
        selected_n = int(win.trace.tbl.item(row, 0).text())
        assert win._pinned_n == selected_n
        assert "PINNED" in win.regs.mode_lbl.text()
        assert win.pipeline.konata.plot.playhead is not None

        plot = win.pipeline.konata.plot
        anchor_row = max(0, plot.sel_row - 4)
        anchor_cyc = plot.insns[anchor_row]["c1"]
        QTest.mouseClick(plot, Qt.LeftButton, Qt.ShiftModifier,
                         QPoint(max(1, plot._x(anchor_cyc) + 2), anchor_row * ROW_H + ROW_H // 2))
        settle(app)
        assert plot.anchor == anchor_cyc

        old_playhead = plot.playhead
        click(app, win.evprev_btn)
        assert plot.playhead is not None and plot.playhead <= old_playhead
        click(app, win.evnext_btn)
        assert plot.playhead is not None

        select_tab(app, win.tables.tabs, 4)
        select_table_row(app, win.tables.hot, 0)
        selected_pc = int(win.tables.hot.item(0, 0).text(), 16)
        assert int(win.trace.tbl.item(win.trace.tbl.currentRow(), 4).text(), 16) == selected_pc

        click(app, win.reset_btn)
        win.speed.setValue(8)
        before = win.backend.state().core_cyc
        click(app, win.run_btn)
        QTest.qWait(100)
        settle(app)
        click(app, win.run_btn)
        assert not win._running and win.backend.state().core_cyc > before
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

        stalls = set_filter(app, win.trace, "stall")
        assert stalls > 0
        mem_rows = set_filter(app, win.trace, "@")
        assert mem_rows >= 10
        set_filter(app, win.trace, "")

        select_tab(app, win.tables.tabs, 1)
        assert win.tables.dc.rowCount() >= 10
        assert "miss" in win.tables.dc_lbl.text().lower()

        select_tab(app, win.tables.tabs, 8)
        access_button = next(b for b in win.tables.mem.findChildren(QPushButton)
                             if b.text() == "→access")
        click(app, access_button)
        assert win.tables.mem.follow == "access"
        assert win.tables.mem.addr == (win.trace.last_access[0] & 0xfffffff0)
        assert "following ACCESS" in win.tables.mem.follow_lbl.text()
        save_shot(app, win, outdir, "02_dcache_memory_follow")

        select_tab(app, win.tables.tabs, 9)
        win.tables.accmap.repaint()
        settle(app)
        assert len(win.tables.accmap._pts) == len(accesses)
        px, py, idx = win.tables.accmap._pts[len(win.tables.accmap._pts) // 2]
        chosen = accesses[idx]
        click(app, win.tables.accmap, pos=QPoint(px, py))
        assert win.tables.accmap.sel_n == chosen[0]
        assert win._pinned_n == chosen[0]
        assert win.tables.mem._click_hl == (chosen[2], chosen[4])
        assert int(win.trace.tbl.item(win.trace.tbl.currentRow(), 0).text()) == chosen[0]
        save_shot(app, win, outdir, "03_dcache_memmap_drilldown")
        print(f"OK D-cache/memory: lines={len(win.backend.dcache())}, "
              f"accesses={len(accesses)}, stalls={stalls}")
    finally:
        close_window(win)


def scenario_x87(app, outdir):
    win = new_window(app)
    try:
        win.load_image(repo_path("build/verify/mb_fpindep.cycle.flat"))
        win.stepn.setValue(420)
        click(app, win.stepn_btn)
        fp_rows = [r for r in range(win.trace.tbl.rowCount())
                   if win.trace.tbl.item(r, 6).text().lower().startswith("f")]
        assert len(fp_rows) >= 80
        select_table_row(app, win.trace.tbl, fp_rows[-4])
        assert win._pinned_n == int(win.trace.tbl.item(fp_rows[-4], 0).text())
        assert "PINNED" in win.regs.mode_lbl.text()
        assert win.regs.fphdr.text().startswith("pin ctrl=")
        assert any(ins["mnem"].lower().startswith("f")
                   for ins in win.pipeline.konata.plot.insns)

        select_tab(app, win.tables.tabs, 6)
        classes = {win.tables.mix.item(r, 0).text().lower()
                   for r in range(win.tables.mix.rowCount())}
        assert "fp" in classes
        select_tab(app, win.tables.tabs, 7)
        assert sum(win.tables.cyc.counts.values()) >= 400
        save_shot(app, win, outdir, "04_x87_pinned")

        click(app, win.step1_btn)
        assert win._pinned_n is None and "PINNED" not in win.regs.mode_lbl.text()
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
        outcomes = {int(win.tables.br.item(r, 4).text())
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
        win.stepn.setValue(1200)
        click(app, win.stepn_btn)
        state = win.backend.state()
        assert state.sys_mode and "SYS" in win.regs.mode_lbl.text()
        assert win.backend.retire_count() >= 100
        assert len(win.backend.icache()) >= 3 and len(win.backend.dcache()) >= 1
        valid_tlb = [entry for side in (0, 1) for entry in win.backend.tlb(side)
                     if entry.valid]
        assert len(valid_tlb) >= 2
        select_tab(app, win.tables.tabs, 2)
        save_shot(app, win, outdir, "06_system_paging")

        # Switching workload classes must discard all system/memory/transient state.
        win.load_image(repo_path("build/verify/mb_brloop.cycle.flat"))
        settle(app)
        assert not win.sys_cb.isChecked() and not win.soc_cb.isChecked()
        assert not win.backend.state().sys_mode
        assert win.trace.tbl.rowCount() == 0
        assert win.trace.accesses == [] and win.tables.mem._click_hl is None
        print("OK system/switch: real-mode placement, SYS state, clean user-mode reload")
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
        win.resize(1280, 800)
        settle(app, 8)
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
        assert win.trace.tbl.verticalHeader().defaultSectionSize() == 22
        save_shot(app, win, outdir, "08_compact_layout")
        print(f"OK layout: effective compact window={win.width()}x{win.height()}, all panels in bounds")
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
