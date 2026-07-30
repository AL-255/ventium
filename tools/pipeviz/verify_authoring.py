#!/usr/bin/env python3
"""End-to-end acceptance checks for the assembly and C workbenches."""
import argparse
import os
from pathlib import Path
import re
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import Qt
from PySide6.QtGui import QCloseEvent, QGuiApplication, QTextCursor
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QFileDialog, QMessageBox

import pipeviz.source_view as source_module
from pipeviz.isa_catalog import CATALOG, MNEMONICS, instruction_info
from pipeviz.main import MainWindow, _apply_dark, _read_program
from pipeviz.source_view import (
    _ASM_TEMPLATE, _C_TEMPLATE, BuildFailure, assemble_source, compile_c_source,
)

_C_ARRAY_TEMPLATE = """volatile unsigned values[256];

int main(void)
{
    for (unsigned i = 0; i < 256; ++i)
        values[i] = 0;
    return (int)values[255];
}
"""

_C_X87_TEMPLATE = """/* Exercise the Pentium x87 path through C and editable assembly. */
volatile float result;

int main(void)
{
    volatile float a = 1.5f;
    volatile float b = 2.25f;
    result = a + b;
    return (int)result;
}
"""


def settle(app):
    app.processEvents()
    QTest.qWait(15)
    app.processEvents()


def save(widget, outdir, name):
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, name + ".png")
    pix = widget.grab()
    assert pix.width() > 0 and pix.height() > 0
    assert pix.save(path), path


def format_colors(editor, line):
    block = editor.document().findBlockByNumber(line - 1)
    return {
        span.format.foreground().color().name()
        for span in block.layout().formats()
        if span.format.foreground().style() != Qt.NoBrush
    }


def format_color_at(editor, line, column):
    block = editor.document().findBlockByNumber(line - 1)
    for span in block.layout().formats():
        if span.start <= column < span.start + span.length:
            color = span.format.foreground().color()
            if span.format.foreground().style() != Qt.NoBrush:
                return color.name()
    return None


def select_trace_pc(win, pc):
    target = f"{int(pc):08x}"
    for row in range(win.trace.tbl.rowCount()):
        if win.trace.tbl.item(row, 4).text() == target:
            win.trace.tbl.setCurrentCell(row, 0)
            return row
    raise AssertionError(f"PC {target} is absent from Trace")


def run_to_stop(win, clocks=4000):
    win.do_step(clocks, False)
    assert win.backend.is_done(), (
        win.backend.state_name(win.backend.state().state),
        win.backend.state().core_cyc,
    )


def verify_catalog():
    assert len(CATALOG) == len(MNEMONICS) >= 250
    for info in CATALOG:
        assert info.signature.split()[0] == info.mnemonic
        assert info.description.strip()
        assert info.pipe in {"UV", "PU", "PV", "NP", "FP", "SYS"}
        assert info.stages
        assert set(info.stages) <= {"F", "D", "X", "M", "W", "S", "FP", "=", "!", "."}
        assert info.latency.strip()
        assert info.availability.strip()
    required = {
        "aaa", "adc", "add", "bound", "bswap", "bt", "call", "cmpxchg8b",
        "cpuid", "endbr32", "f2xm1", "fadd", "fbld", "fldenv", "fprem1",
        "frstor", "fsincos", "lgdt", "lss", "rdtsc", "repnz", "rsm",
        "setnz", "shrd", "ud2", "wbinvd", "xadd",
    }
    assert required <= MNEMONICS
    assert not {"movdqa", "pxor", "addps", "syscall"} & MNEMONICS
    assert instruction_info("add").pipe == "UV"
    assert instruction_info("adc").pipe == "PU"
    assert instruction_info("jnz").pipe == "PV"
    assert instruction_info("fdiv").pipe == "FP"
    assert "VEN_TRANSCENDENTAL" in instruction_info("fsin").availability

    # Keep completion coupled to the actual decoder rather than only guarding a
    # hand-picked count. Any new internal instruction family must either map to
    # an advertised mnemonic here or make this regression fail conspicuously.
    decoder = (
        Path(__file__).resolve().parents[2] / "rtl/core/decode_stages.sv"
    ).read_text(encoding="utf-8")
    family_roots = {
        "FX": {"AR": "fadd", "FLDCONST": "fld1"},
        "SYS": {
            "LCALL": "call", "LJMP": "jmp",
            "MOVCR": "mov", "MOVDR": "mov", "MOVSREG": "mov",
        },
        "K": {
            "ALU": "add", "BITSCAN": "bsf", "BITTEST": "bt",
            "CONV": "cwde", "CTRL": "call", "CX8B": "cmpxchg8b",
            "EXT": "movzx", "IMUL2": "imul", "MULDIV": "mul",
            "SETCC": "setz", "SHIFT": "shl", "SHLDRD": "shld",
            "STKMISC": "pushf", "STR": "movs",
        },
        "SM": {
            "ENTER": "enter", "LAHF": "lahf", "LEAVE": "leave",
            "POPA": "popa", "POPF": "popf", "PUSHA": "pusha",
            "PUSHF": "pushf", "SAHF": "sahf",
        },
        "CT": {
            "CALLIND": "call", "CALLREL": "call", "JECXZ": "jecxz",
            "JMPIND": "jmp", "LOOP": "loop", "LOOPE": "loope",
            "LOOPNE": "loopne", "RETN": "retn", "RETN_IMM": "retn",
        },
        "ST": {
            "CMPS": "cmps", "INS": "ins", "LODS": "lods",
            "MOVS": "movs", "OUTS": "outs", "SCAS": "scas",
            "STOS": "stos",
        },
    }
    for prefix, exceptions in family_roots.items():
        tokens = set(re.findall(
            rf"\b{prefix}_([A-Z][A-Z0-9_]*)\b", decoder)) - {"NONE"}
        for token in tokens:
            root = token.split("_", 1)[0]
            mnemonic = exceptions.get(token, exceptions.get(root, root.lower()))
            assert mnemonic in MNEMONICS, (
                f"decoder family {prefix}_{token} is absent from completion "
                f"(expected mnemonic {mnemonic!r})")
    print(f"OK ISA catalogue: {len(CATALOG)} completion mnemonics, "
          "all current decoder families, and P5 pipeline/mode metadata present")


