#!/usr/bin/env python3
"""End-to-end acceptance checks for the assembly and C workbenches."""
import argparse
import os
from pathlib import Path
import re
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QPoint, QRect, Qt
from PySide6.QtGui import (
    QCloseEvent, QFontMetrics, QGuiApplication, QTextCursor, QWheelEvent,
)
from PySide6.QtTest import QTest
from PySide6.QtWidgets import (
    QApplication, QFileDialog, QInputDialog, QMessageBox, QPlainTextEdit, QWidget,
)

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
        assert info.signature == (
            f"{info.mnemonic} {info.operands}".rstrip())
        assert info.description.strip()
        assert info.pipe in {"UV", "PU", "PV", "NP", "FP", "SYS"}
        assert info.stages
        assert set(info.stages) <= {"F", "D", "X", "M", "W", "S", "FP", "=", "!", "."}
        assert info.latency.strip()
        assert info.availability.strip()
    expected_alu_actions = {
        "add": "Add the source",
        "sub": "Subtract the source",
        "and": "Bitwise AND",
        "or": "Bitwise OR",
        "xor": "Bitwise XOR",
        "cmp": "Compare by subtraction",
    }
    for mnemonic, opening in expected_alu_actions.items():
        info = instruction_info(mnemonic)
        assert info.description.startswith(opening)
        assert mnemonic == "cmp" or "CMP" not in info.description
    assert instruction_info("nop").description == (
        "Perform no architectural operation.")
    assert "CET compatibility" in instruction_info("endbr32").description
    assert instruction_info("jnz").description == (
        "Jump when not equal / nonzero (ZF=0).")
    assert instruction_info("ja").description == (
        "Jump when unsigned above (CF=0 and ZF=0).")
    assert instruction_info("jl").description == (
        "Jump when signed less-than (SF≠OF).")
    assert instruction_info("setz").description == (
        "Store 1 when equal / zero (ZF=1); otherwise store 0.")
    assert instruction_info("setg").description == (
        "Store 1 when signed greater-than (ZF=0 and SF=OF); "
        "otherwise store 0.")
    assert instruction_info("loopne").description == (
        "Decrement (E)CX and jump when nonzero and ZF=0.")
    assert instruction_info("jecxz").description == (
        "Jump when ECX is zero; flags are unchanged.")
    expected_x87_details = {
        "fild": "signed integer",
        "fstp": "then pop",
        "fsubr": "Reverse subtract",
        "fsubrp": "ST(0) minus ST(i)",
        "fdivr": "Reverse divide",
        "fdivrp": "ST(0) divided by ST(i)",
        "fcompp": "pop twice",
        "fxam": "Classify ST(0)",
        "fldpi": "constant π",
        "ffree": "tag as empty",
        "fincstp": "Increment x87 TOP",
        "fnstcw": "without an implicit WAIT",
        "fstcw": "then store the control word",
    }
    for mnemonic, detail in expected_x87_details.items():
        assert detail in instruction_info(mnemonic).description
    obsolete_x87_help = {
        "Push a real, integer, BCD, constant, or x87 register value.",
        "Store/convert ST(0), optionally popping it.",
        "x87 add/subtract family.",
        "x87 multiply family.",
        "x87 divide family.",
        "Compare/classify x87 operands and update the x87 status word.",
        "Change or clear ST(0)'s sign.",
        "Push a built-in x87 constant.",
        "Manipulate the x87 stack/tag state.",
        "Load, store, clear, initialize, or inspect x87 control/status state.",
    }
    assert not any(info.description in obsolete_x87_help for info in CATALOG)
    expected_string_details = {
        "movsb": "one byte from DS:[(E)SI] to ES:[(E)DI]",
        "stosd": "Store EAX in ES:[(E)DI]",
        "lodsw": "into AX",
        "scasd": "Compare EAX with the dword",
        "cmpsb": "bytes at DS:[(E)SI] and ES:[(E)DI]",
        "insd": "I/O port DX into ES:[(E)DI]",
        "outsw": "from DS:[(E)SI] to I/O port DX",
        "repne": "(E)CX is nonzero and ZF=0",
        "std": "string indexes decrement",
        "cli": "disabling maskable interrupts",
    }
    for mnemonic, detail in expected_string_details.items():
        assert detail in instruction_info(mnemonic).description
    assert instruction_info("movsd").stages == ("F", "D", "S", "M")
    assert instruction_info("outsb").stages == ("F", "D", "S", "M")
    assert instruction_info("clc").availability == "user"
    assert instruction_info("std").availability == "user"
    assert instruction_info("cli").availability == "system-oriented"
    assert instruction_info("sti").availability == "system-oriented"
    obsolete_string_help = {
        "Move or store one string element; REP is micro-sequenced.",
        "Load or scan one string element; REP is micro-sequenced.",
        "Compare string elements and update flags; REP is micro-sequenced.",
        "Transfer a string element through an I/O port.",
        "Legacy repetition/atomic prefix accepted by the decoder.",
        "Clear, set, or complement carry/direction/interrupt control flags.",
        "Clear, set, or complement carry/direction control flags.",
        "Clear or set the interrupt-enable flag.",
        "Read or write an I/O port.",
    }
    assert not any(info.description in obsolete_string_help for info in CATALOG)
    expected_integer_details = {
        "movsx": "Sign-extend",
        "movzx": "Zero-extend",
        "adc": "source and carry flag",
        "sbb": "carry/borrow",
        "dec": "preserving the carry flag",
        "not": "without changing flags",
        "mul": "Unsigned-multiply",
        "imul": "Signed multiply",
        "div": "Unsigned-divide",
        "idiv": "Signed-divide",
        "cwde": "AX into EAX",
        "cdq": "EDX:EAX",
        "bsf": "least-significant set",
        "bsr": "most-significant set",
        "btc": "then complement",
        "btr": "then clear",
        "bts": "then set",
        "shr": "fill high bits with zero",
        "sar": "replicate the sign bit",
        "rcl": "through CF",
        "shrd": "pulling high-order bits",
        "push": "Decrement the stack pointer",
        "pop": "increment the stack pointer",
        "pushad": "original ESP",
        "popad": "skip ESP",
        "pushfd": "32-bit EFLAGS",
        "sahf": "SF, ZF, AF, PF, and CF",
    }
    for mnemonic, detail in expected_integer_details.items():
        assert detail in instruction_info(mnemonic).description
    obsolete_integer_help = {
        "Sign-extend or zero-extend a byte/word into a register.",
        "Add/subtract with carry. May lead a pair but cannot occupy V.",
        "Increment/decrement while preserving carry.",
        "Two's-complement negate or bitwise complement.",
        "Integer multiply; IMUL also has two- and three-operand forms.",
        "Unsigned/signed divide of the implicit accumulator pair.",
        "Sign-extend AL/AX/EAX into the wider implicit accumulator pair.",
        "Find the first/last set bit.",
        "Test, complement, reset, or set a selected bit.",
        "Shift or rotate by 1, CL, or an immediate. Immediate forms may lead U/V.",
        "Double-precision shift using two operands.",
        "Push or pop a register, immediate, segment, or memory value.",
        "Push or pop the complete general-register set.",
        "Push or pop architectural flags.",
        "Transfer selected status flags to/from AH.",
    }
    assert not any(info.description in obsolete_integer_help for info in CATALOG)
    expected_system_details = {
        "aaa": "after addition",
        "aas": "after subtraction",
        "aam": "quotient AH and remainder AL",
        "retf": "CS:(E)IP",
        "int3": "breakpoint interrupt vector 3",
        "iretd": "32-bit EIP, CS, and EFLAGS",
        "lss": "register and SS",
        "lgdt": "Load the GDTR",
        "sgdt": "Store the GDTR",
        "ltr": "Load the task-register",
        "str": "Store the current task-register",
        "wbinvd": "Write back",
        "fnstenv": "without an implicit WAIT",
        "fsave": "then initialize x87 state",
        "frndint": "control-word rounding mode",
        "fprem1": "nearest quotient",
        "fpatan": "arctan(ST(1) / ST(0))",
        "fyl2xp1": "log2(ST(0)+1)",
    }
    for mnemonic, detail in expected_system_details.items():
        assert detail in instruction_info(mnemonic).description
    obsolete_system_help = {
        "Legacy ASCII/BCD adjustment instruction implemented by the core.",
        "Return from a near or far procedure.",
        "Deliver/return from an interrupt through the IDT.",
        "Load a general register and segment selector from a far pointer.",
        "Load or store a six-byte descriptor-table register.",
        "Load/store a task or local-descriptor selector.",
        "Modeled cache-management serialization/no-op.",
        "Load or store the x87 environment/full state image.",
        "Round ST(0) to integer or scale it by a power of two.",
        "Compute a partial IEEE/x87 remainder.",
        "Iterative x87 transcendental operation.",
    }
    assert not any(info.description in obsolete_system_help for info in CATALOG)
    obsolete_condition_help = {
        "Conditional branch selected by EFLAGS.",
        "Assembler alias for a conditional branch selected by EFLAGS.",
        "Store a one-byte Boolean selected by EFLAGS.",
        "Assembler alias for a one-byte SETcc result.",
        "Counted/zero-count branch handled on the slow control path.",
    }
    assert not any(
        info.description in obsolete_condition_help for info in CATALOG)
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
    # The independent P5 timing classifier names exact Capstone instruction
    # IDs rather than RTL operation families. Cover every 32-bit P54C mnemonic
    # it handles; MOVABS/MOVSXD are Capstone's non-Pentium 64-bit aliases.
    timing_model = (
        Path(__file__).resolve().parents[2]
        / "verif/qemu-plugins/p5trace.c"
    ).read_text(encoding="utf-8")
    timing_mnemonics = {
        token.lower()
        for token in re.findall(r"\bX86_INS_([A-Z0-9_]+)\b", timing_model)
    } - {"movabs", "movsxd"}
    assert timing_mnemonics <= MNEMONICS, (
        "P5 timing mnemonics absent from completion: "
        + ", ".join(sorted(timing_mnemonics - MNEMONICS)))
    print(f"OK ISA catalogue: {len(CATALOG)} completion mnemonics, "
          "all current decoder families, "
          f"{len(timing_mnemonics)} exact P5 timing mnemonics, "
          "and pipeline/mode metadata present")


