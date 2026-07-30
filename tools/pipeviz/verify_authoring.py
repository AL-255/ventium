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
from PySide6.QtWidgets import QApplication, QMessageBox

from pipeviz.isa_catalog import CATALOG, MNEMONICS, instruction_info
from pipeviz.main import MainWindow, _apply_dark, _read_program
from pipeviz.source_view import (
    _ASM_TEMPLATE, _C_TEMPLATE, assemble_source, compile_c_source,
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
        os.makedirs(outdir, exist_ok=True)
        save_path = os.path.join(outdir, "keyboard-saved.s")
        win.assembly._path = save_path
        QTest.keyClick(editor, Qt.Key_S, Qt.ControlModifier)
        settle(app)
        assert Path(save_path).read_text(encoding="utf-8") == "i r . [ ] /"
        assert not editor.document().isModified()
        assert win.workspace.tabText(1) == "Assembly"
        win.assembly.new_template()
        win.assembly.editor.highlighter.rehighlight()
        settle(app)
        assert "#79c0ff" in format_colors(editor, 5)  # mov mnemonic
        assert "#56d364" in format_colors(editor, 5)  # eax register
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

        # A syntax error is line-linked and never starts a backend session.
        editor.setPlainText(
            ".intel_syntax noprefix\n.section .text\n.global _start\n_start:\n"
            "    frobnicate eax\n")
        assert win.assembly.build(False) is None
        assert editor._error_line == 5
        assert "Error" in win.assembly.diagnostics.toPlainText()
        assert not win._has_session()

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
        win.c_source.new_template()
        assert all(toolbar.isHidden() for toolbar in toolbars)
        assert win.open_action.text() == "Open C source…"
        assert win.save_source_action.isEnabled()
        assert all(not action.isEnabled()
                   for action in win._transport_shortcut_actions)
        win.c_source.highlighter.rehighlight()
        settle(app)
        assert "#ff7b72" in format_colors(win.c_source.editor, 4)  # int
        assert "#d2a8ff" in format_colors(win.c_source.editor, 4)  # main
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