def verify_toolchain():
    try:
        assemble_source("")
    except BuildFailure as error:
        assert "empty" in str(error).lower()
    else:
        raise AssertionError("empty assembly was not rejected clearly")
    assembled = assemble_source(_ASM_TEMPLATE)
    segments, entry, kind = _read_program(assembled.elf_path)
    assert kind == "ELF" and entry == 0x08048000
    assert segments and len(assembled.source_map) >= 6
    snippet = assemble_source("mov eax, 7\n")
    assert set(snippet.source_map.values()) == {1}
    generated, _log = compile_c_source(_C_TEMPLATE)
    assert ".intel_syntax noprefix" in generated
    assert "_start:" in generated and "call main" in generated
    compiled = assemble_source(generated)
    assert len(compiled.source_map) >= 10
    array_assembly, _log = compile_c_source(_C_ARRAY_TEMPLATE)
    assert "memset" not in array_assembly
    assert "_start:" in array_assembly
    assert len(assemble_source(array_assembly).source_map) >= 10
    try:
        compile_c_source(
            "int main(void)\n{\n    return unavailable_runtime();\n}\n")
    except BuildFailure as error:
        assert error.line == 3
        assert "implicit declaration" in str(error)
    else:
        raise AssertionError("implicit function call was not rejected in C")
    try:
        compile_c_source(
            "#include <pipeviz_header_that_does_not_exist.h>\n"
            "int main(void) { return 0; }\n")
    except BuildFailure as error:
        assert error.line == 1
        assert "fatal error" in str(error).lower()
    else:
        raise AssertionError("missing C header was not rejected")
    print("OK toolchain: GNU as/ld ELF + DWARF source map; "
          "self-contained freestanding C → Intel assembly → ELF")