def verify_toolchain():
    assert "same ELF U/V on/off" in _C_TEMPLATE
    assert "0x198c09a0" in _C_TEMPLATE
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
    assert "Built .generated/assembly.elf" in assembled.log
    assert str(source_module._GENERATED_DIR) not in assembled.log
    snippet = assemble_source("mov eax, 7\n")
    assert set(snippet.source_map.values()) == {1}
    warned = assemble_source(
        ".intel_syntax noprefix\n.global _start\n_start:\n"
        '.warning "acceptance warning"\nhlt\n')
    assert warned.warning_line == 4
    assert "warning:" in warned.log.lower()
    assert "Assembly:4:" in warned.log
    assert str(source_module._GENERATED_DIR) not in warned.log
    for optimization in ("-O0", "-O1", "-O2", "-Os"):
        generated, _log = compile_c_source(
            _C_TEMPLATE, optimization=optimization)
        assert ".intel_syntax noprefix" in generated
        assert "_start:" in generated and "call main" in generated
        compiled = assemble_source(generated)
        assert len(compiled.source_map) >= 10
    array_assembly, _log = compile_c_source(_C_ARRAY_TEMPLATE)
    assert "memset" not in array_assembly
    assert "_start:" in array_assembly
    assert len(assemble_source(array_assembly).source_map) >= 10
    _warning_assembly, warning_log = compile_c_source(
        "int main(void) { int unused; return 0; }\n")
    assert "warning:" in warning_log.lower()
    assert "unused variable" in warning_log
    assert "C source:1:" in warning_log
    assert str(source_module._GENERATED_DIR) not in warning_log
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
    assert source_module._completion_bounds(
        QRect(1, 1, 900, 620), QRect(0, 0, 533, 533), 650, 257
    ) == QRect(1, 1, 900, 620)
    assert source_module._completion_bounds(
        QRect(20, 20, 900, 620), QRect(0, 0, 1200, 800), 650, 257
    ) == QRect(20, 20, 900, 620)
    assert source_module._completion_bounds(
        QRect(20, 20, 500, 400), QRect(0, 0, 1200, 800), 650, 257
    ) == QRect(0, 0, 1200, 800)
    win = MainWindow()
    win.resize(1500, 920)
    win.show()
    settle(app)
    try:
        assert [win.workspace.tabText(i) for i in range(3)] == [
            "Visualizer", "Assembly", "C"]
        assert "Ctrl+B or Ctrl+Enter" in win.c_source.status.text()
        assert not win.new_source_action.isEnabled()
        assert not win.save_source_action.isEnabled()
        assert not win.save_source_as_action.isEnabled()
        assert [action.shortcut().toString()
                for action in win._workspace_actions] == ["Alt+V", "Alt+A", "Alt+C"]
        assert win._view_menu.title() == "Vie&w"
        QTest.keyClick(win, Qt.Key_A, Qt.AltModifier)
        settle(app)
        assert win.workspace.currentWidget() is win.assembly
        assert app.focusWidget() is win.assembly.editor
        QTest.keyClick(win.assembly.editor, Qt.Key_C, Qt.AltModifier)
        settle(app)
        assert win.workspace.currentWidget() is win.c_source
        assert app.focusWidget() is win.c_source.editor
        QTest.keyClick(win.c_source.editor, Qt.Key_V, Qt.AltModifier)
        settle(app)
        assert win.workspace.currentWidget() is win.visualizer_tab
        assert app.focusWidget() is win.pipeline.konata.plot
        QTest.keyClick(win.pipeline.konata.plot, Qt.Key_A, Qt.AltModifier)
        settle(app)
        assert win.workspace.currentWidget() is win.assembly
        assert app.focusWidget() is win.assembly.editor
        toolbars = (
            win.session_toolbar, win.transport_toolbar, win.status_toolbar)
        assert all(toolbar.isHidden() for toolbar in toolbars)
        assert all(not action.isEnabled()
                   for action in win._toolbar_visibility_actions)
        for toolbar, action in zip(
                toolbars, win._toolbar_visibility_actions):
            action.trigger()
            assert toolbar.isHidden()
        assert win.open_action.text() == "Open assembly source…"
        assert win.open_action.shortcut().toString() == "Ctrl+O"
        assert win.new_source_action.isEnabled()
        assert win.new_source_action.shortcut().toString() == "Ctrl+N"
        assert win.new_source_action.text() == "New assembly template"
        assert win.save_source_action.isEnabled()
        assert win.save_source_action.shortcut().toString() == "Ctrl+S"
        assert win.save_source_as_action.isEnabled()
        assert win.save_source_as_action.shortcut().toString() == "Ctrl+Shift+S"
        assert win.save_source_as_action.text() == "Save assembly source as…"
        assert win.assembly.editor.accessibleName() == "Assembly source editor"
        assert win.assembly.status.accessibleName() == (
            "Assembly workbench status")
        assert "Ctrl+B assembles" in win.assembly.status.text()
        assert "Ctrl+Enter assembles and runs" in win.assembly.status.text()
        assert win.assembly.status.toolTip() == win.assembly.status.text()
        assert win.assembly.status.accessibleDescription() == (
            win.assembly.status.text())
        assert win.assembly.cursor_position.text() == "Ln 1 · Col 1"
        assert win.assembly.cursor_position.accessibleName() == (
            "Go to source line")
        assert win.assembly.cursor_position.accessibleDescription() == (
            "Cursor at source line 1, column 1. "
            "Click or press Ctrl+G to go to a line.")
        assert win.assembly.source_badge.accessibleName() == "Assembly source identity"
        assert win.assembly.source_badge.accessibleDescription() == (
            "Source origin built-in template; not saved. No unsaved changes.")
        assert "built-in template" in win.assembly.source_badge.text()
        assert "not saved" in win.assembly.source_badge.text()
        assert win.assembly.editor.completion.list.accessibleName()
        assert win.assembly.diagnostics.accessibleName()
        assert win.assembly.info.signature.text() == "No opcode selected"
        assert not win.assembly.info.description.text()
        assert "Ctrl+Space" in (
            win.assembly.info.preview.accessibleDescription())
        assert win.assembly.diagnostics.placeholderText() == (
            "Build diagnostics appear here.")
        assert win.assembly.diagnostics.accessibleDescription() == (
            "No build diagnostics.")
        assert win.pipeline.board.accessibleName() == "Live pipeline stage board"
        assert "clicked" in win.pipeline.board.accessibleDescription()
        assert "Ctrl+Enter" in win.assembly.run_btn.toolTip()
        assert "Ctrl+B" in win.assembly.build_btn.toolTip()
        assert "Ctrl+N" in win.assembly.template_btn.toolTip()
        assert "Ctrl+Shift+S" in win.assembly.save_btn.toolTip()
        build_requests = []
        real_build = win.assembly.build
        win.assembly.build = (
            lambda run=False: build_requests.append(bool(run)))
        try:
            QTest.keyClick(
                win.assembly.editor, Qt.Key_B, Qt.ControlModifier)
            settle(app)
        finally:
            win.assembly.build = real_build
        assert build_requests == [False]
        new_requests = []
        real_new_template = win.assembly.new_template
        win.assembly.new_template = lambda: new_requests.append("assembly")
        try:
            QTest.keyClick(win.assembly.editor, Qt.Key_N, Qt.ControlModifier)
            settle(app)
        finally:
            win.assembly.new_template = real_new_template
        assert new_requests == ["assembly"]

        # Analysis shortcuts are global navigation, not hidden background
        # mutations. From a source editor they must reveal the Visualizer and
        # focus the requested analysis content, then restore editor focus on
        # the way back.
        QTest.keyClick(win.assembly.editor, Qt.Key_1, Qt.AltModifier)
        settle(app)
        assert win.workspace.currentWidget() is win.visualizer_tab
        assert win.tables.tabs.currentIndex() == 0
        assert app.focusWidget() is win.tables.ic
        hidden_build_requests = []
        real_build = win.assembly.build
        real_compile = win.c_source.compile
        win.assembly.build = (
            lambda run=False: hidden_build_requests.append(("asm", run)))
        win.c_source.compile = (
            lambda: hidden_build_requests.append(("c", False)))
        try:
            QTest.keyClick(win.tables.ic, Qt.Key_B, Qt.ControlModifier)
            settle(app)
        finally:
            win.assembly.build = real_build
            win.c_source.compile = real_compile
        assert not hidden_build_requests
        assert win.reset_layout_action.isEnabled()
        assert all(action.isEnabled()
                   for action in win._toolbar_visibility_actions)
        assert all(not toolbar.isHidden() for toolbar in toolbars)
        QTest.keyClick(win.tables.ic, Qt.Key_A, Qt.AltModifier)
        settle(app)
        assert win.workspace.currentWidget() is win.assembly
        assert app.focusWidget() is win.assembly.editor
        assert not win.reset_layout_action.isEnabled()
        assert all(toolbar.isHidden() for toolbar in toolbars)

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
        dirty_before_cancelled_new = editor.toPlainText()
        real_warning = QMessageBox.warning
        QMessageBox.warning = staticmethod(
            lambda *_args, **_kwargs: QMessageBox.Cancel)
        try:
            QTest.keyClick(editor, Qt.Key_N, Qt.ControlModifier)
            settle(app)
        finally:
            QMessageBox.warning = real_warning
        assert editor.toPlainText() == dirty_before_cancelled_new
        assert win.workspace.tabText(1) == "Assembly *"
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
        keyboard_save_as_path = os.path.join(
            outdir, "keyboard-save-as.s")
        real_save_dialog = QFileDialog.getSaveFileName
        QFileDialog.getSaveFileName = staticmethod(
            lambda *_args, **_kwargs:
            (keyboard_save_as_path, "Assembly (*.s)"))
        try:
            QTest.keyClick(
                editor, Qt.Key_S,
                Qt.ControlModifier | Qt.ShiftModifier)
            settle(app)
        finally:
            QFileDialog.getSaveFileName = staticmethod(real_save_dialog)
        assert win.assembly._path == keyboard_save_as_path
        assert Path(keyboard_save_as_path).read_text(
            encoding="utf-8") == "i r . [ ] /"
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
        saved_assembly_path = win.assembly._path
        editor.document().setModified(True)
        assert win.workspace.tabText(1) == "Assembly *"
        blocked_assembly_save = str(
            blocked_artifacts / "cannot-save-assembly.s")
        real_save_dialog = QFileDialog.getSaveFileName
        QFileDialog.getSaveFileName = staticmethod(
            lambda *_args, **_kwargs:
            (blocked_assembly_save, "Assembly (*.s)"))
        try:
            assert not win.assembly.save_source(save_as=True)
        finally:
            QFileDialog.getSaveFileName = staticmethod(real_save_dialog)
        assert win.assembly._path == saved_assembly_path
        assert editor.document().isModified()
        assert win.workspace.tabText(1) == "Assembly *"
        assert win.assembly.source_badge.text().endswith("*")
        assert app.focusWidget() is editor
        assert win.assembly.status.text().startswith("Save failed · ")
        assert "cannot-save-assembly.s" in win.assembly.status.text()
        assert win.assembly.status.toolTip() == win.assembly.status.text()
        assert win.assembly.status.accessibleDescription() == (
            win.assembly.status.text())
        assert "#f85149" in win.assembly.status.styleSheet()
        assert win.assembly.diagnostics._severity == "error"
        assert win.assembly.status.text() in (
            win.assembly.diagnostics.accessibleDescription())
        assert win.action_hint.text() == win.assembly.status.text()
        settle(app)
        save(win, outdir, "00c_assembly_save_failure")
        editor.document().setModified(False)
        dropped_assembly = Path(outdir) / "dropped-source.S"
        dropped_assembly.write_text(
            ".intel_syntax noprefix\nmov eax, 17\n", encoding="utf-8")
        assert win._load_dropped_path(str(dropped_assembly))
        assert win.workspace.currentWidget() is win.assembly
        assert editor.toPlainText().endswith("mov eax, 17\n")
        assert win.assembly._path == str(dropped_assembly)
        assert "dropped-source.S" in win.assembly.source_badge.text()
        assert win.assembly.source_badge.toolTip() == str(dropped_assembly.resolve())
        assert win.assembly.source_badge.accessibleDescription() == (
            f"Source file {dropped_assembly.resolve()}. No unsaved changes.")
        assert win.assembly._last_dir == str(Path(outdir).resolve())
        assert win.assembly.status.text() == "Opened dropped-source.S"
        assert win.assembly.status.toolTip() == "Opened dropped-source.S"
        assert "Opened assembly source: dropped-source.S" in win.action_hint.text()
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
            editor, 1, assembly_literal.rindex("#")) == "#7d8590"
        structural_probe = "eax: add eax, 1\n.int 3"
        editor.setPlainText(structural_probe)
        editor.highlighter.rehighlight()
        settle(app)
        assert format_color_at(editor, 1, 0) == "#d2a8ff"  # label, not EAX
        assert format_color_at(editor, 1, 5) == "#79c0ff"  # ADD opcode
        assert format_color_at(editor, 2, 1) == "#ff7b72"  # directive, not INT
        editor.document().setModified(False)
        assert win.assembly.new_template()
        assert editor._line_area.accessibleName() == "Source line numbers"
        assert "drag" in editor._line_area.accessibleDescription()
        line_cursor = QTextCursor(
            editor.document().findBlockByNumber(4))
        line_y = editor.cursorRect(line_cursor).center().y()
        QTest.mouseClick(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(editor._line_area.width() // 2, line_y))
        assert app.focusWidget() is editor
        assert editor.textCursor().blockNumber() == 4
        assert editor.textCursor().selectedText().strip() == "mov eax, 0"
        drag_end_block = editor.document().findBlockByNumber(7)
        drag_end_y = editor.cursorRect(
            QTextCursor(drag_end_block)).center().y()
        gutter_x = editor._line_area.width() // 2
        QTest.mouseClick(
            editor._line_area, Qt.LeftButton, Qt.ShiftModifier,
            QPoint(gutter_x, drag_end_y))
        assert editor.textCursor().selectionStart() == line_cursor.block().position()
        assert editor.textCursor().selectionEnd() == (
            drag_end_block.position() + len(drag_end_block.text()))
        assert win.assembly.cursor_position.text().endswith(" · 4L")
        QTest.mouseClick(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(gutter_x, line_y))
        QTest.mousePress(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(gutter_x, line_y))
        QTest.mouseMove(
            editor._line_area, QPoint(gutter_x, drag_end_y))
        QTest.mouseRelease(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(gutter_x, drag_end_y))
        assert editor.textCursor().selectionStart() == line_cursor.block().position()
        assert editor.textCursor().selectionEnd() == (
            drag_end_block.position() + len(drag_end_block.text()))
        assert win.assembly.cursor_position.text().endswith(" · 4L")
        assert "Selection spans 4 lines" in (
            win.assembly.cursor_position.accessibleDescription())
        QTest.mousePress(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(gutter_x, drag_end_y))
        QTest.mouseMove(editor._line_area, QPoint(gutter_x, line_y))
        QTest.mouseRelease(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(gutter_x, line_y))
        assert editor.textCursor().selectionStart() == line_cursor.block().position()
        assert editor.textCursor().selectionEnd() == (
            drag_end_block.position() + len(drag_end_block.text()))
        assert win.assembly.cursor_position.text().endswith(" · 4L")
        QTest.mouseClick(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(gutter_x, line_y))
        selected_range = (
            editor.textCursor().selectionStart(),
            editor.textCursor().selectionEnd())
        assert win.assembly.cursor_position.text().endswith(" · 1L")
        QTest.mouseClick(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(editor._line_area.width() // 2,
                   editor._line_area.height() - 2))
        assert (
            editor.textCursor().selectionStart(),
            editor.textCursor().selectionEnd()) == selected_range
        editor.setFocus()
        QTest.keyClick(editor, Qt.Key_F, Qt.ControlModifier)
        settle(app)
        assert win.assembly.find_bar.isVisible()
        assert win.assembly.find_bar.query.text().strip() == "mov eax, 0"
        win.assembly.find_bar.query.clear()
        assert not win.assembly.find_bar.previous_btn.isEnabled()
        assert not win.assembly.find_bar.next_btn.isEnabled()
        assert win.assembly.find_bar.count.accessibleName() == (
            "Source search match count")
        assert win.assembly.find_bar.count.accessibleDescription() == (
            "No active source search")
        QTest.keyClicks(win.assembly.find_bar.query, "absent")
        settle(app)
        assert win.assembly.find_bar.count.text() == "No matches"
        assert "'absent'" in (
            win.assembly.find_bar.count.accessibleDescription())
        assert not win.assembly.find_bar.previous_btn.isEnabled()
        assert not win.assembly.find_bar.next_btn.isEnabled()
        win.assembly.find_bar.query.clear()
        QTest.keyClicks(win.assembly.find_bar.query, "MOV")
        settle(app)
        assert win.assembly.find_bar.count.text().endswith("/ 2")
        assert editor.textCursor().selectedText() == "mov"
        win.assembly.find_bar.query.clear()
        search_start = editor.textCursor()
        search_start.clearSelection()
        search_start.movePosition(QTextCursor.Start)
        editor.setTextCursor(search_start)
        win.assembly.find_bar.query.setFocus()
        QTest.keyClicks(win.assembly.find_bar.query, "mov")
        settle(app)
        assert win.assembly.find_bar.count.text() == "1 / 2", (
            win.assembly.find_bar.query.text(),
            win.assembly.find_bar.count.text())
        assert win.assembly.find_bar.count.accessibleDescription() == (
            "Match 1 of 2 for 'mov'")
        assert win.assembly.find_bar.previous_btn.isEnabled()
        assert win.assembly.find_bar.next_btn.isEnabled()
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
        find_source = editor.toPlainText()
        editor.setPlainText("x\n" * 2001)
        editor.moveCursor(QTextCursor.Start)
        win.assembly.find_bar.show_find()
        win.assembly.find_bar.query.setText("x")
        settle(app)
        assert editor._find_truncated
        win.assembly.find_bar.find(-1)
        settle(app)
        assert win.assembly.find_bar.count.text() == "2,000 / 2,000+"
        assert "at least 2000" in (
            win.assembly.find_bar.count.accessibleDescription())
        assert QFontMetrics(
            win.assembly.find_bar.count.font()).horizontalAdvance(
                win.assembly.find_bar.count.text()) <= (
                    win.assembly.find_bar.count.contentsRect().width())
        save(win, outdir, "00ba_assembly_find_cap")
        win.assembly.find_bar.hide_find()
        editor.setPlainText(find_source)
        editor.document().setModified(False)
        settle(app)
        line_five = editor.document().findBlockByNumber(4)
        line_five_y = round(editor.blockBoundingGeometry(line_five).translated(
            editor.contentOffset()).center().y())
        QTest.mouseClick(
            editor._line_area, Qt.LeftButton, Qt.NoModifier,
            QPoint(5, line_five_y))
        settle(app)
        assert editor.textCursor().blockNumber() + 1 == 5
        assert editor.textCursor().selectedText() == "    mov eax, 0"
        assert app.focusWidget() is editor
        assert win.assembly.cursor_position.text().startswith("Ln 5 · Col ")
        assert "source line 5" in (
            win.assembly.cursor_position.accessibleDescription())
        real_get_int = QInputDialog.getInt
        answers = iter(((2, True), (6, True), (6, False)))
        QInputDialog.getInt = staticmethod(
            lambda *_args, **_kwargs: next(answers))
        try:
            assert editor.request_completion(force=True)
            assert editor.completion.isVisible()
            QTest.keyClick(editor, Qt.Key_G, Qt.ControlModifier)
            settle(app)
            assert not editor.completion.isVisible()
            assert editor.textCursor().blockNumber() + 1 == 2
            assert editor.textCursor().positionInBlock() == 0
            assert win.assembly.cursor_position.text() == "Ln 2 · Col 1"
            assert app.focusWidget() is editor
            QTest.mouseClick(
                win.assembly.cursor_position, Qt.LeftButton)
            settle(app)
            assert editor.textCursor().blockNumber() + 1 == 6
            assert win.assembly.cursor_position.text() == "Ln 6 · Col 1"
            position_before_cancel = editor.textCursor().position()
            QTest.mouseClick(
                win.assembly.cursor_position, Qt.LeftButton)
            settle(app)
            assert editor.textCursor().position() == position_before_cancel
            assert app.focusWidget() is editor
        finally:
            QInputDialog.getInt = staticmethod(real_get_int)
        save(win, outdir, "00_assembly_workbench")
        win.resize(900, 620)
        settle(app)
        assert win.width() == 900
        assert win.minimumSizeHint().width() <= 900
        for button in (
                win.assembly.template_btn, win.assembly.open_btn,
                win.assembly.save_btn, win.assembly.complete_btn,
                win.assembly.build_btn, win.assembly.run_btn):
            corner = button.mapTo(win, button.rect().bottomRight())
            assert 0 <= corner.x() < win.width()
            assert 0 <= corner.y() < win.height()
            assert button.accessibleName()
            assert button.accessibleDescription() == button.toolTip()
        unnamed_assembly_focus = [
            (type(widget).__name__, widget.objectName())
            for widget in win.findChildren(QWidget)
            if (widget.isVisibleTo(win) and widget.isEnabled()
                and widget.focusPolicy() != Qt.NoFocus
                and not widget.accessibleName()
                and not (
                    widget.objectName() == "qt_spinbox_lineedit"
                    and widget.parentWidget() is not None
                    and widget.parentWidget().accessibleName()))
        ]
        assert not unnamed_assembly_focus, unnamed_assembly_focus
        badge_corner = win.assembly.source_badge.mapTo(
            win, win.assembly.source_badge.rect().bottomRight())
        cursor_corner = win.assembly.cursor_position.mapTo(
            win, win.assembly.cursor_position.rect().bottomRight())
        assert win.assembly.source_badge.isVisible()
        assert win.assembly.source_badge.width() >= 200
        assembly_badge_display = win.assembly.source_badge.displayText()
        assert QFontMetrics(
            win.assembly.source_badge.font()).horizontalAdvance(
                assembly_badge_display) <= (
                    win.assembly.source_badge.contentsRect().width() + 1)
        if QFontMetrics(
                win.assembly.source_badge.font()).horizontalAdvance(
                    win.assembly.source_badge.text()) > (
                        win.assembly.source_badge.contentsRect().width()):
            assert "…" in assembly_badge_display
        assert 0 <= badge_corner.x() < win.width()
        assert 0 <= badge_corner.y() < win.height()
        assert 0 <= cursor_corner.x() < win.width()
        assert 0 <= cursor_corner.y() < win.height()
        assert editor.width() >= 500 and editor.height() >= 400
        original_assembly_status = win.assembly.status.text()
        long_assembly_status = (
            "Saved dual-fibonacci-scheduling-experiment-with-a-deliberately-"
            "long-source-name-for-compact-layout.s")
        win.assembly.status.setText(long_assembly_status)
        settle(app)
        assert win.assembly.status.text() == long_assembly_status
        assert "…" in win.assembly.status.displayText()
        assert QFontMetrics(
            win.assembly.status.font()).horizontalAdvance(
                win.assembly.status.displayText()) <= (
                    win.assembly.status.contentsRect().width() + 1)
        assert win.assembly.status.toolTip() == long_assembly_status
        assert win.assembly.status.accessibleDescription() == (
            long_assembly_status)
        save(win, outdir, "00aa_assembly_compact_long_status")
        win.assembly.status.setText(original_assembly_status)
        settle(app)
        assert "Ctrl+Tab" in editor.accessibleDescription()
        assert "Ctrl+/" in editor.accessibleDescription()
        editor.setFocus()
        original_source = editor.toPlainText()
        QTest.keyClick(editor, Qt.Key_Tab, Qt.ControlModifier)
        settle(app)
        assert app.focusWidget() is win.assembly.diagnostics
        assert editor.toPlainText() == original_source
        editor.setFocus()
        QTest.keyClick(
            editor, Qt.Key_Backtab,
            Qt.ControlModifier | Qt.ShiftModifier)
        settle(app)
        assert app.focusWidget() is win.assembly.run_btn
        assert editor.toPlainText() == original_source
        assert not win.reset_layout_action.isEnabled()
        base_tab_stop = editor.tabStopDistance()
        QTest.keyClick(editor, Qt.Key_Plus, Qt.ControlModifier)
        assert editor.font().pointSize() == 11
        assert editor.tabStopDistance() > base_tab_stop
        assert editor._line_area.width() == editor.line_number_area_width()
        assert "Current text size: 11 point" in (
            editor.accessibleDescription())
        QTest.keyClick(editor, Qt.Key_Minus, Qt.ControlModifier)
        assert editor.font().pointSize() == 10
        for _ in range(6):
            QTest.keyClick(editor, Qt.Key_Minus, Qt.ControlModifier)
        assert editor.font().pointSize() == 8
        for _ in range(20):
            QTest.keyClick(editor, Qt.Key_Plus, Qt.ControlModifier)
        assert editor.font().pointSize() == 24
        QTest.keyClick(editor, Qt.Key_0, Qt.ControlModifier)
        assert editor.font().pointSize() == 10
        assert editor.tabStopDistance() == base_tab_stop
        wheel_up = QWheelEvent(
            QPoint(20, 20), QPoint(20, 20), QPoint(), QPoint(0, 120),
            Qt.NoButton, Qt.ControlModifier, Qt.NoScrollPhase, False)
        QApplication.sendEvent(editor.viewport(), wheel_up)
        assert wheel_up.isAccepted()
        assert editor.font().pointSize() == 11
        wheel_down = QWheelEvent(
            QPoint(20, 20), QPoint(20, 20), QPoint(), QPoint(0, -120),
            Qt.NoButton, Qt.ControlModifier, Qt.NoScrollPhase, False)
        QApplication.sendEvent(editor.viewport(), wheel_down)
        assert wheel_down.isAccepted()
        assert editor.font().pointSize() == 10
        editor.setPlainText("\n".join(
            f"mov eax, {line}" for line in range(200)))
        editor.verticalScrollBar().setValue(0)
        plain_wheel = QWheelEvent(
            QPoint(20, 20), QPoint(20, 20), QPoint(), QPoint(0, -120),
            Qt.NoButton, Qt.NoModifier, Qt.NoScrollPhase, False)
        QApplication.sendEvent(editor.viewport(), plain_wheel)
        assert editor.font().pointSize() == 10
        assert editor.verticalScrollBar().value() > 0
        bracket_probe = (
            'mov eax, [ebx + (ecx * 4)]\n'
            '# ignored [)]\n'
            '.ascii "{still ignored}"\n')
        editor.setPlainText(bracket_probe)
        caret = editor.textCursor()
        outer_open = bracket_probe.index("[")
        outer_close = bracket_probe.index("]")
        caret.setPosition(outer_open + 1)
        editor.setTextCursor(caret)
        assert set(editor._matched_bracket_positions) == {
            outer_open, outer_close}
        assert editor._unmatched_bracket_position is None
        assert set(editor._bracket_index) == {
            bracket_probe.index("["),
            bracket_probe.index("("),
            bracket_probe.index(")"),
            bracket_probe.index("]"),
        }
        editor.setPlainText("mov eax, ([ebx)]")
        caret = editor.textCursor()
        unmatched = editor.toPlainText().index("(")
        caret.setPosition(unmatched + 1)
        editor.setTextCursor(caret)
        assert editor._matched_bracket_positions == ()
        assert editor._unmatched_bracket_position == unmatched
        indentation_probe = "mov eax, 1\nadd eax, 2\nhlt\n"
        editor.setPlainText(indentation_probe)
        selection = editor.textCursor()
        selection.setPosition(0)
        selection.setPosition(
            indentation_probe.index("hlt"), QTextCursor.KeepAnchor)
        editor.setTextCursor(selection)
        QTest.keyClick(editor, Qt.Key_Tab)
        indented_probe = "    mov eax, 1\n    add eax, 2\nhlt\n"
        assert editor.toPlainText() == indented_probe
        editor.document().undo()
        assert editor.toPlainText() == indentation_probe
        editor.document().redo()
        assert editor.toPlainText() == indented_probe
        selection = editor.textCursor()
        selection.setPosition(0)
        selection.setPosition(
            indented_probe.index("hlt"), QTextCursor.KeepAnchor)
        editor.setTextCursor(selection)
        QTest.keyClick(editor, Qt.Key_Backtab, Qt.ShiftModifier)
        assert editor.toPlainText() == indentation_probe
        assert editor.textCursor().hasSelection()
        comment_probe = "    mov eax, 1\n\nadd eax, 2\n"
        editor.setPlainText(comment_probe)
        selection = editor.textCursor()
        selection.setPosition(0)
        selection.setPosition(
            len(comment_probe) - 1, QTextCursor.KeepAnchor)
        editor.setTextCursor(selection)
        QTest.keyClick(editor, Qt.Key_Slash, Qt.ControlModifier)
        commented_probe = "    # mov eax, 1\n\n# add eax, 2\n"
        assert editor.toPlainText() == commented_probe
        editor.document().undo()
        assert editor.toPlainText() == comment_probe
        editor.document().redo()
        assert editor.toPlainText() == commented_probe
        selection = editor.textCursor()
        selection.setPosition(0)
        selection.setPosition(
            len(commented_probe) - 1, QTextCursor.KeepAnchor)
        editor.setTextCursor(selection)
        QTest.keyClick(editor, Qt.Key_Slash, Qt.ControlModifier)
        assert editor.toPlainText() == comment_probe
        editor.setPlainText("    mov eax, 1")
        caret = editor.textCursor()
        caret.setPosition(8)
        editor.setTextCursor(caret)
        QTest.keyClick(editor, Qt.Key_Slash, Qt.ControlModifier)
        assert editor.toPlainText() == "    # mov eax, 1"
        assert editor.textCursor().positionInBlock() == 10
        QTest.keyClick(editor, Qt.Key_Slash, Qt.ControlModifier)
        assert editor.toPlainText() == "    mov eax, 1"
        assert editor.textCursor().positionInBlock() == 8
        editor.setPlainText(indentation_probe)
        caret = editor.textCursor()
        caret.setPosition(3)
        editor.setTextCursor(caret)
        QTest.keyClick(editor, Qt.Key_Tab)
        assert editor.document().firstBlock().text() == "mov  eax, 1"
        editor.document().undo()
        assert editor.toPlainText() == indentation_probe
        editor.setPlainText("    mov eax, 1\n")
        caret = editor.textCursor()
        caret.setPosition(8)
        editor.setTextCursor(caret)
        QTest.keyClick(editor, Qt.Key_Backtab, Qt.ShiftModifier)
        assert editor.toPlainText() == "mov eax, 1\n"
        assert editor.textCursor().positionInBlock() == 4
        editor.setPlainText(original_source)
        editor.document().setModified(False)
        save(win, outdir, "00a_assembly_compact")
        edge_source = "\n".join(
            ["    nop"] * 70 + [" " * 100 + "ad"])
        editor.setPlainText(edge_source)
        edge_cursor = editor.textCursor()
        edge_cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(edge_cursor)
        editor.ensureCursorVisible()
        settle(app)
        edge_scroll = editor.verticalScrollBar()
        edge_scroll.setValue(max(
            edge_scroll.minimum(), edge_scroll.value() - 15))
        settle(app)
        edge_caret = editor.mapToGlobal(
            editor.cursorRect().bottomLeft())
        assert editor.request_completion()
        settle(app)
        owner_bounds = QRect(
            win.mapToGlobal(QPoint(0, 0)), win.size())
        popup_frame = editor.completion.frameGeometry()
        assert owner_bounds.contains(popup_frame), (
            owner_bounds, popup_frame)
        assert popup_frame.top() < edge_caret.y()
        save(editor.completion, outdir, "01_opcode_compact_edge_popup")
        editor.completion.hide()
        editor.setPlainText(original_source)
        editor.document().setModified(False)
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

        # Workbench navigation chords outrank the popup's plain-Tab insertion:
        # completion closes, focus escapes, and the opcode token stays exact.
        editor.setPlainText("ad")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        assert editor.completion.list.count() == 2
        assert editor.completion.hint.text().startswith("2 matches ·")
        assert "prefix ad" in editor.completion.hint.accessibleDescription()
        save(editor.completion, outdir, "01_opcode_filtered_popup")
        QTest.keyClick(editor, Qt.Key_Tab, Qt.ControlModifier)
        settle(app)
        assert app.focusWidget() is win.assembly.diagnostics
        assert editor.toPlainText() == "ad"
        assert not editor.completion.isVisible()
        editor.setFocus()
        assert editor.request_completion()
        QTest.keyClick(
            editor, Qt.Key_Backtab,
            Qt.ControlModifier | Qt.ShiftModifier)
        settle(app)
        assert app.focusWidget() is win.assembly.run_btn
        assert editor.toPlainText() == "ad"
        assert not editor.completion.isVisible()

        editor.setPlainText("zzunknown")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        assert not editor.request_completion()
        assert not editor.completion.isVisible()
        assert win.assembly.status.text() == (
            "No Ventium/P54C opcode matches 'zzunknown'")
        assert win.assembly.status.toolTip() == win.assembly.status.text()
        assert win.assembly.status.accessibleDescription() == (
            win.assembly.status.text())
        assert "#e3b341" in win.assembly.status.styleSheet()
        save(win, outdir, "01_opcode_no_match")

        # Ctrl+Space / Complete remains a full catalogue reference even when
        # the cursor is not currently in an opcode token.
        editor.setPlainText(".intel_syntax noprefix")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        QTest.mouseClick(win.assembly.complete_btn, Qt.LeftButton)
        settle(app)
        assert app.focusWidget() is editor
        assert editor.completion.isVisible()
        assert editor.completion.list.count() == len(CATALOG)
        QTest.keyClick(editor, Qt.Key_Down)
        assert editor.completion.list.currentRow() == 1
        reference_text = editor.toPlainText()
        QTest.keyClick(editor, Qt.Key_End)
        assert editor.completion.list.currentRow() == len(CATALOG) - 1
        assert editor.completion.isVisible()
        QTest.keyClick(editor, Qt.Key_Home)
        assert editor.completion.list.currentRow() == 0
        assert editor.toPlainText() == reference_text
        assert editor.completion.isVisible()
        QTest.keyClick(editor, Qt.Key_Home, Qt.ControlModifier)
        assert editor.textCursor().position() == 0
        assert not editor.completion.isVisible()
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        QTest.mouseClick(win.assembly.complete_btn, Qt.LeftButton)
        settle(app)
        assert editor.completion.isVisible()
        QTest.keyClick(editor, Qt.Key_Escape)
        assert not editor.completion.isVisible()
        QTest.keyClick(editor, Qt.Key_Space, Qt.ControlModifier)
        settle(app)
        assert editor.completion.isVisible()
        assert editor.completion.parent() is editor
        screen = (
            QGuiApplication.screenAt(editor.completion.frameGeometry().center())
            or QGuiApplication.primaryScreen())
        assert screen is not None
        owner_rect = QRect(
            win.mapToGlobal(QPoint(0, 0)), win.size())
        assert (
            owner_rect.contains(editor.completion.frameGeometry())
            or screen.availableGeometry().contains(
                editor.completion.frameGeometry()))
        assert editor.completion.list.count() == len(CATALOG)
        assert editor.completion.accessibleName() == "Opcode completion popup"
        assert editor.completion.hint.accessibleName() == (
            "Completion keyboard help")
        assert editor.completion.hint.text().startswith(
            f"{len(CATALOG)} opcodes ·")
        assert "Type to search" in editor.completion.hint.text()
        assert "Enter/Tab insert" not in editor.completion.hint.text()
        assert "complete catalogue" in (
            editor.completion.hint.accessibleDescription())
        completion_accessible = editor.completion.list.accessibleDescription()
        assert f"{len(CATALOG)} matching opcodes" in completion_accessible
        assert "type to search" in completion_accessible
        assert "Home or End" in completion_accessible
        reference_source = editor.toPlainText()
        QTest.keyClicks(editor, "divide")
        settle(app)
        assert editor.toPlainText() == reference_source
        assert editor.completion.isVisible()
        assert editor.completion._reference_query == "divide"
        assert editor.completion.list.count() == 10
        assert editor.completion.hint.text().startswith(
            '10 matches · Search "divide"')
        assert 'reference search "divide"' in (
            editor.completion.list.accessibleDescription())
        searched_names = {
            editor.completion.list.item(i).data(Qt.UserRole).mnemonic
            for i in range(editor.completion.list.count())
        }
        assert {"div", "idiv", "fdivrp"} <= searched_names
        assert all(
            "divide" in editor.completion.list.item(i).data(
                Qt.UserRole).search_text
            for i in range(editor.completion.list.count()))
        save(editor.completion, outdir, "01_opcode_reference_search")
        QTest.keyClick(editor, Qt.Key_Delete)
        assert editor.completion.list.count() == len(CATALOG)
        QTest.keyClicks(editor, "zzzz")
        settle(app)
        assert editor.toPlainText() == reference_source
        assert editor.completion.isVisible()
        assert editor.completion.list.count() == 0
        assert editor.completion.info.preview.info is None
        assert editor.completion.hint.text().startswith(
            '0 matches · Search "zzzz"')
        assert "0 matching opcodes" in (
            editor.completion.list.accessibleDescription())
        QTest.keyClick(editor, Qt.Key_Backspace)
        assert editor.completion._reference_query == "zzz"
        QTest.keyClick(editor, Qt.Key_Delete)
        assert editor.completion._reference_query == ""
        assert editor.completion.list.count() == len(CATALOG)
        long_reference_query = "unavailable-opcode-reference-query-" * 2
        QTest.keyClicks(editor, long_reference_query)
        settle(app)
        assert editor.toPlainText() == reference_source
        assert editor.completion._reference_query == long_reference_query
        assert "…" in editor.completion.hint.text()
        assert (
            owner_rect.contains(editor.completion.frameGeometry())
            or screen.availableGeometry().contains(
                editor.completion.frameGeometry()))
        QTest.keyClick(editor, Qt.Key_Delete)
        assert editor.completion.list.count() == len(CATALOG)
        names = {
            editor.completion.list.item(i).data(Qt.UserRole).mnemonic
            for i in range(editor.completion.list.count())
        }
        assert {"add", "adc", "fdiv", "cmpxchg8b", "fsincos"} <= names
        add_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic == "add")
        add_list_text = editor.completion.list.item(add_row).text()
        assert add_list_text.count("add") == 1
        assert add_list_text.rstrip().endswith("dst, src")
        aaa_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic == "aaa")
        assert editor.completion.list.item(aaa_row).text().split() == [
            "aaa", "NP"]
        editor.completion.list.setCurrentRow(add_row)
        settle(app)
        assert editor.completion.info.preview.info.mnemonic == "add"
        assert editor.completion.info.description.text()
        assert editor.completion.info.preview.info.stages == ("F", "D", "X")
        assert editor.completion.info.preview.accessibleName() == (
            "Instruction pipeline preview")
        preview_accessible = (
            editor.completion.info.preview.accessibleDescription())
        assert "add dst, src" in preview_accessible
        assert "Stages F, then D, then X" in preview_accessible
        assert "Latency 1 cycle" in preview_accessible
        assert editor.completion.info.signature.accessibleName() == (
            "Instruction signature")
        assert editor.completion.info.description.accessibleName() == (
            "Instruction description")
        assert editor.completion.info.availability.accessibleName() == (
            "Instruction availability")
        assert editor.completion.info.availability.text() == "Availability · user"
        assert "#8b949e" in (
            editor.completion.info.availability.styleSheet())
        assert "cycle" not in editor.completion.info.availability.text()
        editor.completion.info.set_instruction(instruction_info("cpuid"))
        assert "SoC/co-simulation" in (
            editor.completion.info.availability.text())
        assert "#e3b341" in (
            editor.completion.info.availability.styleSheet())
        editor.completion.info.set_instruction(instruction_info("add"))
        save(editor.completion, outdir, "01_opcode_completion_popup")
        jnz_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic == "jnz")
        editor.completion.list.setCurrentRow(jnz_row)
        settle(app)
        assert editor.completion.info.description.text() == (
            "Jump when not equal / nonzero (ZF=0).")
        assert editor.completion.info.preview.info.pipe == "PV"
        save(editor.completion, outdir, "01_opcode_branch_popup")
        fdivrp_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic
            == "fdivrp")
        editor.completion.list.setCurrentRow(fdivrp_row)
        settle(app)
        assert editor.completion.info.description.text() == (
            "Store ST(0) divided by ST(i) in ST(i), then pop.")
        assert editor.completion.info.preview.info.pipe == "FP"
        save(editor.completion, outdir, "01_opcode_x87_popup")
        movsd_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic
            == "movsd")
        editor.completion.list.setCurrentRow(movsd_row)
        settle(app)
        assert editor.completion.info.description.text() == (
            "Move one dword from DS:[(E)SI] to ES:[(E)DI].")
        assert editor.completion.info.preview.info.stages == (
            "F", "D", "S", "M")
        assert editor.completion.info.availability.text() == (
            "Availability · user")
        save(editor.completion, outdir, "01_opcode_string_popup")
        dec_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic
            == "dec")
        editor.completion.list.setCurrentRow(dec_row)
        settle(app)
        assert editor.completion.info.description.text() == (
            "Subtract one from the destination while preserving the carry flag.")
        assert editor.completion.info.preview.info.pipe == "UV"
        save(editor.completion, outdir, "01_opcode_fibonacci_popup")
        lgdt_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic
            == "lgdt")
        editor.completion.list.setCurrentRow(lgdt_row)
        settle(app)
        assert editor.completion.info.description.text() == (
            "Load the GDTR limit and base from a six-byte memory operand.")
        assert editor.completion.info.preview.info.stages == (
            "F", "D", "S", "M")
        assert "system" in editor.completion.info.availability.text()
        save(editor.completion, outdir, "01_opcode_system_popup")
        editor.completion.list.setCurrentRow(add_row)
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

        # Pointer movement in the editor invalidates the popup's caret anchor.
        # Dismiss it on a click or wheel instead of leaving a detached overlay.
        editor.setPlainText("ad")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        QTest.mouseClick(
            editor.viewport(), Qt.LeftButton, Qt.NoModifier,
            editor.cursorRect().center())
        assert not editor.completion.isVisible()
        assert editor.toPlainText() == "ad"
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        completion_wheel = QWheelEvent(
            QPoint(20, 20), QPoint(20, 20), QPoint(), QPoint(0, 120),
            Qt.NoButton, Qt.ControlModifier, Qt.NoScrollPhase, False)
        QApplication.sendEvent(editor.viewport(), completion_wheel)
        assert completion_wheel.isAccepted()
        assert not editor.completion.isVisible()
        assert editor.font().pointSize() == 11
        QTest.keyClick(editor, Qt.Key_0, Qt.ControlModifier)
        editor.setPlainText(
            "ad\n" + "\n".join(f"nop # {line}" for line in range(200)))
        cursor = editor.textCursor()
        cursor.setPosition(2)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        assert editor.verticalScrollBar().maximum() > 0
        editor.verticalScrollBar().setValue(20)
        assert not editor.completion.isVisible()

        # Pointer completion is deliberately two-stage: one click previews
        # without touching source; a double-click inserts and restores typing
        # focus to the non-activating tooltip's editor.
        editor.setPlainText("ad")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        editor.setFocus()
        assert editor.request_completion()
        add_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic == "add")
        add_rect = editor.completion.list.visualItemRect(
            editor.completion.list.item(add_row))
        QTest.mouseClick(
            editor.completion.list.viewport(), Qt.LeftButton, Qt.NoModifier,
            add_rect.center())
        settle(app)
        assert editor.completion.list.currentRow() == add_row
        assert editor.completion.info.preview.info.mnemonic == "add"
        assert editor.toPlainText() == "ad"
        assert editor.completion.isVisible()
        assert app.focusWidget() is editor
        QTest.mouseDClick(
            editor.completion.list.viewport(), Qt.LeftButton, Qt.NoModifier,
            add_rect.center())
        settle(app)
        assert editor.toPlainText() == "add "
        assert not editor.completion.isVisible()
        assert app.focusWidget() is editor

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

        # Completion follows the source's mnemonic casing convention and uses
        # the entire replaced token even when the cursor sits in its middle.
        editor.setPlainText("AD")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        editor.completion.move_selection(1)  # adc, add
        editor.completion.accept_current()
        assert editor.toPlainText() == "ADD "

        editor.setPlainText("Mov")
        cursor = editor.textCursor()
        cursor.setPosition(2)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        mov_row = next(
            i for i in range(editor.completion.list.count())
            if editor.completion.list.item(i).data(Qt.UserRole).mnemonic == "mov")
        editor.completion.list.setCurrentRow(mov_row)
        editor.completion.accept_current()
        assert editor.toPlainText() == "Mov "

        # Numeric opcode characters keep filtering instead of dismissing the
        # popup; destructive edits refresh the broader prefix in place.
        editor.clear()
        QTest.keyClicks(editor, "cmpxchg8")
        settle(app)
        assert editor.completion.isVisible()
        assert editor.completion.list.count() == 1
        assert (
            editor.completion.list.currentItem().data(Qt.UserRole).mnemonic
            == "cmpxchg8b")
        editor.completion.accept_current()
        assert editor.toPlainText() == "cmpxchg8b "

        editor.setPlainText("cmpxchg8")
        cursor = editor.textCursor()
        cursor.movePosition(QTextCursor.End)
        editor.setTextCursor(cursor)
        assert editor.request_completion()
        assert editor.completion.list.count() == 1
        QTest.keyClick(editor, Qt.Key_Backspace)
        settle(app)
        assert editor.toPlainText() == "cmpxchg"
        assert editor.completion.isVisible()
        assert editor.completion.list.count() == 2  # cmpxchg, cmpxchg8b
        QTest.keyClick(editor, Qt.Key_Escape)

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
        QTest.keyClick(editor, Qt.Key_Backspace)
        assert editor.toPlainText() == ".loop:\n"
        editor.document().undo()
        assert editor.toPlainText() == ".loop:\n    "
        editor.setPlainText("      mov eax, 1\n")
        caret = editor.textCursor()
        caret.setPosition(6)
        editor.setTextCursor(caret)
        QTest.keyClick(editor, Qt.Key_Backspace)
        assert editor.toPlainText() == "    mov eax, 1\n"
        assert editor.textCursor().positionInBlock() == 4
        editor.setPlainText("\tmov eax, 1\n")
        caret = editor.textCursor()
        caret.setPosition(1)
        editor.setTextCursor(caret)
        QTest.keyClick(editor, Qt.Key_Backspace)
        assert editor.toPlainText() == "mov eax, 1\n"
        assert editor.textCursor().positionInBlock() == 0
        editor.setPlainText("mov ")
        editor.moveCursor(QTextCursor.End)
        QTest.keyClick(editor, Qt.Key_Backspace)
        assert editor.toPlainText() == "mov"
        editor.setPlainText("    mov eax, 1")
        assert not editor.completion.isVisible()
        editor.moveCursor(QTextCursor.End)
        QTest.keyClick(editor, Qt.Key_Home)
        assert editor.textCursor().positionInBlock() == 4
        QTest.keyClick(editor, Qt.Key_Home)
        assert editor.textCursor().positionInBlock() == 0
        QTest.keyClick(editor, Qt.Key_Home)
        assert editor.textCursor().positionInBlock() == 4
        editor.moveCursor(QTextCursor.End)
        QTest.keyClick(editor, Qt.Key_Home, Qt.ShiftModifier)
        assert editor.textCursor().selectedText() == "mov eax, 1"
        QTest.keyClick(editor, Qt.Key_Home, Qt.ControlModifier)
        assert editor.textCursor().position() == 0

        # A syntax error is line-linked and never starts a backend session.
        editor.setPlainText(
            ".intel_syntax noprefix\n.section .text\n.global _start\n_start:\n"
            "    frobnicate eax\n")
        QTest.mouseClick(win.assembly.build_btn, Qt.LeftButton)
        settle(app)
        assert app.focusWidget() is editor
        assert editor._error_line == 5
        assert "Build error highlighted at source line 5" in (
            editor.accessibleDescription())
        assert "Error" in win.assembly.diagnostics.toPlainText()
        assert "Assembly:5:" in win.assembly.diagnostics.toPlainText()
        assert str(source_module._GENERATED_DIR) not in (
            win.assembly.diagnostics.toPlainText())
        assert win.assembly.diagnostics.toPlainText().startswith(
            "→ Line 5: press Enter or double-click to jump")
        assert "Line 5" in win.assembly.diagnostics.toolTip()
        assert "press Enter" in (
            win.assembly.diagnostics.accessibleDescription())
        editor.moveCursor(QTextCursor.Start)
        win.assembly.diagnostics.setFocus()
        QTest.keyClick(win.assembly.diagnostics, Qt.Key_Return)
        settle(app)
        assert app.focusWidget() is editor
        assert editor.textCursor().blockNumber() + 1 == 5
        assert win.assembly.status.text() == "Build error at line 5"
        save(win, outdir, "01a_assembly_error_jump")
        assert not win._has_session()
        editor.insertPlainText(" ")
        assert editor._error_line is None
        assert "Build error highlighted" not in editor.accessibleDescription()
        assert not win.assembly.diagnostics.toPlainText()
        assert "#8b949e" in win.assembly.diagnostics.styleSheet()
        editor.document().setModified(False)

        # Successful assembler warnings stay runnable but are amber, source-
        # linked, and never masquerade as a clean green build.
        editor.setPlainText(
            ".intel_syntax noprefix\n.section .text\n.global _start\n_start:\n"
            '    .warning "check this schedule"\n'
            "    hlt\n")
        warning_result = win.assembly.build(False)
        settle(app)
        assert warning_result is not None
        assert warning_result.warning_line == 5
        assert editor._warning_line == 5 and editor._error_line is None
        assert "Build warning highlighted at source line 5" in (
            editor.accessibleDescription())
        assert win.assembly.diagnostics._severity == "warning"
        assert win.assembly.diagnostics.toPlainText().startswith(
            "→ Warning line 5: press Enter or double-click to jump")
        assert "Assembly:5:" in win.assembly.diagnostics.toPlainText()
        assert str(source_module._GENERATED_DIR) not in (
            win.assembly.diagnostics.toPlainText())
        assert "#e3b341" in win.assembly.diagnostics.styleSheet()
        assert "succeeded with warnings" in win.assembly.status.text()
        win.assembly.diagnostics.setFocus()
        QTest.keyClick(win.assembly.diagnostics, Qt.Key_Return)
        settle(app)
        assert app.focusWidget() is editor
        assert editor.textCursor().blockNumber() + 1 == 5
        assert win.assembly.status.text() == "Build warning at line 5"
        save(win, outdir, "01b_assembly_warning_jump")
        editor.insertPlainText(" ")
        assert editor._warning_line is None
        assert "Build warning highlighted" not in editor.accessibleDescription()
        assert not win.assembly.diagnostics.toPlainText()
        editor.document().setModified(False)

        # Assemble and run the editable template. The result (1+...+10) proves
        # execution used the authored bytes, not a demo fallback.
        win.assembly.new_template()
        editor.appendPlainText("# intentionally unsaved authoring session")
        assert win.workspace.tabText(1) == "Assembly *"
        assert editor.request_completion(force=True)
        assert editor.completion.isVisible()
        result = win.assembly.build(True)
        settle(app)
        assert result is not None
        assert not editor.completion.isVisible()
        assert "built-in template" in win.assembly.source_badge.text()
        assert win.assembly.source_badge.text().endswith("*")
        assert win.assembly.source_badge.accessibleDescription().endswith(
            "Unsaved changes.")
        assert win.workspace.currentWidget() is win.visualizer_tab
        assert win.open_action.text() == "Open program…"
        assert not win.save_source_action.isEnabled()
        assert all(not toolbar.isHidden() for toolbar in toolbars)
        assert all(action.isEnabled()
                   for action in win._transport_shortcut_actions)
        assert win.image_kind == "ELF"
        assert win._assembly_source_map == result.source_map
        assert win.pipeline.board._source_link_available
        assert win.pipeline.board._source_links == result.source_map
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
        live_rects = {}
        for lane in ("U", "V"):
            rect = next(
                rect for rect, cell_lane, _pc in board._lane_rects
                if cell_lane == lane)
            live_rects[lane] = rect
            line = result.source_map[board._lane_pcs[lane]]
            QTest.mouseMove(board, rect.center())
            settle(app)
            assert "in-flight instruction" in board.toolTip()
            assert f"Assembly line {line}" in board.toolTip()
            assert "double-click to open" in board.toolTip()
            QTest.mouseClick(board, Qt.LeftButton, Qt.NoModifier, rect.center())
            settle(app)
            live_lines[lane] = line
            assert editor._execution_line == line
            assert f"In-flight {lane}-lane" in editor._execution_tip
            assert (
                f"Source-linked selection: In-flight {lane}-lane instruction"
                in editor.accessibleDescription())
            assert f"source line {line}" in editor.accessibleDescription()
            assert win.workspace.tabText(1) == f"Assembly * · L{line}"
            assert f"Assembly line {line}" in win.action_hint.text()
        assert live_lines["U"] != live_lines["V"]

        # The same in-flight source link must be reachable without a pointer.
        # Home/End select the first/last occupied lane; Enter activates exactly
        # the highlighted lane and leaves the author on the Visualizer.
        board.setFocus()
        settle(app)
        assert app.focusWidget() is board
        QTest.keyClick(board, Qt.Key_Home)
        assert board._kbd_lane == "U"
        QTest.keyClick(board, Qt.Key_Return)
        settle(app)
        assert editor._execution_line == live_lines["U"]
        assert win.workspace.currentWidget() is win.visualizer_tab
        QTest.keyClick(board, Qt.Key_End)
        assert board._kbd_lane == "V"
        QTest.keyClick(board, Qt.Key_Return)
        settle(app)
        assert editor._execution_line == live_lines["V"]
        assert not win.pipeline.konata.plot.insns
        assert win.pipeline.konata.plot.width() >= (
            win.pipeline.konata.scroll.viewport().width())
        assert win.pipeline.konata.plot.height() >= (
            win.pipeline.konata.scroll.viewport().height())
        QTest.mouseDClick(
            board, Qt.LeftButton, Qt.NoModifier, live_rects["U"].center())
        settle(app)
        assert win.workspace.currentWidget() is win.assembly
        assert app.focusWidget() is editor
        assert editor._execution_line == live_lines["U"]
        assert f"Assembly line {live_lines['U']}" in win.action_hint.text()
        save(win, outdir, "02aa_live_uv_source_open")
        win.workspace.setCurrentWidget(win.visualizer_tab)
        settle(app)
        save(win, outdir, "02a_live_uv_source_link")

        # A live lane is not a retirement pin, but its source marker is still
        # time-specific. Advancing must clear that stale visual claim while
        # preserving the valid address map for the next live/retired selection.
        source_map_before = dict(win._assembly_source_map)
        cycle_before = win.backend.cycle_count()
        win.do_step(1, False)
        settle(app)
        assert win.backend.cycle_count() == cycle_before + 1
        assert win._pinned_n is None
        assert win._assembly_link_line is None
        assert editor._execution_line is None
        assert "Source-linked selection" not in editor.accessibleDescription()
        assert win.workspace.tabText(1) == "Assembly *"
        assert win._assembly_source_map == source_map_before
        assert win.assembly.mapping_current
        assert "prior in-flight source marker cleared" in (
            win.assembly.status.text())

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
        # Moving into a source editor hides every transport/status control, so
        # continuous execution must pause synchronously rather than running
        # invisibly behind the authoring workspace.
        cycle_before_authoring = win.backend.cycle_count()
        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        assert not win._running and not win.timer.isActive()
        assert win.backend.cycle_count() == cycle_before_authoring
        assert win.run_btn.text().strip() == "Run"
        assert "Paused continuous execution" in win.action_hint.text()
        win.workspace.setCurrentWidget(win.visualizer_tab)
        settle(app)
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
        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        real_reset = win.on_reset
        win.on_reset = lambda: False
        try:
            assert not win._run_assembly(
                candidate.elf_path, candidate.source_map)
        finally:
            win.on_reset = real_reset
        assert win.backend is old_backend
        assert win.image_bytes == old_bytes
        assert win._assembly_source_map == old_map
        assert editor._execution_line == old_line
        assert win.workspace.tabText(1) == old_tab
        assert win.workspace.currentWidget() is win.assembly
        assert win.assembly.status.text() == (
            "Build succeeded · run failed to start · "
            "previous Visualizer session preserved")
        assert win.assembly.status.toolTip() == win.assembly.status.text()
        assert win.assembly.status.accessibleDescription() == (
            win.assembly.status.text())
        assert "#e3b341" in win.assembly.status.styleSheet()
        assert win.action_hint.text() == (
            "Authored assembly built, but run failed to start — "
            "previous session preserved")

        save(win, outdir, "02_assembly_source_link")
        assert not win.reload_action.isEnabled()
        pre_reload_backend = win.backend
        pre_reload_cycle = win.backend.state().core_cyc
        pre_reload_map = dict(win._assembly_source_map)
        pre_reload_line = editor._execution_line
        win.reload_action.trigger()
        settle(app)
        assert win.backend is pre_reload_backend
        assert win.backend.state().core_cyc == pre_reload_cycle
        assert win._assembly_source_map == pre_reload_map
        assert editor._execution_line == pre_reload_line

        # Unpin is a pure linked-view operation: it clears every historical
        # selection cue and refreshes live registers immediately, while neither
        # advancing the RTL nor invalidating the still-current DWARF map.
        pinned_cycle = win.backend.state().core_cyc
        linked_map = dict(win._assembly_source_map)
        assert editor._execution_line is not None
        QTest.mouseClick(win.regs.unpin_btn, Qt.LeftButton)
        settle(app)
        assert win.backend.state().core_cyc == pinned_cycle
        assert win._pinned_n is None
        assert win.trace.tbl.currentRow() < 0
        assert plot.sel_row is None and plot.sel_pc is None
        assert plot.playhead is None and not plot._dep_edges
        assert editor._execution_line is None
        assert win.workspace.tabText(1) == "Assembly *"
        assert win._assembly_source_map == linked_map
        assert win.assembly.mapping_current
        assert "selection cleared" in win.assembly.status.text()
        assert win.regs.eip_name_lbl.text() == "EIP"

        editor.appendPlainText("# edited after build")
        assert not win.assembly.mapping_current
        assert "assemble again" in win.assembly.status.text()
        assert not win.assembly.diagnostics.toPlainText()
        assert "#8b949e" in win.assembly.diagnostics.styleSheet()
        assert editor._execution_line is None
        assert not win._assembly_source_map
        assert not board._source_link_available
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
        assert win.assembly._replacement_block_reason == "cancelled"
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
        preserved_assembly_path = win.assembly._path
        editor.document().setModified(True)
        real_open_dialog = QFileDialog.getOpenFileName
        QFileDialog.getOpenFileName = staticmethod(
            lambda *_args, **_kwargs: (str(invalid_assembly_path), ""))
        try:
            assert not win.assembly.open_source()
        finally:
            QFileDialog.getOpenFileName = staticmethod(real_open_dialog)
        assert editor.toPlainText() == preserved_source
        assert win.assembly._path == preserved_assembly_path
        assert editor.document().isModified()
        assert win.workspace.tabText(1) == "Assembly *"
        assert win.assembly.source_badge.text().endswith("*")
        assert "decode" in win.assembly.diagnostics.toPlainText().lower()
        assert win.assembly.status.text().startswith("Open failed · ")
        assert "invalid-encoding.s" in win.assembly.status.text()
        assert win.assembly.status.toolTip() == win.assembly.status.text()
        assert win.assembly.status.accessibleDescription() == (
            win.assembly.status.text())
        assert "#f85149" in win.assembly.status.styleSheet()
        assert win.assembly.diagnostics._severity == "error"
        assert win.assembly.status.text() in (
            win.assembly.diagnostics.accessibleDescription())
        assert win.action_hint.text() == win.assembly.status.text()
        settle(app)
        save(win, outdir, "00d_assembly_open_failure")
        editor.document().setModified(False)

        # Bare snippets get a generated fall-through HLT. Selecting it must
        # clear a previous linked line instead of falsely retaining that marker.
        assert win.assembly.set_source("mov eax, 7\n", "bare-snippet regression")
        snippet_result = win.assembly.build(True)
        settle(app)
        assert snippet_result is not None
        run_to_stop(win)
        settle(app)
        board = win.pipeline.board
        snippet_hlt_pc = board._lane_pcs["U"]
        assert snippet_hlt_pc not in snippet_result.source_map
        snippet_hlt_rect = next(
            rect for rect, lane, pc in board._lane_rects
            if lane == "U" and pc == snippet_hlt_pc)
        assert "no editor source line" in board.accessibleDescription()
        QTest.mouseMove(board, snippet_hlt_rect.center())
        settle(app)
        assert f"PC 0x{snippet_hlt_pc:08x}" in board.toolTip()
        assert "generated instruction" in board.toolTip()
        assert "no editor source line" in board.toolTip()
        assert "double-click" not in board.toolTip()
        assert board.cursor().shape() == Qt.ArrowCursor
        QTest.mouseDClick(
            board, Qt.LeftButton, Qt.NoModifier, snippet_hlt_rect.center())
        settle(app)
        assert win.workspace.currentWidget() is win.visualizer_tab
        assert editor._execution_line is None
        assert "has no linked Assembly line" in win.action_hint.text()
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
        assert win.c_source.status.text() == "Opened dropped-source.c"
        assert "Opened C source: dropped-source.c" in win.action_hint.text()
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
        saved_c_path = win.c_source._path
        win.c_source.editor.document().setModified(True)
        assert win.workspace.tabText(2) == "C *"
        blocked_c_save = str(blocked_artifacts / "cannot-save-c.c")
        real_save_dialog = QFileDialog.getSaveFileName
        QFileDialog.getSaveFileName = staticmethod(
            lambda *_args, **_kwargs:
            (blocked_c_save, "C source (*.c)"))
        try:
            assert not win.c_source.save_source(save_as=True)
        finally:
            QFileDialog.getSaveFileName = staticmethod(real_save_dialog)
        assert win.c_source._path == saved_c_path
        assert win.c_source.editor.document().isModified()
        assert win.workspace.tabText(2) == "C *"
        assert win.c_source.source_badge.text().endswith("*")
        assert app.focusWidget() is win.c_source.editor
        assert win.c_source.status.text().startswith("Save failed · ")
        assert "cannot-save-c.c" in win.c_source.status.text()
        assert win.c_source.status.toolTip() == win.c_source.status.text()
        assert win.c_source.status.accessibleDescription() == (
            win.c_source.status.text())
        assert "#f85149" in win.c_source.status.styleSheet()
        assert win.c_source.diagnostics._severity == "error"
        assert win.c_source.status.text() in (
            win.c_source.diagnostics.accessibleDescription())
        assert win.action_hint.text() == win.c_source.status.text()
        settle(app)
        save(win, outdir, "03d_c_save_failure")
        win.c_source.editor.document().setModified(False)
        invalid_c_path = Path(outdir) / "invalid-encoding.c"
        invalid_c_path.write_bytes(b"\x80\x81")
        preserved_c = win.c_source.editor.toPlainText()
        preserved_c_path = win.c_source._path
        win.c_source.editor.document().setModified(True)
        real_open_dialog = QFileDialog.getOpenFileName
        QFileDialog.getOpenFileName = staticmethod(
            lambda *_args, **_kwargs: (str(invalid_c_path), ""))
        try:
            assert not win.c_source.open_source()
        finally:
            QFileDialog.getOpenFileName = staticmethod(real_open_dialog)
        assert win.c_source.editor.toPlainText() == preserved_c
        assert win.c_source._path == preserved_c_path
        assert win.c_source.editor.document().isModified()
        assert win.workspace.tabText(2) == "C *"
        assert win.c_source.source_badge.text().endswith("*")
        assert "decode" in win.c_source.diagnostics.toPlainText().lower()
        assert win.c_source.status.text().startswith("Open failed · ")
        assert "invalid-encoding.c" in win.c_source.status.text()
        assert win.c_source.status.toolTip() == win.c_source.status.text()
        assert win.c_source.status.accessibleDescription() == (
            win.c_source.status.text())
        assert "#f85149" in win.c_source.status.styleSheet()
        assert win.c_source.diagnostics._severity == "error"
        assert win.c_source.status.text() in (
            win.c_source.diagnostics.accessibleDescription())
        assert win.action_hint.text() == win.c_source.status.text()
        settle(app)
        save(win, outdir, "03e_c_open_failure")
        win.c_source.editor.document().setModified(False)
        assert win.c_source.new_template()
        assert "#8b949e" in win.c_source.diagnostics.styleSheet()
        assert "#8b949e" in win.c_source.status.styleSheet()
        assert all(toolbar.isHidden() for toolbar in toolbars)
        assert win.open_action.text() == "Open C source…"
        assert win.new_source_action.isEnabled()
        assert win.new_source_action.text() == "New C U/V demo"
        assert win.save_source_action.isEnabled()
        assert win.save_source_as_action.isEnabled()
        assert win.save_source_as_action.text() == "Save C source as…"
        assert all(not action.isEnabled()
                   for action in win._transport_shortcut_actions)
        assert win.c_source.editor.accessibleName() == "C source editor"
        assert win.c_source.source_badge.accessibleName() == "C source identity"
        assert win.c_source.status.accessibleName() == (
            "C compiler workbench status")
        assert win.c_source.status.toolTip() == win.c_source.status.text()
        assert win.c_source.status.accessibleDescription() == (
            win.c_source.status.text())
        assert win.c_source.cursor_position.accessibleName() == (
            "Go to source line")
        assert win.c_source.cursor_position.text().startswith("Ln ")
        assert "column" in (
            win.c_source.cursor_position.accessibleDescription())
        assert win.c_source.source_badge.accessibleDescription() == (
            "Source origin built-in U/V demo; not saved. No unsaved changes.")
        assert win.c_source.template_btn.text() == "New U/V demo"
        assert win.c_source.optimization.accessibleName()
        assert win.c_source.optimization.count() == 4
        for index in range(win.c_source.optimization.count()):
            option = win.c_source.optimization.itemText(index)
            item_help = win.c_source.optimization.itemData(
                index, Qt.ToolTipRole)
            assert item_help.startswith(f"{option}: ")
            assert len(item_help) > len(option) + 12
        assert "U/V experiments" in win.c_source.optimization.toolTip()
        assert (win.c_source.optimization.accessibleDescription()
                == win.c_source.optimization.toolTip())
        assert win.c_source.diagnostics.accessibleName()
        assert win.c_source.diagnostics.placeholderText() == (
            "Compiler diagnostics appear here.")
        assert win.c_source.diagnostics.accessibleDescription() == (
            "No compiler diagnostics.")
        assert win.c_source.diagnostics.height() <= 54
        assert (win.c_source.diagnostics.lineWrapMode()
                == QPlainTextEdit.WidgetWidth)
        assert (win.c_source.diagnostics.horizontalScrollBarPolicy()
                == Qt.ScrollBarAlwaysOff)
        assert "Ctrl+Enter" in win.c_source.compile_btn.toolTip()
        assert "Ctrl+B" in win.c_source.compile_btn.toolTip()
        assert "Ctrl+N" in win.c_source.template_btn.toolTip()
        assert "Ctrl+Shift+S" in win.c_source.save_btn.toolTip()
        compile_requests = []
        real_compile = win.c_source.compile
        win.c_source.compile = lambda: compile_requests.append("compile")
        win.c_source.editor.setFocus()
        try:
            QTest.keyClick(
                win.c_source.editor, Qt.Key_B, Qt.ControlModifier)
            settle(app)
        finally:
            win.c_source.compile = real_compile
        assert compile_requests == ["compile"]
        win.resize(900, 620)
        settle(app)
        assert win.width() == 900
        assert win.minimumSizeHint().width() <= 900
        for control in (
                win.c_source.template_btn, win.c_source.open_btn,
                win.c_source.save_btn, win.c_source.optimization,
                win.c_source.compile_btn):
            corner = control.mapTo(win, control.rect().bottomRight())
            assert 0 <= corner.x() < win.width()
            assert 0 <= corner.y() < win.height()
            assert control.accessibleName()
            assert control.accessibleDescription() or control.toolTip()
        unnamed_c_focus = [
            (type(widget).__name__, widget.objectName())
            for widget in win.findChildren(QWidget)
            if (widget.isVisibleTo(win) and widget.isEnabled()
                and widget.focusPolicy() != Qt.NoFocus
                and not widget.accessibleName()
                and not (
                    widget.objectName() == "qt_spinbox_lineedit"
                    and widget.parentWidget() is not None
                    and widget.parentWidget().accessibleName()))
        ]
        assert not unnamed_c_focus, unnamed_c_focus
        badge_corner = win.c_source.source_badge.mapTo(
            win, win.c_source.source_badge.rect().bottomRight())
        cursor_corner = win.c_source.cursor_position.mapTo(
            win, win.c_source.cursor_position.rect().bottomRight())
        assert win.c_source.source_badge.isVisible()
        assert win.c_source.source_badge.width() >= 200
        c_badge_display = win.c_source.source_badge.displayText()
        assert QFontMetrics(
            win.c_source.source_badge.font()).horizontalAdvance(
                c_badge_display) <= (
                    win.c_source.source_badge.contentsRect().width() + 1)
        if QFontMetrics(
                win.c_source.source_badge.font()).horizontalAdvance(
                    win.c_source.source_badge.text()) > (
                        win.c_source.source_badge.contentsRect().width()):
            assert "…" in c_badge_display
        badge_path = os.path.join(
            outdir,
            "dual-fibonacci-scheduling-experiment-with-a-deliberately-"
            "long-source-name-for-compact-layout.c")
        original_badge_path = win.c_source._path
        original_badge_modified = (
            win.c_source.editor.document().isModified())
        win.c_source._path = badge_path
        win.c_source.editor.document().setModified(True)
        win.c_source._sync_source_badge()
        settle(app)
        assert win.c_source.source_badge.text().endswith(".c *")
        assert "…" in win.c_source.source_badge.displayText()
        assert win.c_source.source_badge.displayText().endswith("*")
        assert QFontMetrics(
            win.c_source.source_badge.font()).horizontalAdvance(
                win.c_source.source_badge.displayText()) <= (
                    win.c_source.source_badge.contentsRect().width() + 1)
        assert win.c_source.source_badge.toolTip() == (
            os.path.abspath(badge_path) + "\nUnsaved changes")
        save(win, outdir, "03aa_c_compact_long_source")
        win.c_source._path = original_badge_path
        win.c_source.editor.document().setModified(
            original_badge_modified)
        win.c_source._sync_source_badge()
        settle(app)
        assert 0 <= badge_corner.x() < win.width()
        assert 0 <= badge_corner.y() < win.height()
        assert 0 <= cursor_corner.x() < win.width()
        assert 0 <= cursor_corner.y() < win.height()
        assert (
            win.c_source.editor.width() >= 800
            and win.c_source.editor.height() >= 320)
        assert "Ctrl+Tab" in win.c_source.editor.accessibleDescription()
        assert "Ctrl+/" in win.c_source.editor.accessibleDescription()
        assert not win.reset_layout_action.isEnabled()
        QTest.keyClick(
            win.c_source.editor, Qt.Key_Plus, Qt.ControlModifier)
        assert win.c_source.editor.font().pointSize() == 11
        QTest.keyClick(
            win.c_source.editor, Qt.Key_0, Qt.ControlModifier)
        assert win.c_source.editor.font().pointSize() == 10
        original_c_source = win.c_source.editor.toPlainText()
        c_bracket_probe = (
            "int main(void) {\n"
            '    const char *ignored = "}"; // ]\n'
            '    const char *escaped = "\\"[still ignored]";\n'
            "    /* { [ ( also ignored */\n"
            "    return (1 + 2);\n"
            "}\n")
        win.c_source.editor.setPlainText(c_bracket_probe)
        caret = win.c_source.editor.textCursor()
        body_open = c_bracket_probe.index("{")
        body_close = c_bracket_probe.rindex("}")
        caret.setPosition(body_open + 1)
        win.c_source.editor.setTextCursor(caret)
        assert set(win.c_source.editor._matched_bracket_positions) == {
            body_open, body_close}
        assert set(
            win.c_source.editor._bracket_index.values()) == {
            "(", ")", "{", "}"}
        win.c_source.editor.setFocus()
        win.c_source.editor.setPlainText(original_c_source)
        QTest.keyClick(
            win.c_source.editor, Qt.Key_Tab, Qt.ControlModifier)
        settle(app)
        assert app.focusWidget() is win.c_source.diagnostics
        assert win.c_source.editor.toPlainText() == original_c_source
        win.c_source.editor.setFocus()
        QTest.keyClick(
            win.c_source.editor, Qt.Key_Backtab,
            Qt.ControlModifier | Qt.ShiftModifier)
        settle(app)
        assert app.focusWidget() is win.c_source.compile_btn
        assert win.c_source.editor.toPlainText() == original_c_source
        c_indent_probe = "int a;\nint b;\n"
        win.c_source.editor.setPlainText(c_indent_probe)
        selection = win.c_source.editor.textCursor()
        selection.setPosition(0)
        selection.setPosition(
            c_indent_probe.index("int b"), QTextCursor.KeepAnchor)
        win.c_source.editor.setTextCursor(selection)
        QTest.keyClick(win.c_source.editor, Qt.Key_Tab)
        assert win.c_source.editor.toPlainText() == (
            "    int a;\nint b;\n")
        QTest.keyClick(
            win.c_source.editor, Qt.Key_Backtab, Qt.ShiftModifier)
        assert win.c_source.editor.toPlainText() == c_indent_probe
        c_comment_probe = "    int a;\nint b;\n"
        win.c_source.editor.setPlainText(c_comment_probe)
        selection = win.c_source.editor.textCursor()
        selection.setPosition(0)
        selection.setPosition(
            win.c_source.editor.document().findBlockByNumber(1).position(),
            QTextCursor.KeepAnchor)
        win.c_source.editor.setTextCursor(selection)
        QTest.keyClick(
            win.c_source.editor, Qt.Key_Slash, Qt.ControlModifier)
        assert win.c_source.editor.toPlainText() == (
            "    // int a;\nint b;\n")
        selection = win.c_source.editor.textCursor()
        selection.setPosition(0)
        selection.setPosition(
            win.c_source.editor.document().findBlockByNumber(1).position(),
            QTextCursor.KeepAnchor)
        win.c_source.editor.setTextCursor(selection)
        QTest.keyClick(
            win.c_source.editor, Qt.Key_Slash, Qt.ControlModifier)
        assert win.c_source.editor.toPlainText() == c_comment_probe
        win.c_source.editor.setPlainText(original_c_source)
        win.c_source.editor.document().setModified(False)
        save(win, outdir, "03a_c_compact")
        win.resize(1500, 920)
        settle(app)
        win.c_source.highlighter.rehighlight()
        settle(app)
        c_main_line = next(
            number for number, text in enumerate(
                original_c_source.splitlines(), 1)
            if "int main(" in text)
        assert "#ff7b72" in format_colors(
            win.c_source.editor, c_main_line)  # int
        assert "#d2a8ff" in format_colors(
            win.c_source.editor, c_main_line)  # main
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
            win.c_source.editor, 1, trailing_comment) == "#7d8590"
        assert format_color_at(
            win.c_source.editor, 3, 4) == "#7d8590"
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
        QTest.mouseClick(win.c_source.compile_btn, Qt.LeftButton)
        settle(app)
        assert app.focusWidget() is win.c_source.editor
        assert win.c_source.editor._error_line == 3
        assert "Build error highlighted at source line 3" in (
            win.c_source.editor.accessibleDescription())
        assert "undeclared" in win.c_source.diagnostics.toPlainText()
        assert re.search(
            r"C source:3:\d+:\s+error:",
            win.c_source.diagnostics.toPlainText())
        assert str(source_module._GENERATED_DIR) not in (
            win.c_source.diagnostics.toPlainText())
        assert win.c_source.diagnostics.height() >= 92
        # The useful GCC error fits at the supported minimum width now that the
        # internal generated path is replaced with a compact editor-facing name.
        win.resize(900, 620)
        settle(app)
        primary_error = next(
            block for block in (
                win.c_source.diagnostics.document().findBlockByNumber(i)
                for i in range(
                    win.c_source.diagnostics.document().blockCount()))
            if block.text().startswith("C source:3:"))
        assert primary_error.layout().lineCount() == 1
        assert win.c_source.diagnostics.horizontalScrollBar().maximum() == 0
        assert win.c_source.diagnostics.toPlainText().startswith(
            "→ Line 3: press Enter or double-click to jump")
        win.c_source.editor.moveCursor(QTextCursor.Start)
        QTest.mouseDClick(
            win.c_source.diagnostics.viewport(), Qt.LeftButton,
            Qt.NoModifier, win.c_source.diagnostics.viewport().rect().center())
        settle(app)
        assert app.focusWidget() is win.c_source.editor
        assert win.c_source.editor.textCursor().blockNumber() + 1 == 3
        assert win.c_source.status.text() == "Compile error at line 3"
        save(win, outdir, "03b_c_error_jump")
        win.resize(1500, 920)
        settle(app)
        win.c_source.editor.insertPlainText(" ")
        assert win.c_source.editor._error_line is None
        assert "Build error highlighted" not in (
            win.c_source.editor.accessibleDescription())
        assert not win.c_source.diagnostics.toPlainText()
        assert win.c_source.diagnostics.height() <= 54
        assert "#8b949e" in win.c_source.diagnostics.styleSheet()
        win.c_source.editor.document().setModified(False)

        # GCC warnings generate editable assembly normally, but remain amber
        # and line-actionable in the originating C workbench.
        win.c_source.editor.setPlainText(
            "int main(void)\n{\n    int unused;\n    return 0;\n}\n")
        warning_assembly = win.c_source.compile()
        settle(app)
        assert warning_assembly is not None
        assert win.workspace.currentWidget() is win.assembly
        assert "C compiled with warnings" in win.assembly.status.text()
        assert "Alt+C" in win.assembly.status.text()
        assert "#e3b341" in win.assembly.status.styleSheet()
        assert "C compiled with warnings" in win.action_hint.text()
        assert win.c_source.editor._warning_line == 3
        assert win.c_source.editor._error_line is None
        assert "Build warning highlighted at source line 3" in (
            win.c_source.editor.accessibleDescription())
        assert win.c_source.diagnostics._severity == "warning"
        assert win.c_source.diagnostics.toPlainText().startswith(
            "→ Warning line 3: press Enter or double-click to jump")
        assert "unused variable" in win.c_source.diagnostics.toPlainText()
        assert "C source:3:" in win.c_source.diagnostics.toPlainText()
        assert str(source_module._GENERATED_DIR) not in (
            win.c_source.diagnostics.toPlainText())
        assert win.c_source.diagnostics.height() >= 92
        assert "#e3b341" in win.c_source.diagnostics.styleSheet()
        assert win.c_source.status.text() == (
            "Compiled with warnings · assembly tab is ready")
        win.workspace.setCurrentWidget(win.c_source)
        settle(app)
        win.c_source.diagnostics.setFocus()
        QTest.keyClick(win.c_source.diagnostics, Qt.Key_Return)
        settle(app)
        assert app.focusWidget() is win.c_source.editor
        assert win.c_source.editor.textCursor().blockNumber() + 1 == 3
        assert win.c_source.status.text() == "Compile warning at line 3"
        save(win, outdir, "03c_c_warning_jump")
        win.c_source.editor.insertPlainText(" ")
        assert win.c_source.editor._warning_line is None
        assert "Build warning highlighted" not in (
            win.c_source.editor.accessibleDescription())
        assert not win.c_source.diagnostics.toPlainText()
        assert win.c_source.diagnostics.height() <= 54
        win.c_source.editor.document().setModified(False)

        # If generated C output cannot replace dirty Assembly because the
        # requested protective save fails, distinguish that I/O failure from
        # a user cancellation and retain both source buffers.
        assembly_before_failed_replacement = (
            win.assembly.editor.toPlainText())
        win.assembly.editor.appendPlainText(
            "# unsaved before generated replacement")
        win.assembly._path = str(
            blocked_artifacts / "replacement-save.s")
        win.assembly._sync_source_badge()
        assert win.workspace.tabText(1).startswith("Assembly *")
        real_warning = QMessageBox.warning
        QMessageBox.warning = staticmethod(
            lambda *_args, **_kwargs: QMessageBox.Save)
        try:
            replacement_output = win.c_source.compile()
        finally:
            QMessageBox.warning = real_warning
        settle(app)
        assert replacement_output is not None
        assert win.workspace.currentWidget() is win.c_source
        assert win.assembly.editor.toPlainText().startswith(
            assembly_before_failed_replacement)
        assert win.assembly.editor.document().isModified()
        assert win.assembly._replacement_block_reason == "save_failed"
        assert win.assembly.status.text().startswith("Save failed · ")
        assert "replacement-save.s" in win.assembly.status.text()
        assert win.assembly.diagnostics._severity == "error"
        assert win.c_source.status.text() == (
            "C compiled · Assembly save failed; generated Assembly "
            "was not opened")
        assert win.c_source.status.toolTip() == win.c_source.status.text()
        assert win.c_source.status.accessibleDescription() == (
            win.c_source.status.text())
        assert "#e3b341" in win.c_source.status.styleSheet()
        assert win.action_hint.text() == (
            "C compiled, but Assembly save failed — generated assembly "
            "was not opened")
        save(win, outdir, "03f_c_replacement_save_failure")
        win.assembly.editor.document().setModified(False)

        # Compile real C, inspect/edit the emitted assembly, then assemble/run it.
        win.c_source.new_template()
        generated = win.c_source.compile()
        settle(app)
        assert generated is not None
        assert win.workspace.currentWidget() is win.assembly
        assert app.focusWidget() is win.assembly.editor
        assert "C compiler (-O2)" in win.assembly.source_badge.text()
        assert "not saved" in win.assembly.source_badge.text()
        assert win.assembly.source_badge.accessibleDescription() == (
            "Source origin C compiler (-O2); not saved. No unsaved changes.")
        assert "call main" in win.assembly.editor.toPlainText()
        assert "Assembly generated from C compiler" in win.assembly.status.text()
        assert win.assembly.status.toolTip() == win.assembly.status.text()
        assert win.assembly.status.accessibleDescription() == (
            win.assembly.status.text())
        save(win, outdir, "04_c_generated_assembly")
        # The green origin/result text describes one exact editor revision.
        # Editing generated source must retire it just like a build diagnostic.
        generated_text = win.assembly.editor.toPlainText()
        win.assembly.editor.appendPlainText("# scheduling experiment")
        assert not win.assembly.diagnostics.toPlainText()
        assert "assemble again" in win.assembly.status.text()
        win.assembly.editor.setPlainText(generated_text)
        win.assembly.editor.document().setModified(False)
        c_result = win.assembly.build(True)
        settle(app)
        assert c_result is not None and win.workspace.currentWidget() is win.visualizer_tab
        run_to_stop(win)
        expected_fibonacci = 0x198C09A0
        assert win.backend.state().gpr[0] == expected_fibonacci
        dual_cycles = win.backend.state().core_cyc
        dual_stats = win.pipeline.stats()
        assert dual_stats["vret"] > 400
        wrapper_line = next(
            number for number, text in enumerate(
                win.assembly.editor.toPlainText().splitlines(), 1)
            if text.strip() == "_start:")
        c_row = next(
            r
            for r in range(win.trace.tbl.rowCount())
            if win.trace.tbl.item(r, 3).text() == "V"
            and win.trace.tbl.item(r, 6).text().lower().startswith("add ")
            and int(win.trace.tbl.item(r, 4).text(), 16) in c_result.source_map
            and c_result.source_map[
                int(win.trace.tbl.item(r, 4).text(), 16)] < wrapper_line)
        c_pc = int(win.trace.tbl.item(c_row, 4).text(), 16)
        win.trace.tbl.setCurrentCell(c_row, 0)
        settle(app)
        assert win.assembly.editor._execution_line == c_result.source_map[c_pc]
        assert "Retired V-lane instruction" in (
            win.assembly.editor.accessibleDescription())
        assert f"source line {c_result.source_map[c_pc]}" in (
            win.assembly.editor.accessibleDescription())
        assert "Retired V-lane instruction" in win.assembly.status.text()
        assert win._pinned_n == int(win.trace.tbl.item(c_row, 0).text())
        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        save(win, outdir, "05_c_run_source_link")

        # The built-in C template must be a real U/V experiment, not a
        # constant-folded Fibonacci ornament. Re-run the exact generated ELF
        # with pairing disabled and require identical output plus an obvious
        # cycle advantage from the default dual-issue run.
        win.workspace.setCurrentWidget(win.visualizer_tab)
        win.cyc_cb.setChecked(False)
        assert win.on_reset()
        run_to_stop(win)
        assert win.backend.state().gpr[0] == expected_fibonacci
        single_cycles = win.backend.state().core_cyc
        single_stats = win.pipeline.stats()
        assert single_stats["vret"] == 0
        assert single_cycles >= dual_cycles * 1.20, (
            f"dual Fibonacci advantage too small: "
            f"single={single_cycles}, dual={dual_cycles}")
        win.cyc_cb.setChecked(True)

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
        assert "Retired FP-lane instruction" in win.assembly.status.text()
        assert " · FP · " in win.action_hint.text()
        win.workspace.setCurrentWidget(win.assembly)
        settle(app)
        save(win, outdir, "06_c_x87_source_link")

        # Keep shutdown non-interactive: the C source was injected directly to
        # exercise dirty replacement, so save it as acceptance-test evidence.
        win.workspace.setCurrentWidget(win.c_source)
        assert win.c_source.diagnostics.toPlainText()
        old_optimization = win.c_source.optimization.currentText()
        replacement_optimization = (
            "-O1" if old_optimization != "-O1" else "-O2")
        win.c_source.optimization.setCurrentText(replacement_optimization)
        assert replacement_optimization in win.c_source.optimization.toolTip()
        assert (win.c_source.optimization.accessibleDescription()
                == win.c_source.optimization.toolTip())
        assert not win.c_source.diagnostics.toPlainText()
        assert (
            f"Optimization changed to {replacement_optimization}"
            in win.c_source.status.text())
        assert "#e3b341" in win.c_source.status.styleSheet()
        win.c_source._path = os.path.join(outdir, "x87-workbench.c")
        assert win.c_source.save_source()
        print("OK GUI authoring: completion/preview, syntax/error lines, "
              f"assembly result=55, C dual Fibonacci result=0x"
              f"{expected_fibonacci:08x} ({single_cycles}→{dual_cycles} clocks), "
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