def scenario(app, outdir):
    win = MainWindow()
    win.resize(1500, 920)
    win.show()
    settle(app)
    try:
        assert [win.workspace.tabText(i) for i in range(3)] == [
            "Visualizer", "Assembly", "C"]
        assert [action.shortcut().toString()
                for action in win._workspace_actions] == ["Alt+V", "Alt+A", "Alt+C"]
        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        toolbars = (
            win.session_toolbar, win.transport_toolbar, win.status_toolbar)
        assert all(toolbar.isHidden() for toolbar in toolbars)
        assert win.open_action.text() == "Open assembly source…"
        assert win.open_action.shortcut().toString() == "Ctrl+O"
        assert win.save_source_action.isEnabled()
        assert win.save_source_action.shortcut().toString() == "Ctrl+S"
        assert win.assembly.editor.accessibleName() == "Assembly source editor"
        assert win.assembly.editor.completion.list.accessibleName()
        assert win.assembly.diagnostics.accessibleName()
        assert win.pipeline.board.accessibleName() == "Live pipeline stage board"
        assert "clicked" in win.pipeline.board.accessibleDescription()
        assert "Ctrl+Enter" in win.assembly.run_btn.toolTip()

        editor = win.assembly.editor
        editor.clear()
        editor.setFocus()
        QTest.keyClicks(editor, "i r . [ ] /")
        settle(app)
        assert editor.toPlainText() == "i r . [ ] /"
        assert win.workspace.tabText(1) == "Assembly *"
        assert all(not action.isEnabled()
                   for action in win._transport_shortcut_actions)
        close_event = QCloseEvent()
        real_warning = QMessageBox.warning
        QMessageBox.warning = staticmethod(
            lambda *_args, **_kwargs: QMessageBox.Cancel)
        try:
            win.closeEvent(close_event)
        finally:
            QMessageBox.warning = real_warning
        assert not close_event.isAccepted()
        assert win.isVisible()
        opened = []
        real_open_source = win.assembly.open_source
        win.assembly.open_source = lambda: opened.append("assembly")
        try:
            QTest.keyClick(editor, Qt.Key_O, Qt.ControlModifier)
            settle(app)
        finally:
            win.assembly.open_source = real_open_source
        assert opened == ["assembly"]
        dirty_before_cancelled_open = editor.toPlainText()
        real_open_dialog = QFileDialog.getOpenFileName
        real_warning = QMessageBox.warning
        QFileDialog.getOpenFileName = staticmethod(
            lambda *_args, **_kwargs: ("", ""))
        QMessageBox.warning = staticmethod(
            lambda *_args, **_kwargs: (_ for _ in ()).throw(
                AssertionError("cancelled file chooser prompted for discard")))
        try:
            assert not win.assembly.open_source()
        finally:
            QFileDialog.getOpenFileName = staticmethod(real_open_dialog)
            QMessageBox.warning = real_warning
        assert editor.toPlainText() == dirty_before_cancelled_open
        os.makedirs(outdir, exist_ok=True)
        blocked_artifacts = Path(outdir) / "not-a-build-directory"
        blocked_artifacts.write_text("regular file", encoding="utf-8")
        real_generated_dir = source_module._GENERATED_DIR
        source_module._GENERATED_DIR = blocked_artifacts
        try:
            try:
                assemble_source("mov eax, 1\n")
            except BuildFailure as error:
                assert "build directory" in str(error)
            else:
                raise AssertionError("invalid build directory was not diagnosed")
        finally:
            source_module._GENERATED_DIR = real_generated_dir
        assert not win._has_session()
        save_path = os.path.join(outdir, "keyboard-saved.s")
        win.assembly._path = save_path
        QTest.keyClick(editor, Qt.Key_S, Qt.ControlModifier)
        settle(app)
        assert Path(save_path).read_text(encoding="utf-8") == "i r . [ ] /"
        assert not editor.document().isModified()
        assert win.workspace.tabText(1) == "Assembly"
        assembly_bare_path = os.path.join(outdir, "assembly-no-extension")
        real_save_dialog = QFileDialog.getSaveFileName
        QFileDialog.getSaveFileName = staticmethod(
            lambda *_args, **_kwargs:
            (assembly_bare_path, "Assembly (*.s)"))
        try:
            assert win.assembly.save_source(save_as=True)
        finally:
            QFileDialog.getSaveFileName = staticmethod(real_save_dialog)
        assert win.assembly._path == assembly_bare_path + ".s"
        assert Path(assembly_bare_path + ".s").read_text(
            encoding="utf-8") == "i r . [ ] /"
        assert "Saved assembly-no-extension.s" in win.action_hint.text()
        dropped_assembly = Path(outdir) / "dropped-source.S"
        dropped_assembly.write_text(
            ".intel_syntax noprefix\nmov eax, 17\n", encoding="utf-8")
        assert win._load_dropped_path(str(dropped_assembly))
        assert win.workspace.currentWidget() is win.assembly
        assert editor.toPlainText().endswith("mov eax, 17\n")
        assert win.assembly._path == str(dropped_assembly)
        assert win.assembly._last_dir == str(Path(outdir).resolve())
        assert not win._has_session()
        win.assembly.new_template()
        assert win.assembly._last_dir == str(Path(outdir).resolve())
        win.assembly.editor.highlighter.rehighlight()
        settle(app)
        assert "#79c0ff" in format_colors(editor, 5)  # mov mnemonic
        assert "#56d364" in format_colors(editor, 5)  # eax register
        assembly_literal = '.asciz "https://example.test/#literal" # comment'
        editor.setPlainText(assembly_literal)
        editor.highlighter.rehighlight()
        settle(app)
        assert format_color_at(
            editor, 1, assembly_literal.index("//")) == "#a5d6ff"
        assert format_color_at(
            editor, 1, assembly_literal.rindex("#")) == "#6e7681"
        structural_probe = "eax: add eax, 1\n.int 3"
        editor.setPlainText(structural_probe)
        editor.highlighter.rehighlight()
        settle(app)
        assert format_color_at(editor, 1, 0) == "#d2a8ff"  # label, not EAX
        assert format_color_at(editor, 1, 5) == "#79c0ff"  # ADD opcode
        assert format_color_at(editor, 2, 1) == "#ff7b72"  # directive, not INT
        editor.document().setModified(False)
        assert win.assembly.new_template()
        editor.setFocus()
        QTest.keyClick(editor, Qt.Key_F, Qt.ControlModifier)
        settle(app)
        assert win.assembly.find_bar.isVisible()
        QTest.keyClicks(win.assembly.find_bar.query, "mov")
        settle(app)
        assert win.assembly.find_bar.count.text() == "1 / 2"
        assert editor.textCursor().selectedText().lower() == "mov"
        assert editor.textCursor().blockNumber() + 1 == 5
        QTest.keyClick(win.assembly.find_bar.query, Qt.Key_Return)
        settle(app)
        assert win.assembly.find_bar.count.text() == "2 / 2"
        assert editor.textCursor().blockNumber() + 1 == 6
        save(win, outdir, "00b_assembly_find")
        QTest.keyClick(win.assembly.find_bar.query, Qt.Key_Escape)
        settle(app)
        assert not win.assembly.find_bar.isVisible()
        assert not editor._find_ranges
        save(win, outdir, "00_assembly_workbench")
        win.resize(1280, 800)
        settle(app)
        for button in (
                win.assembly.template_btn, win.assembly.open_btn,
                win.assembly.save_btn, win.assembly.complete_btn,
                win.assembly.build_btn, win.assembly.run_btn):
            corner = button.mapTo(win, button.rect().bottomRight())
            assert 0 <= corner.x() < win.width()
            assert 0 <= corner.y() < win.height()
        assert editor.height() >= 550
        save(win, outdir, "00a_assembly_compact")
        win.resize(1500, 920)
        settle(app)

        # Automatic completion is scoped to the opcode slot: it must not
        # interrupt ordinary operand/comment typing.
        editor.setPlainText("mov e")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        QTest.keyClicks(editor, "ax")
        settle(app)
        assert editor.toPlainText() == "mov eax"
        assert not editor.completion.isVisible()
        editor.setPlainText("# ad")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        QTest.keyClicks(editor, "d")
        settle(app)
        assert not editor.completion.isVisible()

        # Ctrl+Space / Complete remains a full catalogue reference even when
        # the cursor is not currently in an opcode token.
        editor.setPlainText(".intel_syntax noprefix")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        QTest.keyClick(editor, Qt.Key_Space, Qt.ControlModifier)
        settle(app)
        assert editor.completion.isVisible()
        assert editor.completion.parent() is editor
        screen = (
            QGuiApplication.screenAt(editor.completion.frameGeometry().center())
            or QGuiApplication.primaryScreen())
        assert screen is not None
        assert screen.availableGeometry().contains(
            editor.completion.frameGeometry())
        assert editor.completion.list.count() == len(CATALOG)
        names = {
            editor.completion.list.item(i).data(Qt.UserRole).mnemonic
            for i in range(editor.completion.list.count())
        }
        assert {"add", "adc", "fdiv", "cmpxchg8b", "fsincos"} <= names
        add_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic == "add")
        editor.completion.list.setCurrentRow(add_row)
        settle(app)
        assert editor.completion.info.preview.info.mnemonic == "add"
        assert editor.completion.info.description.text()
        assert editor.completion.info.preview.info.stages == ("F", "D", "X")
        assert editor.completion.info.availability.text() == "Availability · user"
        assert "cycle" not in editor.completion.info.availability.text()
        save(editor.completion, outdir, "01_opcode_completion_popup")
        reference_source = editor.toPlainText()
        editor.completion.accept_current()
        assert editor.toPlainText() == reference_source
        assert "reference-only" in win.assembly.status.text()
        editor.setPlainText(".loop: adc")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        cursor.movePosition(QTextCursor.PreviousCharacter)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        add_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic == "add")
        editor.completion.list.setCurrentRow(add_row)
        editor.completion.accept_current()
        assert editor.toPlainText() == ".loop: add "

        # GNU as uses ';' as a statement separator. Completion and the persistent
        # preview must understand the second opcode rather than grey it as a
        # NASM-style comment.
        editor.setPlainText("mov eax, 1; ad")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        assert editor.completion.list.count() == 2  # adc, add
        editor.completion.move_selection(1)
        editor.completion.accept_current()
        assert editor.toPlainText() == "mov eax, 1; add "
        settle(app)
        assert win.assembly.info.signature.text().startswith("add ")

        # Statement scanning is lexical, not a raw split/search: comment markers
        # and semicolons inside data strings neither trigger nor suppress opcode
        # completion in the real statement that follows.
        quoted_statements = (
            '.asciz "https://example.test/#payload;ad"; ad')
        editor.setPlainText(quoted_statements)
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        assert editor.completion.list.count() == 2  # adc, add
        editor.completion.move_selection(1)
        editor.completion.accept_current()
        assert editor.toPlainText().endswith("; add ")
        settle(app)
        assert win.assembly.info.signature.text().startswith("add ")

        inside_string = '.asciz "payload;add"'
        editor.setPlainText(inside_string)
        cursor = editor.textCursor()
        cursor.setPosition(inside_string.index("add") + 3)
        editor.setTextCursor(cursor)
        assert not editor.request_completion()
        settle(app)
        assert win.assembly.info.preview.info is None

        editor.setPlainText(".loop:")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        QTest.keyClick(editor, Qt.Key_Return)
        assert editor.toPlainText() == ".loop:\n    "

        # A syntax error is line-linked and never starts a backend session.
        editor.setPlainText(
            ".intel_syntax noprefix\n.section .text\n.global _start\n_start:\n"
            "    frobnicate eax\n")
        assert win.assembly.build(False) is None
        assert editor._error_line == 5
        assert "Error" in win.assembly.diagnostics.toPlainText()
        assert not win._has_session()
        editor.insertPlainText(" ")
        assert editor._error_line is None
        assert not win.assembly.diagnostics.toPlainText()
        assert "#8b949e" in win.assembly.diagnostics.styleSheet()
        editor.document().setModified(False)

        # Assemble and run the editable template. The result (1+...+10) proves
        # execution used the authored bytes, not a demo fallback.
        win.assembly.new_template()
        editor.appendPlainText("# intentionally unsaved authoring session")
        assert win.workspace.tabText(1) == "Assembly *"
        result = win.assembly.build(True)
        settle(app)
        assert result is not None
        assert win.workspace.currentWidget() is win.visualizer_tab
        assert win.open_action.text() == "Open program…"
        assert not win.save_source_action.isEnabled()
        assert all(not toolbar.isHidden() for toolbar in toolbars)
        assert all(action.isEnabled()
                   for action in win._transport_shortcut_actions)
        assert win.image_kind == "ELF"
        assert win._assembly_source_map == result.source_map
        assert win.assembly.mapping_current
        assert win.workspace.tabText(1) == "Assembly *"

        # The live stage board is the actual in-flight view, not merely retired
        # history. Advance through the first I-fill so both current U/V issue
        # slots are visible, then click each occupied lane and require its exact
        # authored PC/line without relying on a retirement record.
        board = win.pipeline.board
        assert not board._lane_rects  # reset itself is not an in-flight instruction
        win.do_step(1, False)
        assert not board._lane_rects  # hit targets wait for the matching paint frame
        settle(app)
        assert board._lane_rects, (
            board.isVisible(), board.size(), board._cells, board._lane_pcs)
        win.do_step(1, False)
        assert not board._lane_rects  # never retain a previous frame's PC hit target
        settle(app)
        win.do_step(7, False)
        settle(app)
        assert set(board._lane_pcs) >= {"U", "V"}
        assert board._lane_pcs["U"] in result.source_map
        assert board._lane_pcs["V"] in result.source_map
        live_lines = {}
        for lane in ("U", "V"):
            rect = next(
                rect for rect, cell_lane, _pc in board._lane_rects
                if cell_lane == lane)
            QTest.mouseMove(board, rect.center())
            settle(app)
            assert "in-flight instruction" in board.toolTip()
            QTest.mouseClick(board, Qt.LeftButton, Qt.NoModifier, rect.center())
            settle(app)
            line = result.source_map[board._lane_pcs[lane]]
            live_lines[lane] = line
            assert editor._execution_line == line
            assert f"In-flight {lane}-lane" in editor._execution_tip
            assert win.workspace.tabText(1) == f"Assembly * · L{line}"
            assert f"Assembly line {line}" in win.action_hint.text()
        assert live_lines["U"] != live_lines["V"]
        save(win, outdir, "02a_live_uv_source_link")

        win.on_run_toggle()
        assert win._running and win.timer.isActive()
        close_event = QCloseEvent()
        real_warning = QMessageBox.warning
        QMessageBox.warning = staticmethod(
            lambda *_args, **_kwargs: QMessageBox.Cancel)
        try:
            win.closeEvent(close_event)
        finally:
            QMessageBox.warning = real_warning
        assert not close_event.isAccepted()
        assert win._running and win.timer.isActive()
        win.stop_run()
        run_to_stop(win)
        assert win.backend.state().gpr[0] == 55

        # A normal terminal HLT remains a visible, source-linked live cell; it
        # must not make the stage board blank just when the experiment finishes.
        settle(app)
        assert win.backend.state_name(win.backend.state().state) == "S_HALT"
        board = win.pipeline.board
        assert "mispredict-bubble" not in board._status
        assert win.pipeline.stats()["mispred"] < 50
        assert not any(win.pipeline.spark.ev[-256:]), (
            "latched hazard counters created events during terminal HLT")
        assert board._lane_pcs["U"] in result.source_map
        halt_rect = next(
            rect for rect, lane, _pc in board._lane_rects if lane == "U")
        QTest.mouseClick(
            board, Qt.LeftButton, Qt.NoModifier, halt_rect.center())
        settle(app)
        halt_line = result.source_map[board._lane_pcs["U"]]
        assert editor._execution_line == halt_line
        assert editor.document().findBlockByNumber(
            halt_line - 1).text().strip() == "hlt"
        save(win, outdir, "02b_terminal_hlt_source_link")

        mapped_pcs = set(win._assembly_source_map)
        row = next(
            row for row in range(win.trace.tbl.rowCount())
            if int(win.trace.tbl.item(row, 4).text(), 16) in mapped_pcs)
        pc = int(win.trace.tbl.item(row, 4).text(), 16)
        win.trace.tbl.setCurrentCell(row, 0)
        settle(app)
        line = result.source_map[pc]
        assert editor._execution_line == line
        assert win.workspace.tabText(1) == f"Assembly * · L{line}"

        # Exact U/V row identity survives round-tripping through Trace, and each
        # row maps to its own source line even when U and V share a cycle.
        plot = win.pipeline.konata.plot
        pair = next(
            (i for i in range(len(plot.insns) - 1)
             if plot.insns[i]["c1"] == plot.insns[i + 1]["c1"]
             and plot.insns[i]["pipe"] == "U"
             and plot.insns[i + 1]["pipe"] == "V"),
            None)
        assert pair is not None
        for index in (pair, pair + 1):
            plot.select_row(index)
            settle(app)
            chosen = plot.insns[index]
            assert plot.sel_row == index
            assert win._pinned_n == chosen["n"]
            chosen_line = result.source_map[chosen["pc"]]
            assert editor._execution_line == chosen_line
            assert win.workspace.tabText(1) == f"Assembly * · L{chosen_line}"

        # A rejected replacement load must leave the live backend, authored
        # bytes, source map, marker, and tab label as one coherent old session.
        old_backend = win.backend
        old_bytes = win.image_bytes
        old_map = dict(win._assembly_source_map)
        old_line = editor._execution_line
        old_tab = win.workspace.tabText(1)
        candidate = assemble_source("mov eax, 7\n")
        real_reset = win.on_reset
        win.on_reset = lambda: False
        try:
            assert not win.load_image(candidate.elf_path)
        finally:
            win.on_reset = real_reset
        assert win.backend is old_backend
        assert win.image_bytes == old_bytes
        assert win._assembly_source_map == old_map
        assert editor._execution_line == old_line
        assert win.workspace.tabText(1) == old_tab

        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        save(win, outdir, "02_assembly_source_link")
        editor.appendPlainText("# edited after build")
        assert not win.assembly.mapping_current
        assert "assemble again" in win.assembly.status.text()
        assert editor._execution_line is None
        assert not win._assembly_source_map
        assert win.workspace.tabText(1) == "Assembly *"
        select_trace_pc(win, pc)
        settle(app)
        assert editor._execution_line is None  # stale maps never retain/move a marker
        assert win.workspace.tabText(1) == "Assembly *"
        dirty_source = editor.toPlainText()
        real_warning = QMessageBox.warning
        QMessageBox.warning = staticmethod(
            lambda *_args, **_kwargs: QMessageBox.Cancel)
        try:
            assert not win.assembly.set_source("hlt\n", "cancelled replacement")
        finally:
            QMessageBox.warning = real_warning
        assert editor.toPlainText() == dirty_source
        assert win.workspace.tabText(1) == "Assembly *"
        win.assembly._path = os.path.join(outdir, "edited-after-build.s")
        assert win.assembly.save_source()
        assert win.workspace.tabText(1) == "Assembly"
        bom_assembly_path = Path(outdir) / "utf8-bom.s"
        bom_assembly_path.write_bytes(
            b"\xef\xbb\xbf.intel_syntax noprefix\nmov eax, 9\n")
        real_open_dialog = QFileDialog.getOpenFileName
        QFileDialog.getOpenFileName = staticmethod(
            lambda *_args, **_kwargs: (str(bom_assembly_path), ""))
        try:
            assert win.assembly.open_source()
        finally:
            QFileDialog.getOpenFileName = staticmethod(real_open_dialog)
        assert win.assembly.editor.toPlainText().startswith(".intel_syntax")
        assert "\ufeff" not in win.assembly.editor.toPlainText()
        invalid_assembly_path = Path(outdir) / "invalid-encoding.s"
        invalid_assembly_path.write_bytes(b"\xff\xfe\x00")
        preserved_source = editor.toPlainText()
        real_open_dialog = QFileDialog.getOpenFileName
        QFileDialog.getOpenFileName = staticmethod(
            lambda *_args, **_kwargs: (str(invalid_assembly_path), ""))
        try:
            assert not win.assembly.open_source()
        finally:
            QFileDialog.getOpenFileName = staticmethod(real_open_dialog)
        assert editor.toPlainText() == preserved_source
        assert "decode" in win.assembly.diagnostics.toPlainText().lower()

        # Bare snippets get a generated fall-through HLT. Selecting it must
        # clear a previous linked line instead of falsely retaining that marker.
        assert win.assembly.set_source("mov eax, 7\n", "bare-snippet regression")
        snippet_result = win.assembly.build(True)
        settle(app)
        assert snippet_result is not None
        run_to_stop(win)
        mapped_row = next(
            r for r in range(win.trace.tbl.rowCount())
            if int(win.trace.tbl.item(r, 4).text(), 16)
            in snippet_result.source_map)
        unmapped_row = next(
            r for r in range(win.trace.tbl.rowCount())
            if int(win.trace.tbl.item(r, 4).text(), 16)
            not in snippet_result.source_map)
        win.trace.tbl.setCurrentCell(mapped_row, 0)
        settle(app)
        assert editor._execution_line == 1
        assert win.workspace.tabText(1) == "Assembly · L1"
        win.trace.tbl.setCurrentCell(unmapped_row, 0)
        settle(app)
        assert editor._execution_line is None
        assert win.workspace.tabText(1) == "Assembly"
        assert "no editor source line" in win.assembly.status.text()

        # C syntax highlighting and error navigation.
        win.workspace.setCurrentWidget(win.c_source)
        old_backend = win.backend
        dropped_c = Path(outdir) / "dropped-source.c"
        dropped_c.write_text(
            "int main(void) { return 23; }\n", encoding="utf-8")
        assert win._load_dropped_path(str(dropped_c))
        assert win.workspace.currentWidget() is win.c_source
        assert "return 23" in win.c_source.editor.toPlainText()
        assert win.c_source._path == str(dropped_c)
        assert win.c_source._last_dir == str(Path(outdir).resolve())
        assert win.backend is old_backend
        win.c_source.new_template()
        assert win.c_source._last_dir == str(Path(outdir).resolve())
        c_bare_path = os.path.join(outdir, "c-no-extension")
        real_save_dialog = QFileDialog.getSaveFileName
        QFileDialog.getSaveFileName = staticmethod(
            lambda *_args, **_kwargs:
            (c_bare_path, "C source (*.c)"))
        try:
            assert win.c_source.save_source(save_as=True)
        finally:
            QFileDialog.getSaveFileName = staticmethod(real_save_dialog)
        assert win.c_source._path == c_bare_path + ".c"
        assert Path(c_bare_path + ".c").read_text(
            encoding="utf-8") == win.c_source.editor.toPlainText()
        assert "Saved c-no-extension.c" in win.action_hint.text()
        invalid_c_path = Path(outdir) / "invalid-encoding.c"
        invalid_c_path.write_bytes(b"\x80\x81")
        preserved_c = win.c_source.editor.toPlainText()
        real_open_dialog = QFileDialog.getOpenFileName
        QFileDialog.getOpenFileName = staticmethod(
            lambda *_args, **_kwargs: (str(invalid_c_path), ""))
        try:
            assert not win.c_source.open_source()
        finally:
            QFileDialog.getOpenFileName = staticmethod(real_open_dialog)
        assert win.c_source.editor.toPlainText() == preserved_c
        assert "decode" in win.c_source.diagnostics.toPlainText().lower()
        assert win.c_source.new_template()
        assert "#8b949e" in win.c_source.diagnostics.styleSheet()
        assert "#8b949e" in win.c_source.status.styleSheet()
        assert all(toolbar.isHidden() for toolbar in toolbars)
        assert win.open_action.text() == "Open C source…"
        assert win.save_source_action.isEnabled()
        assert all(not action.isEnabled()
                   for action in win._transport_shortcut_actions)
        assert win.c_source.editor.accessibleName() == "C source editor"
        assert win.c_source.optimization.accessibleName()
        assert win.c_source.diagnostics.accessibleName()
        assert "Ctrl+Enter" in win.c_source.compile_btn.toolTip()
        win.c_source.highlighter.rehighlight()
        settle(app)
        assert "#ff7b72" in format_colors(win.c_source.editor, 4)  # int
        assert "#d2a8ff" in format_colors(win.c_source.editor, 4)  # main
        c_priority_probe = "int main(void) { if (main()) return 1; }\n"
        win.c_source.editor.setPlainText(c_priority_probe)
        win.c_source.highlighter.rehighlight()
        settle(app)
        assert format_color_at(
            win.c_source.editor, 1, c_priority_probe.index("if")) == "#ff7b72"
        assert format_color_at(
            win.c_source.editor, 1, c_priority_probe.index("main")) == "#d2a8ff"
        lexical_probe = (
            'const char *url = "https://example.test/*literal*/"; // comment\n'
            "/* block comment\n"
            '   "quoted text" */\n')
        win.c_source.editor.setPlainText(lexical_probe)
        win.c_source.highlighter.rehighlight()
        settle(app)
        string_slashes = lexical_probe.splitlines()[0].index("//")
        trailing_comment = lexical_probe.splitlines()[0].rindex("//")
        assert format_color_at(
            win.c_source.editor, 1, string_slashes) == "#a5d6ff"
        assert format_color_at(
            win.c_source.editor, 1, trailing_comment) == "#6e7681"
        assert format_color_at(
            win.c_source.editor, 3, 4) == "#6e7681"
        win.c_source.editor.document().setModified(False)
        win.c_source._path = os.path.join(outdir, "indent-probe.c")
        assert win.c_source.save_source()
        assert "#3fb950" in win.c_source.status.styleSheet()
        win.c_source.new_template()
        win.c_source.editor.setPlainText("int main(void)\n{")
        cursor = win.c_source.editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        win.c_source.editor.setTextCursor(cursor)
        QTest.keyClick(win.c_source.editor, Qt.Key_Return)
        assert win.c_source.editor.toPlainText() == "int main(void)\n{\n    "
        QTest.keyClicks(win.c_source.editor, "}")
        assert win.c_source.editor.toPlainText() == "int main(void)\n{\n}"
        win.c_source.editor.document().setModified(False)
        win.c_source.new_template()
        win.c_source.editor.appendPlainText("/* unsaved */")
        assert win.workspace.tabText(2) == "C *"
        dirty_c = win.c_source.editor.toPlainText()
        real_warning = QMessageBox.warning
        QMessageBox.warning = staticmethod(
            lambda *_args, **_kwargs: QMessageBox.Cancel)
        try:
            assert not win.c_source.new_template()
        finally:
            QMessageBox.warning = real_warning
        assert win.c_source.editor.toPlainText() == dirty_c
        QMessageBox.warning = staticmethod(
            lambda *_args, **_kwargs: QMessageBox.Discard)
        try:
            assert win.c_source.new_template()
        finally:
            QMessageBox.warning = real_warning
        assert win.workspace.tabText(2) == "C"
        save(win, outdir, "03_c_workbench")
        win.c_source.editor.setPlainText(
            "int main(void)\n{\n    return missing_symbol;\n}\n")
        assert win.c_source.compile() is None
        assert win.c_source.editor._error_line == 3
        assert "undeclared" in win.c_source.diagnostics.toPlainText()
        win.c_source.editor.insertPlainText(" ")
        assert win.c_source.editor._error_line is None
        assert not win.c_source.diagnostics.toPlainText()
        assert "#8b949e" in win.c_source.diagnostics.styleSheet()
        win.c_source.editor.document().setModified(False)

        # Compile real C, inspect/edit the emitted assembly, then assemble/run it.
        win.c_source.new_template()
        generated = win.c_source.compile()
        settle(app)
        assert generated is not None
        assert win.workspace.currentWidget() is win.assembly
        assert "call main" in win.assembly.editor.toPlainText()
        assert "Assembly generated from C compiler" in win.assembly.status.text()
        save(win, outdir, "04_c_generated_assembly")
        c_result = win.assembly.build(True)
        settle(app)
        assert c_result is not None and win.workspace.currentWidget() is win.visualizer_tab
        run_to_stop(win)
        assert win.backend.state().gpr[0] == 144
        c_pc = next(
            int(win.trace.tbl.item(r, 4).text(), 16)
            for r in range(win.trace.tbl.rowCount())
            if int(win.trace.tbl.item(r, 4).text(), 16) in c_result.source_map)
        select_trace_pc(win, c_pc)
        settle(app)
        assert win.assembly.editor._execution_line == c_result.source_map[c_pc]
        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        save(win, outdir, "05_c_run_source_link")

        # Floating-point C must stay within the Pentium x87 ISA, remain
        # editable, execute on the real RTL, and retain source navigation.
        win.workspace.setCurrentWidget(win.c_source)
        win.c_source.editor.setPlainText(_C_X87_TEMPLATE)
        generated = win.c_source.compile()
        settle(app)
        assert generated is not None
        emitted = win.assembly.editor.toPlainText()
        assert re.search(r"(?m)^\s*f(?:ld|add|addp|istp|stp)\b", emitted)
        assert not re.search(r"(?mi)^\s*(?:mov[adqup]*s|add[ps]s|cvt)", emitted)
        x87_result = win.assembly.build(True)
        settle(app)
        assert x87_result is not None

        # Live source linkage must include the x87 lane, not only the U/V cells
        # exercised by the integer template above. Stop on the first authored
        # FP operation while it is still in flight and click its live cell.
        board = win.pipeline.board
        for _ in range(300):
            win.do_step(1, False)
            settle(app)
            if (board._lane_pcs.get("FP") in x87_result.source_map
                    and any(lane == "FP"
                            for _rect, lane, _pc in board._lane_rects)):
                break
        else:
            raise AssertionError(
                "authored x87 operation never reached the live FP lane")
        fp_pc = board._lane_pcs["FP"]
        fp_rect = next(
            rect for rect, lane, pc in board._lane_rects
            if lane == "FP" and pc == fp_pc)
        QTest.mouseMove(board, fp_rect.center())
        settle(app)
        assert "FP in-flight instruction" in board.toolTip()
        QTest.mouseClick(
            board, Qt.LeftButton, Qt.NoModifier, fp_rect.center())
        settle(app)
        assert win.workspace.currentWidget() is win.visualizer_tab
        assert win.assembly.editor._execution_line == x87_result.source_map[fp_pc]
        assert "In-flight FP-lane" in win.assembly.editor._execution_tip
        save(win, outdir, "06a_c_x87_inflight_source_link")

        run_to_stop(win)
        assert win.backend.state().gpr[0] == 3
        x87_pc = next(
            int(win.trace.tbl.item(r, 4).text(), 16)
            for r in range(win.trace.tbl.rowCount())
            if (int(win.trace.tbl.item(r, 4).text(), 16)
                in x87_result.source_map
                and win.trace.tbl.item(r, 6).text().lower().startswith("f")))
        select_trace_pc(win, x87_pc)
        settle(app)
        assert (win.assembly.editor._execution_line
                == x87_result.source_map[x87_pc])
        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        save(win, outdir, "06_c_x87_source_link")

        # Keep shutdown non-interactive: the C source was injected directly to
        # exercise dirty replacement, so save it as acceptance-test evidence.
        win.workspace.setCurrentWidget(win.c_source)
        win.c_source._path = os.path.join(outdir, "x87-workbench.c")
        assert win.c_source.save_source()
        print("OK GUI authoring: completion/preview, syntax/error lines, "
              "assembly result=55, C Fibonacci result=144, "
              "C x87 result=3, exact PC↔source links")
    finally:
        # Teardown must never mask an earlier assertion behind a modal unsaved
        # source prompt. Save/Discard/Cancel is exercised explicitly above.
        win.assembly.editor.document().setModified(False)
        win.c_source.editor.document().setModified(False)
        win.close()
        settle(app)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="/tmp/pipeviz-authoring")
    args = parser.parse_args()
    verify_catalog()
    verify_toolchain()
    app = QApplication.instance() or QApplication(sys.argv)
    _apply_dark(app)
    scenario(app, args.out)
    print(f"All authoring scenarios passed; screenshots: {args.out}")


if __name__ == "__main__":
    main()
