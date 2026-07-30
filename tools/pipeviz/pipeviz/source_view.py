# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Integrated assembly/C authoring workbenches for pipeviz."""
from dataclasses import dataclass
from pathlib import Path
import os
import re
import shutil
import subprocess

from PySide6.QtCore import Qt, QPoint, QRect, QSize, Signal, QRegularExpression
from PySide6.QtGui import (
    QColor, QFont, QFontMetrics, QGuiApplication, QKeySequence, QPainter, QShortcut,
    QSyntaxHighlighter, QTextCharFormat, QTextCursor, QTextFormat,
)
from PySide6.QtWidgets import (
    QComboBox, QFileDialog, QFrame, QHBoxLayout, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QMessageBox, QPlainTextEdit, QPushButton, QSizePolicy, QSplitter,
    QTextEdit, QToolButton, QVBoxLayout, QWidget,
)

from .isa_catalog import CATALOG, MNEMONICS, instruction_info


_TOOL_DIR = Path(__file__).resolve().parent.parent
_GENERATED_DIR = _TOOL_DIR / ".generated"
_ENTRY = 0x08048000


def _mono(size=10, bold=False):
    font = QFont("monospace")
    font.setStyleHint(QFont.Monospace)
    font.setPointSize(size)
    font.setBold(bold)
    return font


class _LineNumberArea(QWidget):
    def __init__(self, editor):
        super().__init__(editor)
        self.editor = editor
        self.setAccessibleName("Source line numbers")
        self.setToolTip("Click a line number to select that source line")

    def sizeHint(self):
        return QSize(self.editor.line_number_area_width(), 0)

    def paintEvent(self, event):
        self.editor.paint_line_numbers(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            y = int(
                event.position().y()
                if hasattr(event, "position") else event.y())
            cursor = self.editor.cursorForPosition(QPoint(0, y))
            block = cursor.block()
            top = round(self.editor.blockBoundingGeometry(block).translated(
                self.editor.contentOffset()).top())
            height = round(self.editor.blockBoundingRect(block).height())
            if block.isValid() and top <= y < top + height:
                cursor.select(QTextCursor.LineUnderCursor)
                self.editor.setTextCursor(cursor)
                self.editor.setFocus(Qt.MouseFocusReason)
                event.accept()
                return
        super().mousePressEvent(event)


class CodeEditor(QPlainTextEdit):
    """Monospace editor with line numbers and independent execution/error marks."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFont(_mono(10))
        self.setLineWrapMode(QPlainTextEdit.NoWrap)
        self.setTabStopDistance(QFontMetrics(self.font()).horizontalAdvance(" ") * 4)
        self.setCenterOnScroll(True)
        self._line_area = _LineNumberArea(self)
        self._execution_line = None
        self._error_line = None
        self._execution_tip = ""
        self._find_text = ""
        self._find_ranges = []
        self._find_truncated = False
        self.blockCountChanged.connect(self._update_line_area_width)
        self.updateRequest.connect(self._update_line_area)
        self.cursorPositionChanged.connect(self._refresh_selections)
        self.textChanged.connect(self._rebuild_find_ranges)
        self._update_line_area_width()
        self._refresh_selections()

    def line_number_area_width(self):
        digits = max(2, len(str(max(1, self.blockCount()))))
        return 12 + QFontMetrics(self.font()).horizontalAdvance("9") * digits

    def _update_line_area_width(self, _count=0):
        self.setViewportMargins(self.line_number_area_width(), 0, 0, 0)

    def _update_line_area(self, rect, dy):
        if dy:
            self._line_area.scroll(0, dy)
        else:
            self._line_area.update(0, rect.y(), self._line_area.width(), rect.height())
        if rect.contains(self.viewport().rect()):
            self._update_line_area_width()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        cr = self.contentsRect()
        self._line_area.setGeometry(
            QRect(cr.left(), cr.top(), self.line_number_area_width(), cr.height()))

    def paint_line_numbers(self, event):
        painter = QPainter(self._line_area)
        painter.fillRect(event.rect(), QColor("#0b0f14"))
        block = self.firstVisibleBlock()
        number = block.blockNumber()
        top = round(self.blockBoundingGeometry(block).translated(
            self.contentOffset()).top())
        bottom = top + round(self.blockBoundingRect(block).height())
        fm = QFontMetrics(self.font())
        while block.isValid() and top <= event.rect().bottom():
            if block.isVisible() and bottom >= event.rect().top():
                line = number + 1
                if line == self._error_line:
                    color = QColor("#f85149")
                elif line == self._execution_line:
                    color = QColor("#7ce0e8")
                elif line == self.textCursor().blockNumber() + 1:
                    color = QColor("#c9d1d9")
                else:
                    color = QColor("#586069")
                painter.setPen(color)
                painter.drawText(
                    0, top, self._line_area.width() - 6, fm.height(),
                    Qt.AlignRight, str(line))
            block = block.next()
            top = bottom
            bottom = top + round(self.blockBoundingRect(block).height())
            number += 1

    def _selection(self, line, color, full_width=True):
        if line is None or line < 1 or line > self.blockCount():
            return None
        sel = QTextEdit.ExtraSelection()
        cursor = QTextCursor(self.document().findBlockByNumber(line - 1))
        sel.cursor = cursor
        sel.format.setBackground(QColor(color))
        if full_width:
            sel.format.setProperty(QTextFormat.FullWidthSelection, True)
        return sel

    def _refresh_selections(self):
        selections = []
        current = self._selection(
            self.textCursor().blockNumber() + 1, "#121a24")
        if current is not None:
            selections.append(current)
        for start, end in self._find_ranges:
            sel = QTextEdit.ExtraSelection()
            cursor = QTextCursor(self.document())
            cursor.setPosition(start)
            cursor.setPosition(end, QTextCursor.KeepAnchor)
            sel.cursor = cursor
            sel.format.setBackground(QColor("#5a4515"))
            selections.append(sel)
        execution = self._selection(self._execution_line, "#10313a")
        if execution is not None:
            execution.format.setProperty(QTextFormat.OutlinePen, QColor("#39c5cf"))
            selections.append(execution)
        error = self._selection(self._error_line, "#351418")
        if error is not None:
            error.format.setProperty(QTextFormat.OutlinePen, QColor("#f85149"))
            selections.append(error)
        self.setExtraSelections(selections)
        self._line_area.update()

    def mark_execution_line(self, line, tooltip=""):
        self._execution_line = int(line) if line else None
        self._execution_tip = tooltip
        self._refresh_selections()
        if self._execution_line:
            cursor = QTextCursor(
                self.document().findBlockByNumber(self._execution_line - 1))
            self.setTextCursor(cursor)
            self.centerCursor()
            self.setToolTip(tooltip)
        else:
            self.setToolTip("")

    def mark_error_line(self, line):
        self._error_line = int(line) if line else None
        self._refresh_selections()
        if self._error_line:
            cursor = QTextCursor(
                self.document().findBlockByNumber(self._error_line - 1))
            self.setTextCursor(cursor)
            self.centerCursor()

    def clear_marks(self):
        self._execution_line = None
        self._error_line = None
        self.setToolTip("")
        self._refresh_selections()

    def keyPressEvent(self, event):
        # Preserve indentation in both workbenches, and indent one level after
        # an assembly label or C block/case opener. QPlainTextEdit otherwise
        # drops back to column zero on every newline.
        modifiers = event.modifiers()
        if (event.text() == "}" and not (modifiers
                                         & (Qt.ControlModifier | Qt.AltModifier
                                            | Qt.MetaModifier))):
            # Match the Enter-after-"{" behavior: when a closing C brace is
            # typed on an otherwise blank indented line, remove exactly one
            # indentation level first.  Never touch indentation before content
            # or a selected range, so this remains safe in assembly/data text.
            cursor = self.textCursor()
            before = cursor.block().text()[:cursor.positionInBlock()]
            if not cursor.hasSelection() and before and not before.strip():
                trim = 1 if before.endswith("\t") else min(
                    4, len(before) - len(before.rstrip(" ")))
                if trim:
                    cursor.movePosition(QTextCursor.Left, QTextCursor.KeepAnchor, trim)
                    cursor.removeSelectedText()
                    self.setTextCursor(cursor)
            super().keyPressEvent(event)
            return
        if (event.key() in (Qt.Key_Return, Qt.Key_Enter)
                and not (modifiers
                         & (Qt.ControlModifier | Qt.AltModifier
                            | Qt.MetaModifier))):
            cursor = self.textCursor()
            before = cursor.block().text()[:cursor.positionInBlock()]
            leading = re.match(r"\s*", before).group(0)
            extra = "    " if before.rstrip().endswith(("{", ":")) else ""
            super().keyPressEvent(event)
            self.insertPlainText(leading + extra)
            return
        super().keyPressEvent(event)

    def _rebuild_find_ranges(self):
        self._find_ranges = []
        self._find_truncated = False
        if self._find_text:
            cursor = QTextCursor(self.document())
            while len(self._find_ranges) < 2000:
                found = self.document().find(self._find_text, cursor)
                if found.isNull():
                    break
                self._find_ranges.append(
                    (found.selectionStart(), found.selectionEnd()))
                cursor.setPosition(found.selectionEnd())
            if len(self._find_ranges) == 2000:
                self._find_truncated = not self.document().find(
                    self._find_text, cursor).isNull()
        self._refresh_selections()
        return len(self._find_ranges)

    def set_find_text(self, text):
        self._find_text = text or ""
        return self._rebuild_find_ranges()

    def find_text(self, direction=1):
        """Select the next/previous match, wrapping at document boundaries."""
        ranges = self._find_ranges
        if not ranges:
            return 0, 0
        cursor = self.textCursor()
        current = (cursor.selectionStart(), cursor.selectionEnd())
        try:
            index = ranges.index(current)
            index = (index + (1 if direction > 0 else -1)) % len(ranges)
        except ValueError:
            pos = cursor.selectionEnd() if direction > 0 else cursor.selectionStart()
            if direction > 0:
                index = next(
                    (i for i, (start, _end) in enumerate(ranges)
                     if start >= pos), 0)
            else:
                index = next(
                    (i for i in range(len(ranges) - 1, -1, -1)
                     if ranges[i][1] <= pos), len(ranges) - 1)
        start, end = ranges[index]
        found = QTextCursor(self.document())
        found.setPosition(start)
        found.setPosition(end, QTextCursor.KeepAnchor)
        self.setTextCursor(found)
        self.centerCursor()
        return index + 1, len(ranges)


class SourceFindBar(QFrame):
    """Compact, shared find UI for the Assembly and C source editors."""

    def __init__(self, editor, parent=None):
        super().__init__(parent)
        self.editor = editor
        self.setFrameShape(QFrame.StyledPanel)
        self.setStyleSheet("QFrame{background:#161b22;border:1px solid #30363d;}")
        row = QHBoxLayout(self)
        row.setContentsMargins(4, 2, 4, 2)
        row.setSpacing(4)
        label = QLabel("Find")
        label.setStyleSheet("border:0;color:#8b949e;")
        row.addWidget(label)
        self.query = QLineEdit()
        self.query.setAccessibleName("Source search")
        self.query.setPlaceholderText("text in source")
        self.query.setToolTip("Case-insensitive literal search in this source editor")
        self.query.setClearButtonEnabled(True)
        label.setBuddy(self.query)
        row.addWidget(self.query, 1)
        self.count = QLabel("")
        self.count.setAccessibleName("Source search match count")
        self.count.setAccessibleDescription("No active source search")
        self.count.setFixedWidth(70)
        self.count.setAlignment(Qt.AlignCenter)
        self.count.setStyleSheet("border:0;color:#8b949e;")
        row.addWidget(self.count)
        self.previous_btn = QToolButton()
        self.previous_btn.setText("↑")
        self.previous_btn.setAccessibleName("Previous source match")
        self.previous_btn.setToolTip("Previous match (Shift+F3)")
        self.next_btn = QToolButton()
        self.next_btn.setText("↓")
        self.next_btn.setAccessibleName("Next source match")
        self.next_btn.setToolTip("Next match (F3 or Enter)")
        self.close_btn = QToolButton()
        self.close_btn.setText("×")
        self.close_btn.setAccessibleName("Close source search")
        self.close_btn.setToolTip("Close source search (Escape)")
        for button in (self.previous_btn, self.next_btn, self.close_btn):
            button.setAutoRaise(True)
            button.setFixedSize(24, 22)
            row.addWidget(button)
        self.query.textChanged.connect(self._query_changed)
        self.query.returnPressed.connect(lambda: self.find(1))
        self.previous_btn.clicked.connect(lambda: self.find(-1))
        self.next_btn.clicked.connect(lambda: self.find(1))
        self.close_btn.clicked.connect(self.hide_find)
        QShortcut(QKeySequence("Ctrl+F"), editor).activated.connect(self.show_find)
        QShortcut(QKeySequence("F3"), editor).activated.connect(lambda: self.find(1))
        QShortcut(QKeySequence("Shift+F3"), editor).activated.connect(
            lambda: self.find(-1))
        QShortcut(QKeySequence("Shift+Return"), self.query).activated.connect(
            lambda: self.find(-1))
        QShortcut(QKeySequence("Escape"), self.query).activated.connect(
            self.hide_find)
        self._set_navigation(False)
        self.hide()

    def show_find(self):
        cursor = self.editor.textCursor()
        seed = cursor.selectedText()
        if not seed or "\n" in seed:
            probe = QTextCursor(cursor)
            probe.select(QTextCursor.WordUnderCursor)
            seed = probe.selectedText()
        self.show()
        if seed and len(seed) <= 80:
            self.query.setText(seed)
        self.query.setFocus(Qt.ShortcutFocusReason)
        self.query.selectAll()

    def hide_find(self):
        self.query.clear()
        self.editor.set_find_text("")
        self.hide()
        self.editor.setFocus(Qt.ShortcutFocusReason)

    def _query_changed(self, text):
        total = self.editor.set_find_text(text)
        if not text:
            self.count.setText("")
            self.count.setAccessibleDescription("No active source search")
            self._set_navigation(False)
            return
        self._set_navigation(total > 0)
        if total:
            self._set_count(*self.editor.find_text(1))
        else:
            self._set_count(0, 0)

    def _set_navigation(self, enabled):
        self.previous_btn.setEnabled(enabled)
        self.next_btn.setEnabled(enabled)

    def _set_count(self, index, total):
        suffix = "+" if self.editor._find_truncated else ""
        self.count.setText(
            f"{index} / {total}{suffix}" if total else "No matches")
        if not total:
            description = (
                f"No matches for {self.query.text()!r} in this source editor")
        elif self.editor._find_truncated:
            description = (
                f"Match {index} of at least {total} for "
                f"{self.query.text()!r}; result count capped at 2000")
        else:
            description = (
                f"Match {index} of {total} for {self.query.text()!r}")
        self.count.setAccessibleDescription(description)

    def find(self, direction):
        if not self.query.text():
            return
        self._set_count(*self.editor.find_text(direction))


def _fmt(color, bold=False, italic=False):
    out = QTextCharFormat()
    out.setForeground(QColor(color))
    out.setFontWeight(QFont.Bold if bold else QFont.Normal)
    out.setFontItalic(italic)
    return out


class AssemblyHighlighter(QSyntaxHighlighter):
    def __init__(self, document):
        super().__init__(document)
        mnemonic_pattern = "|".join(
            re.escape(word) for word in sorted(MNEMONICS, key=len, reverse=True))
        registers = (
            r"(?:e?[abcd]x|e?(?:si|di|sp|bp)|[abcd][lh]|"
            r"[cdefgs]s|cr[0-4]|dr[0-7]|st(?:\([0-7]\))?)")
        self.rules = [
            (QRegularExpression(
                rf"\b(?:{mnemonic_pattern})\b",
                QRegularExpression.CaseInsensitiveOption), _fmt("#79c0ff", True)),
            (QRegularExpression(
                rf"\b{registers}\b",
                QRegularExpression.CaseInsensitiveOption), _fmt("#56d364")),
            (QRegularExpression(r"\b(?:0x[0-9a-fA-F]+|[0-9]+)\b"), _fmt("#f2cc60")),
            (QRegularExpression(r"[\[\]+*,:;-]"), _fmt("#8b949e")),
            # Apply syntactic heads last so a label/directive named like an
            # opcode or register retains its structural color.
            (QRegularExpression(r"^\s*\.[A-Za-z_][\w.]*"), _fmt("#ff7b72")),
            (QRegularExpression(r"^\s*[.$A-Za-z_][\w.$]*:"), _fmt("#d2a8ff", True)),
        ]
        self.string = _fmt("#a5d6ff")
        self.comment = _fmt("#6e7681", italic=True)

    def highlightBlock(self, text):
        for pattern, form in self.rules:
            it = pattern.globalMatch(text)
            while it.hasNext():
                match = it.next()
                self.setFormat(match.capturedStart(), match.capturedLength(), form)
        # In GNU as, ';' separates statements; '#' and '//' introduce
        # comments. Scan quotes so .asciz "https://…" stays a string rather
        # than turning grey at its slashes.
        index = 0
        while index < len(text):
            if text.startswith("//", index) or text[index] == "#":
                self.setFormat(index, len(text) - index, self.comment)
                return
            if text[index] in "\"'":
                quote = text[index]
                start = index
                index += 1
                while index < len(text):
                    if text[index] == "\\":
                        index = min(len(text), index + 2)
                        continue
                    index += 1
                    if text[index - 1] == quote:
                        break
                self.setFormat(start, index - start, self.string)
                continue
            index += 1


class CHighlighter(QSyntaxHighlighter):
    _KEYWORDS = (
        "auto break case char const continue default do double else enum extern "
        "float for goto if inline int long register restrict return short signed "
        "sizeof static struct switch typedef union unsigned void volatile while "
        "_Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary "
        "_Noreturn _Static_assert _Thread_local"
    ).split()

    def __init__(self, document):
        super().__init__(document)
        words = "|".join(self._KEYWORDS)
        self.rules = [
            (QRegularExpression(r"\b[A-Za-z_]\w*(?=\s*\()"), _fmt("#d2a8ff")),
            # Keywords such as if/for/while also precede '('; apply them after
            # the generic call rule so they remain keywords, not functions.
            (QRegularExpression(rf"\b(?:{words})\b"), _fmt("#ff7b72", True)),
            (QRegularExpression(
                r"\b(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?)\b"),
             _fmt("#f2cc60")),
            (QRegularExpression(r"^\s*#.*$"), _fmt("#79c0ff")),
        ]
        self.string = _fmt("#a5d6ff")
        self.comment = _fmt("#6e7681", italic=True)

    def highlightBlock(self, text):
        for pattern, form in self.rules:
            it = pattern.globalMatch(text)
            while it.hasNext():
                match = it.next()
                self.setFormat(match.capturedStart(), match.capturedLength(), form)
        # Apply strings and comments with a tiny stateful lexer. Independent
        # regex rules incorrectly turned the tail of "https://…" or "/*…*/"
        # into a comment, and could color quoted text inside a real comment.
        self.setCurrentBlockState(0)
        index = 0
        if self.previousBlockState() == 1:
            end = text.find("*/")
            if end < 0:
                self.setFormat(0, len(text), self.comment)
                self.setCurrentBlockState(1)
                return
            self.setFormat(0, end + 2, self.comment)
            index = end + 2
        while index < len(text):
            if text.startswith("//", index):
                self.setFormat(index, len(text) - index, self.comment)
                return
            if text.startswith("/*", index):
                end = text.find("*/", index + 2)
                if end < 0:
                    self.setFormat(index, len(text) - index, self.comment)
                    self.setCurrentBlockState(1)
                    return
                self.setFormat(index, end + 2 - index, self.comment)
                index = end + 2
                continue
            if text[index] in "\"'":
                quote = text[index]
                start = index
                index += 1
                while index < len(text):
                    if text[index] == "\\":
                        index = min(len(text), index + 2)
                        continue
                    index += 1
                    if text[index - 1] == quote:
                        break
                self.setFormat(start, index - start, self.string)
                continue
            index += 1


def _gas_statement_span(text, position):
    """Return the current GAS statement, respecting quotes and comments.

    Semicolons separate statements only outside quoted data, and ``#``/``//``
    start comments only outside quotes. ``None`` means the cursor is in a
    comment, where completion/preview must remain inactive.
    """
    position = max(0, min(int(position), len(text)))
    start = 0
    end = len(text)
    quote = None
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue
        if char in "\"'":
            quote = char
            index += 1
            continue
        if char == "#" or text.startswith("//", index):
            if position >= index:
                return None
            end = index
            break
        if char == ";":
            if index < position:
                start = index + 1
            else:
                end = index
                break
        index += 1
    return start, end


class InstructionPipelinePreview(QWidget):
    """Small AP-500-style preview used both persistently and in completion."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.info = None
        self.setMinimumHeight(105)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setAccessibleName("Instruction pipeline preview")
        self.setAccessibleDescription(
            "No instruction selected; place the cursor on an opcode")

    def set_instruction(self, info):
        self.info = info
        if info is None:
            self.setAccessibleDescription(
                "No instruction selected; place the cursor on an opcode")
        else:
            lane = {
                "UV": "U or V, pairable",
                "PU": "U, may lead a pair",
                "PV": "V slot or branch",
                "NP": "U, non-pairable",
                "FP": "x87 floating-point lane",
                "SYS": "system or microcode",
            }.get(info.pipe, info.pipe)
            stages = ", then ".join(info.stages or ("F", "D", "X"))
            self.setAccessibleDescription(
                f"{info.signature}. Lane {lane}. Stages {stages}. "
                f"Latency {info.latency}. Availability {info.availability}.")
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("#0b0f14"))
        if self.info is None:
            painter.setPen(QColor("#586069"))
            painter.setFont(_mono(9))
            painter.drawText(self.rect(), Qt.AlignCenter, "Place the cursor on an opcode")
            return
        info = self.info
        colors = {
            "F": "#4a9eff", "D": "#39c5cf", "X": "#3fb950", "M": "#f0883e",
            "W": "#7d8fc9", "S": "#a87f55", "FP": "#bc8cff", "=": "#7a828d",
            "!": "#f85149", ".": "#6e7681",
        }
        painter.setFont(_mono(8, True))
        painter.setPen(QColor("#8b949e"))
        painter.drawText(QRect(4, 3, 48, 16), Qt.AlignVCenter, "lane")
        lane = {
            "UV": "U or V (pairable)",
            "PU": "U; may lead a pair",
            "PV": "V slot / branch",
            "NP": "U; non-pairable",
            "FP": "x87 FP lane",
            "SYS": "system / microcode",
        }.get(info.pipe, info.pipe)
        painter.setPen(QColor("#e6edf3"))
        painter.drawText(QRect(52, 3, self.width() - 56, 16), Qt.AlignVCenter, lane)
        x, y, cell_h = 5, 27, 26
        stages = info.stages or ("F", "D", "X")
        cell_w = max(34, min(62, (self.width() - 10) // max(1, len(stages))))
        for stage in stages:
            rect = QRect(x, y, cell_w - 3, cell_h)
            painter.fillRect(rect, QColor(colors.get(stage, "#6e7681")))
            painter.setPen(QColor("#0d1117"))
            painter.drawText(rect, Qt.AlignCenter, stage)
            x += cell_w
        painter.setPen(QColor("#8b949e"))
        painter.setFont(_mono(8))
        painter.drawText(
            QRect(5, 62, self.width() - 10, 36),
            Qt.AlignLeft | Qt.AlignVCenter | Qt.TextWordWrap,
            f"{info.pipe} · {info.latency}")


class InstructionInfoPane(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 4, 6, 4)
        layout.setSpacing(4)
        self.signature = QLabel("Instruction preview")
        self.signature.setAccessibleName("Instruction signature")
        self.signature.setStyleSheet("font-weight:bold;color:#e6edf3;")
        self.signature.setWordWrap(True)
        self.description = QLabel(
            "Place the cursor on an opcode or open completion with Ctrl+Space.")
        self.description.setAccessibleName("Instruction description")
        self.description.setWordWrap(True)
        self.description.setStyleSheet("color:#9aa3ad;")
        self.availability = QLabel("")
        self.availability.setAccessibleName("Instruction availability")
        self.availability.setWordWrap(True)
        self.availability.setStyleSheet("color:#e3b341;font-size:9px;")
        self.preview = InstructionPipelinePreview()
        layout.addWidget(self.signature)
        layout.addWidget(self.description)
        layout.addWidget(self.availability)
        layout.addWidget(self.preview)
        layout.addStretch(1)

    def set_instruction(self, info):
        self.preview.set_instruction(info)
        if info is None:
            self.signature.setText("Instruction preview")
            self.description.setText(
                "Place the cursor on an opcode or open completion with Ctrl+Space.")
            self.availability.setText("")
            return
        self.signature.setText(info.signature)
        self.description.setText(info.description)
        # Pipe class and latency are already rendered directly beneath this
        # label in the miniature pipeline. Repeating both here produced a dense,
        # near-duplicate line in the compact Assembly sidebar.
        self.availability.setText(f"Availability · {info.availability}")


class CompletionPopup(QFrame):
    accepted = Signal(str)

    def __init__(self, editor):
        # Keep tooltip window semantics while tying lifetime to its editor; a
        # parentless popup could survive application-window teardown if closed
        # while completion was still visible.
        super().__init__(editor, Qt.ToolTip)
        self.editor = editor
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.setStyleSheet(
            "QFrame{background:#161b22;border:1px solid #484f58;}"
            "QListWidget{border:0;background:#0d1117;}"
            "QListWidget::item{padding:3px;}"
            "QListWidget::item:selected{background:#1f6feb;color:white;}")
        self.setAccessibleName("Opcode completion popup")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(1, 1, 1, 1)
        layout.setSpacing(0)
        body = QHBoxLayout()
        body.setSpacing(0)
        self.list = QListWidget()
        self.list.setAccessibleName("Ventium opcode completions")
        self.list.setFixedWidth(285)
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.list.setTextElideMode(Qt.ElideRight)
        self.info = InstructionInfoPane()
        self.info.setMinimumWidth(330)
        body.addWidget(self.list)
        body.addWidget(self.info, 1)
        layout.addLayout(body, 1)
        self.hint = QLabel(
            "↑/↓ choose · PgUp/PgDn jump · Enter/Tab insert · "
            "Esc close · double-click insert")
        self.hint.setAccessibleName("Completion keyboard help")
        self.hint.setStyleSheet(
            "border:0;border-top:1px solid #30363d;"
            "color:#8b949e;background:#0d1117;padding:3px 6px;")
        layout.addWidget(self.hint)
        self.resize(650, 257)
        self.list.currentItemChanged.connect(self._current_changed)
        self.list.itemDoubleClicked.connect(lambda _item: self.accept_current())

    def _current_changed(self, current, _previous):
        self.info.set_instruction(current.data(Qt.UserRole) if current else None)

    def show_for(self, prefix):
        prefix = (prefix or "").lower()
        matches = [
            info for info in CATALOG
            if not prefix or info.mnemonic.startswith(prefix)
        ]
        self.list.clear()
        for info in matches:
            item = QListWidgetItem(
                f"{info.mnemonic:<10}  {info.pipe:<3}  {info.signature}")
            item.setData(Qt.UserRole, info)
            item.setToolTip(info.description)
            self.list.addItem(item)
        if not matches:
            self.hide()
            return
        scope = f"prefix {prefix}" if prefix else "the complete catalogue"
        self.list.setAccessibleDescription(
            f"{len(matches)} matching opcodes for {scope}. "
            "Use arrows or Page Up and Page Down to choose, Enter or Tab to "
            "insert, Escape to close, or double-click an entry to insert it.")
        self.list.setCurrentRow(0)
        cursor_rect = self.editor.cursorRect()
        below = self.editor.mapToGlobal(cursor_rect.bottomLeft())
        above = self.editor.mapToGlobal(cursor_rect.topLeft())
        screen = QGuiApplication.screenAt(below) or QGuiApplication.primaryScreen()
        pos = below
        if screen is not None:
            available = screen.availableGeometry()
            width, height = self.width(), self.height()
            x = max(
                available.left(),
                min(below.x(), available.right() - width + 1))
            y = below.y()
            if y + height - 1 > available.bottom():
                y = above.y() - height
            y = max(
                available.top(),
                min(y, available.bottom() - height + 1))
            pos.setX(x)
            pos.setY(y)
        self.move(pos)
        self.show()
        # Native window-frame margins are only known after the tooltip gets a
        # platform window. Correct the final frame, not just its client rect.
        if screen is not None:
            frame = self.frameGeometry()
            available = screen.availableGeometry()
            dx = (
                available.left() - frame.left()
                if frame.left() < available.left() else
                available.right() - frame.right()
                if frame.right() > available.right() else 0)
            dy = (
                available.top() - frame.top()
                if frame.top() < available.top() else
                available.bottom() - frame.bottom()
                if frame.bottom() > available.bottom() else 0)
            if dx or dy:
                self.move(self.x() + dx, self.y() + dy)

    def move_selection(self, delta):
        if not self.isVisible() or self.list.count() == 0:
            return
        self.list.setCurrentRow(
            max(0, min(self.list.count() - 1, self.list.currentRow() + delta)))

    def accept_current(self):
        item = self.list.currentItem()
        if item is not None:
            self.accepted.emit(item.data(Qt.UserRole).mnemonic)
        self.hide()


def _match_completion_case(mnemonic, sample):
    """Apply the casing convention of a partially typed opcode."""
    if sample.isupper():
        return mnemonic.upper()
    if len(sample) > 1 and sample[0].isupper() and sample[1:].islower():
        return mnemonic.capitalize()
    return mnemonic


class AssemblyEditor(CodeEditor):
    completionNotice = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.highlighter = AssemblyHighlighter(self.document())
        self.completion = CompletionPopup(self)
        self.completion.accepted.connect(self._insert_completion)
        self._completion_span = None
        self._completion_insertable = True
        self._completion_case_sample = ""

    def _opcode_prefix(self):
        """Return the mnemonic prefix only when the cursor is in opcode position."""
        cursor = self.textCursor()
        line = cursor.block().text()
        position = cursor.positionInBlock()
        span = _gas_statement_span(line, position)
        if span is None:
            return None
        # GAS accepts multiple statements separated by ';'. Completion belongs
        # to the current quote-aware statement, not a ';' inside string data.
        start, _end = span
        before = line[start:position]
        word = re.search(r"([A-Za-z]\w*)$", before)
        prefix = word.group(1) if word else ""
        stem = before[:word.start()] if word else before
        context = re.fullmatch(
            r"\s*(?:[.$A-Za-z_][\w.$]*:\s*)?"
            r"(?:(?:lock|rep|repe|repz|repne|repnz)\s+)*",
            stem, re.IGNORECASE)
        return prefix if context else None

    def request_completion(self, force=False):
        prefix = self._opcode_prefix()
        cursor = self.textCursor()
        if prefix is None:
            if not force:
                self.completion.hide()
                return False
            prefix = ""
            self._completion_span = None
            self._completion_insertable = False
            self._completion_case_sample = ""
        else:
            suffix = re.match(
                r"\w*", cursor.block().text()[cursor.positionInBlock():])
            suffix_text = suffix.group(0) if suffix else ""
            suffix_len = len(suffix_text)
            self._completion_span = (
                cursor.position() - len(prefix),
                cursor.position() + suffix_len)
            self._completion_insertable = True
            self._completion_case_sample = prefix + suffix_text
        self.completion.show_for(prefix)
        return self.completion.isVisible()

    def _insert_completion(self, mnemonic):
        if not self._completion_insertable:
            self._completion_span = None
            self.completionNotice.emit(
                "Completion is reference-only here — move the cursor to an opcode position")
            return
        mnemonic = _match_completion_case(
            mnemonic, self._completion_case_sample)
        if self._completion_span is None:
            cursor = self.textCursor()
            cursor.select(QTextCursor.WordUnderCursor)
        else:
            start, end = self._completion_span
            cursor = QTextCursor(self.document())
            cursor.setPosition(start)
            cursor.setPosition(end, QTextCursor.KeepAnchor)
        cursor.insertText(mnemonic)
        if not self.toPlainText()[cursor.position():cursor.position() + 1].isspace():
            cursor.insertText(" ")
        self.setTextCursor(cursor)
        self._completion_span = None
        self._completion_case_sample = ""

    def keyPressEvent(self, event):
        if self.completion.isVisible():
            if event.key() in (Qt.Key_Up, Qt.Key_Down, Qt.Key_PageUp, Qt.Key_PageDown):
                delta = {
                    Qt.Key_Up: -1, Qt.Key_Down: 1,
                    Qt.Key_PageUp: -8, Qt.Key_PageDown: 8,
                }[event.key()]
                self.completion.move_selection(delta)
                event.accept()
                return
            if event.key() in (Qt.Key_Return, Qt.Key_Enter, Qt.Key_Tab):
                self.completion.accept_current()
                event.accept()
                return
            if event.key() == Qt.Key_Escape:
                self.completion.hide()
                event.accept()
                return
        if (event.modifiers() & Qt.ControlModifier
                and event.key() == Qt.Key_Space):
            self.request_completion(force=True)
            event.accept()
            return
        super().keyPressEvent(event)
        completion_edit = (
            event.text().isalnum()
            or event.key() in (Qt.Key_Backspace, Qt.Key_Delete))
        if completion_edit:
            prefix = self._opcode_prefix()
            if prefix is not None and len(prefix) >= 2:
                self.request_completion()
            elif self.completion.isVisible():
                self.completion.hide()
        elif self.completion.isVisible() and event.key() not in (
                Qt.Key_Shift, Qt.Key_Control):
            self.completion.hide()

    def focusOutEvent(self, event):
        super().focusOutEvent(event)
        if not self.completion.underMouse():
            self.completion.hide()


@dataclass
class AssemblyBuild:
    elf_path: str
    source_map: dict
    log: str


class BuildFailure(RuntimeError):
    def __init__(self, message, line=None):
        super().__init__(message)
        self.line = line


def _require_tool(name):
    path = shutil.which(name)
    if path is None:
        raise BuildFailure(
            f"Required tool '{name}' was not found in PATH. Install GNU binutils/GCC.")
    return path


def _run_tool(command, timeout=20):
    try:
        proc = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout,
            env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BuildFailure(str(error)) from error
    output = (proc.stdout + proc.stderr).strip()
    if proc.returncode:
        line = None
        match = re.search(
            r":(\d+):(?:\d+:)?\s*(?:fatal\s+)?error:",
            output, re.IGNORECASE)
        if match:
            line = int(match.group(1))
        raise BuildFailure(output or f"{command[0]} exited with {proc.returncode}", line)
    return output


def _source_map(elf_path, source_name, prefix_lines, source_lines):
    objdump = _require_tool("objdump")
    decoded = _run_tool(
        [objdump, "--dwarf=decodedline", str(elf_path)])
    result = {}
    base = os.path.basename(source_name)
    # GNU objdump decoded-line rows are:
    #   assembly.s            12          0x8048005
    row_re = re.compile(
        rf"^\s*{re.escape(base)}\s+(\d+)\s+0x([0-9a-fA-F]+)\b")
    for row in decoded.splitlines():
        match = row_re.match(row)
        if not match:
            continue
        generated_line = int(match.group(1))
        source_line = generated_line - prefix_lines
        if 1 <= source_line <= source_lines:
            result[int(match.group(2), 16)] = source_line
    return result


def assemble_source(source):
    """Assemble/link editor text and return ELF path plus PC→editor-line map."""
    if not source.strip():
        raise BuildFailure(
            "Assembly source is empty. Add at least one instruction before building.")
    assembler = _require_tool("as")
    linker = _require_tool("ld")
    source_path = _GENERATED_DIR / "assembly.s"
    object_path = _GENERATED_DIR / "assembly.o"
    elf_path = _GENERATED_DIR / "assembly.elf"

    original = source.rstrip() + "\n"
    prefix = []
    if not re.search(r"(?im)^\s*\.intel_syntax\b", original):
        prefix.append(".intel_syntax noprefix")
    auto_start = not re.search(r"(?im)^\s*_start\s*:", original)
    if auto_start:
        prefix.extend((".section .text", ".global _start", "_start:"))
    # A bare instruction snippet should be safe to run without making the user
    # learn ELF boilerplate first. Its synthesized fall-through HLT is outside
    # the editor mapping; complete sources with an explicit _start stay exact.
    suffix = ["hlt"] if auto_start else []
    body = "\n".join(prefix + [original.rstrip()] + suffix + [""]) + "\n"
    try:
        _GENERATED_DIR.mkdir(parents=True, exist_ok=True)
        source_path.write_text(body, encoding="utf-8")
    except OSError as error:
        raise BuildFailure(
            f"Cannot prepare assembly build directory '{_GENERATED_DIR}': "
            f"{error}") from error
    try:
        as_log = _run_tool([
            assembler, "--32", "--gdwarf-5", "--noexecstack",
            "-o", str(object_path), str(source_path),
        ])
    except BuildFailure as error:
        line = error.line - len(prefix) if error.line else None
        raise BuildFailure(str(error), line if line and line > 0 else None) from error
    ld_log = _run_tool([
        linker, "-m", "elf_i386", "-Ttext", f"0x{_ENTRY:08x}",
        "-e", "_start", "-o", str(elf_path), str(object_path),
    ])
    mapping = _source_map(
        elf_path, source_path.name, len(prefix), len(original.splitlines()))
    if not mapping:
        raise BuildFailure(
            "Assembly succeeded, but no PC-to-source line table was generated.")
    return AssemblyBuild(str(elf_path), mapping, "\n".join(
        part for part in (as_log, ld_log, f"Built {elf_path}") if part))


def compile_c_source(source, optimization="-O2"):
    """Compile freestanding 32-bit C to editable GNU Intel assembly text."""
    compiler = _require_tool("gcc")
    source_path = _GENERATED_DIR / "program.c"
    asm_path = _GENERATED_DIR / "program-from-c.s"
    try:
        _GENERATED_DIR.mkdir(parents=True, exist_ok=True)
        source_path.write_text(source.rstrip() + "\n", encoding="utf-8")
    except OSError as error:
        raise BuildFailure(
            f"Cannot prepare C build directory '{_GENERATED_DIR}': "
            f"{error}") from error
    command = [
        compiler, "-m32", "-march=pentium", "-mtune=pentium",
        "-std=gnu11", optimization, "-ffreestanding", "-fno-builtin",
        "-fno-tree-loop-distribute-patterns",
        "-mno-mmx", "-mno-sse", "-mno-sse2",
        "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
        "-Werror=implicit-int",
        "-fno-pic", "-fno-pie",
        "-fno-stack-protector", "-fno-asynchronous-unwind-tables",
        "-fno-ident", "-masm=intel", "-S",
        "-o", str(asm_path), str(source_path),
    ]
    try:
        log = _run_tool(command)
    except BuildFailure as error:
        raise BuildFailure(str(error), error.line) from error
    try:
        assembly = asm_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise BuildFailure(
            f"Cannot read generated assembly '{asm_path}': {error}") from error
    if not re.search(r"(?m)^main:\s*$", assembly):
        raise BuildFailure(
            "Compilation produced no 'main' symbol. Define int main(void) as the entry.")
    wrapper = """

# pipeviz freestanding entry wrapper
.section .text
.global _start
.type _start, @function
_start:
    call main
    hlt
.size _start, .-_start
"""
    return assembly.rstrip() + wrapper, log or "Compiled C to GNU Intel assembly"


_ASM_TEMPLATE = """.intel_syntax noprefix
.section .text
.global _start
_start:
    mov eax, 0
    mov ecx, 10
.sum:
    add eax, ecx
    dec ecx
    jnz .sum
    hlt
"""

_C_TEMPLATE = """/* Freestanding 32-bit C: no libc; main returns into pipeviz's HLT wrapper. */
volatile unsigned result;

int main(void)
{
    unsigned a = 0, b = 1;
    for (unsigned i = 0; i < 12; ++i) {
        unsigned next = a + b;
        a = b;
        b = next;
    }
    result = a;
    return (int)a;
}
"""


class _Diagnostics(QPlainTextEdit):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setReadOnly(True)
        self.setFont(_mono(8))
        self.setMaximumBlockCount(1000)
        self.setPlaceholderText("Build diagnostics appear here.")
        self.setStyleSheet("color:#8b949e;background:#0b0f14;")

    def reset(self):
        self.setStyleSheet("color:#8b949e;background:#0b0f14;")
        self.clear()

    def success(self, text):
        self.setStyleSheet("color:#3fb950;background:#0b0f14;")
        self.setPlainText(text)

    def failure(self, text):
        self.setStyleSheet("color:#ff7b72;background:#0b0f14;")
        self.setPlainText(text)


def _confirm_source_replacement(view, label, action):
    """Protect edited source before replacing it or closing the application."""
    if not view.editor.document().isModified():
        return True
    choice = QMessageBox.warning(
        view, f"Unsaved {label} source",
        f"The {label} source has unsaved changes. Save it before {action}?",
        QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel,
        QMessageBox.Save)
    if choice == QMessageBox.Cancel:
        return False
    if choice == QMessageBox.Save:
        return bool(view.save_source())
    return True


def _default_save_suffix(path, selected_filter, filter_prefix, suffix):
    """Honor the typed-file filter when a save dialog returns a bare name."""
    if (path and selected_filter.startswith(filter_prefix)
            and not Path(path).suffix):
        return path + suffix
    return path


def _sync_source_badge(badge, editor, path, origin):
    """Render persistent source identity independently of transient build status."""
    dirty = editor.document().isModified()
    if path:
        full = os.path.abspath(path)
        identity = os.path.basename(path)
        suffix = " *" if dirty else ""
    else:
        full = f"{origin} (not saved)"
        identity = origin
        suffix = " *" if dirty else " · not saved"
    display = QFontMetrics(badge.font()).elidedText(
        identity, Qt.ElideMiddle, 215)
    badge.setText(f"source · {display}{suffix}")
    badge.setToolTip(
        full + ("\nUnsaved changes" if dirty else ""))
    badge.setStyleSheet(
        "color:#e3b341;padding:2px;" if dirty else
        "color:#79c0ff;padding:2px;" if not path else
        "color:#8b949e;padding:2px;")


class AssemblyView(QWidget):
    runRequested = Signal(str, object)
    statusChanged = Signal(str)
    dirtyChanged = Signal(bool)

    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(5)
        controls = QHBoxLayout()
        title = QLabel("Assembly workbench")
        title.setStyleSheet("font-size:14px;font-weight:bold;")
        controls.addWidget(title)
        dialect = QLabel("GNU Intel syntax · 32-bit P54C")
        dialect.setStyleSheet("color:#8b949e;")
        controls.addWidget(dialect)
        controls.addStretch(1)
        self.template_btn = QPushButton("New template")
        self.template_btn.setToolTip("Replace the editor with a runnable sum-loop template")
        self.open_btn = QPushButton("Open…")
        self.open_btn.setToolTip("Open GNU Intel-syntax source (Ctrl+O)")
        self.save_btn = QPushButton("Save as…")
        self.save_btn.setToolTip("Save assembly source under a chosen name")
        self.complete_btn = QPushButton("Complete")
        self.complete_btn.setToolTip("Open opcode completion (Ctrl+Space)")
        self.build_btn = QPushButton("Assemble")
        self.build_btn.setToolTip("Check, assemble, and link without loading the RTL")
        self.run_btn = QPushButton("Assemble + Run")
        self.run_btn.setToolTip("Assemble, load in the Visualizer, and reset (Ctrl+Enter)")
        self.run_btn.setStyleSheet(
            "background:#238636;color:white;font-weight:bold;border:1px solid #2ea043;")
        for button in (
                self.template_btn, self.open_btn, self.save_btn,
                self.complete_btn, self.build_btn, self.run_btn):
            controls.addWidget(button)
        layout.addLayout(controls)

        split = QSplitter(Qt.Horizontal)
        self.editor = AssemblyEditor()
        self.editor.setAccessibleName("Assembly source editor")
        self.editor.setPlainText(_ASM_TEMPLATE)
        self.find_bar = SourceFindBar(self.editor)
        layout.addWidget(self.find_bar)
        sidebar = QWidget()
        side = QVBoxLayout(sidebar)
        side.setContentsMargins(4, 0, 0, 0)
        side.addWidget(QLabel("<b>Instruction preview</b>"))
        self.info = InstructionInfoPane()
        side.addWidget(self.info)
        side.addWidget(QLabel("<b>Build diagnostics</b>"))
        self.diagnostics = _Diagnostics()
        self.diagnostics.setAccessibleName("Assembly build diagnostics")
        side.addWidget(self.diagnostics, 1)
        split.addWidget(self.editor)
        split.addWidget(sidebar)
        split.setStretchFactor(0, 4)
        split.setStretchFactor(1, 2)
        split.setSizes([850, 420])
        layout.addWidget(split, 1)
        status_row = QHBoxLayout()
        status_row.setContentsMargins(0, 0, 0, 0)
        self.status = QLabel(
            "Ready · Ctrl+Space completes opcodes · Ctrl+Enter assembles and runs")
        self.status.setStyleSheet("color:#8b949e;padding:2px;")
        status_row.addWidget(self.status, 1)
        self.source_badge = QLabel()
        self.source_badge.setAccessibleName("Assembly source identity")
        self.source_badge.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        self.source_badge.setMaximumWidth(330)
        status_row.addWidget(self.source_badge)
        layout.addLayout(status_row)

        self._built_revision = -1
        self._diagnostic_revision = -1
        self._source_map = {}
        self._path = None
        self._source_origin = "built-in template"
        self._last_dir = str(_TOOL_DIR)
        self.editor.cursorPositionChanged.connect(self._cursor_instruction)
        self.editor.textChanged.connect(self._source_changed)
        self.editor.completionNotice.connect(self._completion_notice)
        self.editor.document().modificationChanged.connect(
            self.dirtyChanged.emit)
        self.editor.document().modificationChanged.connect(
            lambda _dirty: self._sync_source_badge())
        self.template_btn.clicked.connect(self.new_template)
        self.open_btn.clicked.connect(self.open_source)
        self.save_btn.clicked.connect(
            lambda: self.save_source(save_as=True))
        self.complete_btn.clicked.connect(
            self._request_completion)
        self.build_btn.clicked.connect(lambda: self.build(False))
        self.run_btn.clicked.connect(lambda: self.build(True))
        QShortcut(QKeySequence("Ctrl+Return"), self.editor).activated.connect(
            lambda: self.build(True))
        self._cursor_instruction()
        self.editor.document().setModified(False)
        self._sync_source_badge()

    def _focus_editor(self):
        if self.isVisible():
            self.editor.setFocus(Qt.OtherFocusReason)

    def _sync_source_badge(self):
        _sync_source_badge(
            self.source_badge, self.editor, self._path, self._source_origin)

    def _request_completion(self):
        # The popup deliberately does not activate itself. Give the editor the
        # key stream first so arrows/Enter/Escape work after a button click just
        # as they do after Ctrl+Space.
        self._focus_editor()
        self.editor.request_completion(force=True)

    @property
    def mapping_current(self):
        return (
            bool(self._source_map)
            and self.editor.document().revision() == self._built_revision)

    def _source_changed(self):
        revision = self.editor.document().revision()
        diagnostics_stale = (
            self._diagnostic_revision >= 0
            and revision != self._diagnostic_revision)
        if diagnostics_stale:
            self.editor.mark_error_line(None)
            self.diagnostics.reset()
            self._diagnostic_revision = -1
        if self._built_revision >= 0 and not self.mapping_current:
            self._built_revision = -1
            self._source_map = {}
            self.editor.mark_execution_line(None)
            self.status.setText(
                "Source changed since the last build — assemble again to refresh PC links")
            self.status.setStyleSheet("color:#e3b341;padding:2px;")
            self.statusChanged.emit("Assembly source modified")
        elif diagnostics_stale:
            self.status.setText(
                "Source changed — assemble again to refresh diagnostics")
            self.status.setStyleSheet("color:#8b949e;padding:2px;")
            self.statusChanged.emit(self.status.text())

    def _completion_notice(self, text):
        self.status.setText(text)
        self.status.setStyleSheet("color:#e3b341;padding:2px;")
        self.statusChanged.emit(text)

    def _cursor_instruction(self):
        cursor = self.editor.textCursor()
        line = cursor.block().text()
        position = cursor.positionInBlock()
        span = _gas_statement_span(line, position)
        text = line[slice(*span)] if span is not None else ""
        match = re.match(
            r"^\s*(?:[.$A-Za-z_][\w.$]*:\s*)?"
            r"(?:(?:lock|rep|repe|repz|repne|repnz)\s+)*([A-Za-z]\w*)",
            text, re.IGNORECASE)
        self.info.set_instruction(
            instruction_info(match.group(1)) if match else None)

    def new_template(self):
        if not self.confirm_safe_to_discard("creating a new template"):
            return False
        self._source_map = {}
        self._built_revision = -1
        self._diagnostic_revision = -1
        self.editor.setPlainText(_ASM_TEMPLATE)
        self.editor.document().setModified(False)
        self.editor.clear_marks()
        self._path = None
        self._source_origin = "built-in template"
        self.diagnostics.reset()
        self.status.setText("New assembly template")
        self.status.setStyleSheet("color:#8b949e;padding:2px;")
        self.statusChanged.emit("Assembly source replaced")
        self._sync_source_badge()
        self._focus_editor()
        return True

    def set_source(self, text, origin="generated", confirm=True):
        if confirm and not self.confirm_safe_to_discard(
                "replacing it with generated assembly"):
            return False
        self._source_map = {}
        self._built_revision = -1
        self._diagnostic_revision = -1
        self.editor.setPlainText(text)
        self.editor.document().setModified(False)
        self.editor.clear_marks()
        self._path = None
        self._source_origin = origin
        self.diagnostics.success(f"Loaded assembly from {origin}. Review, edit, then run.")
        self._diagnostic_revision = self.editor.document().revision()
        self.status.setText(f"Assembly generated from {origin}")
        self.status.setStyleSheet("color:#79c0ff;padding:2px;")
        self.statusChanged.emit("Assembly source replaced")
        self._sync_source_badge()
        self._focus_editor()
        return True

    def open_source(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Open assembly", self._last_dir,
            "Assembly (*.s *.S *.asm);;All files (*)")
        if not path:
            return False
        return self.load_source(path)

    def load_source(self, path):
        """Load a known source path safely (shared by dialog and drag/drop)."""
        try:
            text = Path(path).read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError) as error:
            self.diagnostics.failure(str(error))
            self._diagnostic_revision = self.editor.document().revision()
            self._focus_editor()
            return False
        if not self.set_source(text, os.path.basename(path), confirm=True):
            return False
        self._path = path
        self._source_origin = os.path.basename(path)
        self._last_dir = os.path.dirname(os.path.abspath(path))
        name = os.path.basename(path)
        self.status.setText(f"Opened {name}")
        self.status.setStyleSheet("color:#79c0ff;padding:2px;")
        self.statusChanged.emit(f"Opened assembly source: {name}")
        self._sync_source_badge()
        return True

    def confirm_safe_to_discard(self, action):
        return _confirm_source_replacement(
            self, "Assembly", action)

    def save_source(self, save_as=False):
        path = self._path
        if save_as or not path:
            path, selected_filter = QFileDialog.getSaveFileName(
                self, "Save assembly",
                path or os.path.join(self._last_dir, "program.s"),
                "Assembly (*.s);;All files (*)")
            if not path:
                return False
            path = _default_save_suffix(
                path, selected_filter, "Assembly", ".s")
        try:
            Path(path).write_text(self.editor.toPlainText(), encoding="utf-8")
        except (OSError, UnicodeError) as error:
            self.diagnostics.failure(str(error))
            self._diagnostic_revision = self.editor.document().revision()
            self._focus_editor()
            return False
        self._path = path
        self._source_origin = os.path.basename(path)
        self._last_dir = os.path.dirname(os.path.abspath(path))
        self.editor.document().setModified(False)
        self.status.setText(f"Saved {os.path.basename(path)}")
        self.status.setStyleSheet("color:#3fb950;padding:2px;")
        self.statusChanged.emit(self.status.text())
        self._sync_source_badge()
        self._focus_editor()
        return True

    def build(self, run=False):
        self._focus_editor()
        self.editor.mark_error_line(None)
        self.status.setText("Assembling and linking…")
        self.status.setStyleSheet("color:#e3b341;padding:2px;")
        try:
            result = assemble_source(self.editor.toPlainText())
        except BuildFailure as error:
            self.editor.mark_error_line(error.line)
            self.diagnostics.failure(str(error))
            self._diagnostic_revision = self.editor.document().revision()
            self.status.setText(
                f"Build failed{f' at line {error.line}' if error.line else ''}")
            self.status.setStyleSheet("color:#f85149;padding:2px;")
            self.statusChanged.emit(self.status.text())
            return None
        self._source_map = result.source_map
        self._built_revision = self.editor.document().revision()
        self._diagnostic_revision = self._built_revision
        self.diagnostics.success(
            f"{result.log}\n{len(result.source_map)} instruction addresses mapped")
        self.status.setText(
            f"Build succeeded · {len(result.source_map)} source-linked instructions")
        self.status.setStyleSheet("color:#3fb950;padding:2px;")
        self.statusChanged.emit(self.status.text())
        if run:
            self.runRequested.emit(result.elf_path, dict(result.source_map))
        return result

    def highlight_pc(self, pc, line, context="Selected instruction"):
        if not self.mapping_current:
            return False
        self.editor.mark_execution_line(
            line, f"{context} at PC 0x{int(pc):08x} · source line {line}")
        self.status.setText(
            f"{context} · PC 0x{int(pc):08x} · assembly line {line}")
        self.status.setStyleSheet("color:#7ce0e8;padding:2px;")
        return True


class CView(QWidget):
    assemblyGenerated = Signal(str, str)
    statusChanged = Signal(str)
    dirtyChanged = Signal(bool)

    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(5)
        controls = QHBoxLayout()
        title = QLabel("Freestanding C workbench")
        title.setStyleSheet("font-size:14px;font-weight:bold;")
        controls.addWidget(title)
        note = QLabel("32-bit Pentium · no libc")
        note.setStyleSheet("color:#8b949e;")
        controls.addWidget(note)
        controls.addStretch(1)
        self.template_btn = QPushButton("New template")
        self.template_btn.setToolTip("Replace the editor with a Fibonacci C template")
        self.open_btn = QPushButton("Open…")
        self.open_btn.setToolTip("Open freestanding C source (Ctrl+O)")
        self.save_btn = QPushButton("Save as…")
        self.save_btn.setToolTip("Save C source under a chosen name")
        controls.addWidget(self.template_btn)
        controls.addWidget(self.open_btn)
        controls.addWidget(self.save_btn)
        controls.addWidget(QLabel(" optimization "))
        self.optimization = QComboBox()
        self.optimization.setAccessibleName("Compiler optimization")
        self.optimization.setToolTip(
            "GCC optimization level used for generated editable assembly")
        self.optimization.addItems(["-O0", "-O1", "-O2", "-Os"])
        self.optimization.setCurrentText("-O2")
        controls.addWidget(self.optimization)
        self.compile_btn = QPushButton("Compile → Assembly")
        self.compile_btn.setToolTip(
            "Compile to editable GNU Intel assembly (Ctrl+Enter)")
        self.compile_btn.setStyleSheet(
            "background:#1f6feb;color:white;font-weight:bold;border:1px solid #388bfd;")
        controls.addWidget(self.compile_btn)
        layout.addLayout(controls)

        split = QSplitter(Qt.Vertical)
        self.editor = CodeEditor()
        self.editor.setAccessibleName("C source editor")
        self.highlighter = CHighlighter(self.editor.document())
        self.editor.setPlainText(_C_TEMPLATE)
        self.find_bar = SourceFindBar(self.editor)
        layout.addWidget(self.find_bar)
        self.diagnostics = _Diagnostics()
        self.diagnostics.setAccessibleName("C compiler diagnostics")
        self.diagnostics.setMaximumHeight(165)
        split.addWidget(self.editor)
        split.addWidget(self.diagnostics)
        split.setStretchFactor(0, 5)
        split.setStretchFactor(1, 1)
        layout.addWidget(split, 1)
        status_row = QHBoxLayout()
        status_row.setContentsMargins(0, 0, 0, 0)
        self.status = QLabel(
            "Define int main(void); Compile emits editable GNU Intel assembly")
        self.status.setStyleSheet("color:#8b949e;padding:2px;")
        status_row.addWidget(self.status, 1)
        self.source_badge = QLabel()
        self.source_badge.setAccessibleName("C source identity")
        self.source_badge.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        self.source_badge.setMaximumWidth(330)
        status_row.addWidget(self.source_badge)
        layout.addLayout(status_row)
        self._path = None
        self._source_origin = "built-in template"
        self._last_dir = str(_TOOL_DIR)
        self._diagnostic_revision = -1
        self._compiled_optimization = None

        self.template_btn.clicked.connect(self.new_template)
        self.open_btn.clicked.connect(self.open_source)
        self.save_btn.clicked.connect(
            lambda: self.save_source(save_as=True))
        self.compile_btn.clicked.connect(self.compile)
        QShortcut(QKeySequence("Ctrl+Return"), self.editor).activated.connect(
            self.compile)
        self.editor.document().modificationChanged.connect(
            self.dirtyChanged.emit)
        self.editor.document().modificationChanged.connect(
            lambda _dirty: self._sync_source_badge())
        self.editor.textChanged.connect(self._source_changed)
        self.optimization.currentTextChanged.connect(
            self._optimization_changed)
        self.editor.document().setModified(False)
        self._sync_source_badge()

    def _focus_editor(self):
        if self.isVisible():
            self.editor.setFocus(Qt.OtherFocusReason)

    def _sync_source_badge(self):
        _sync_source_badge(
            self.source_badge, self.editor, self._path, self._source_origin)

    def _source_changed(self):
        revision = self.editor.document().revision()
        if (self._diagnostic_revision < 0
                or revision == self._diagnostic_revision):
            return
        self.editor.mark_error_line(None)
        self.diagnostics.reset()
        self._diagnostic_revision = -1
        self._compiled_optimization = None
        self.status.setText("Source changed — compile again to refresh diagnostics")
        self.status.setStyleSheet("color:#8b949e;padding:2px;")
        self.statusChanged.emit(self.status.text())

    def _optimization_changed(self, optimization):
        if (self._compiled_optimization is None
                or optimization == self._compiled_optimization):
            return
        self.editor.mark_error_line(None)
        self.diagnostics.reset()
        self._diagnostic_revision = -1
        self._compiled_optimization = None
        self.status.setText(
            f"Optimization changed to {optimization} — compile again")
        self.status.setStyleSheet("color:#e3b341;padding:2px;")
        self.statusChanged.emit(self.status.text())

    def new_template(self):
        if not self.confirm_safe_to_discard("creating a new template"):
            return False
        self.editor.setPlainText(_C_TEMPLATE)
        self.editor.document().setModified(False)
        self.editor.clear_marks()
        self._path = None
        self._source_origin = "built-in template"
        self.diagnostics.reset()
        self._diagnostic_revision = -1
        self._compiled_optimization = None
        self.status.setText("New freestanding C template")
        self.status.setStyleSheet("color:#8b949e;padding:2px;")
        self.statusChanged.emit("C source replaced")
        self._sync_source_badge()
        self._focus_editor()
        return True

    def open_source(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Open C source", self._last_dir,
            "C source (*.c *.h);;All files (*)")
        if not path:
            return False
        return self.load_source(path)

    def load_source(self, path):
        """Load a known source path safely (shared by dialog and drag/drop)."""
        try:
            text = Path(path).read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError) as error:
            self.diagnostics.failure(str(error))
            self._diagnostic_revision = self.editor.document().revision()
            self._focus_editor()
            return False
        if not self.confirm_safe_to_discard("opening another file"):
            return False
        self.editor.setPlainText(text)
        self.editor.document().setModified(False)
        self._path = path
        self._source_origin = os.path.basename(path)
        self._last_dir = os.path.dirname(os.path.abspath(path))
        self.editor.clear_marks()
        self.diagnostics.reset()
        self._diagnostic_revision = -1
        self._compiled_optimization = None
        name = os.path.basename(path)
        self.status.setText(f"Opened {name}")
        self.status.setStyleSheet("color:#79c0ff;padding:2px;")
        self.statusChanged.emit(f"Opened C source: {name}")
        self._sync_source_badge()
        self._focus_editor()
        return True

    def confirm_safe_to_discard(self, action):
        return _confirm_source_replacement(
            self, "C", action)

    def save_source(self, save_as=False):
        path = self._path
        if save_as or not path:
            path, selected_filter = QFileDialog.getSaveFileName(
                self, "Save C source",
                path or os.path.join(self._last_dir, "program.c"),
                "C source (*.c);;All files (*)")
            if not path:
                return False
            path = _default_save_suffix(
                path, selected_filter, "C source", ".c")
        try:
            Path(path).write_text(self.editor.toPlainText(), encoding="utf-8")
        except OSError as error:
            self.diagnostics.failure(str(error))
            self._diagnostic_revision = self.editor.document().revision()
            self._focus_editor()
            return False
        self._path = path
        self._source_origin = os.path.basename(path)
        self._last_dir = os.path.dirname(os.path.abspath(path))
        self.editor.document().setModified(False)
        self.status.setText(f"Saved {os.path.basename(path)}")
        self.status.setStyleSheet("color:#3fb950;padding:2px;")
        self.statusChanged.emit(self.status.text())
        self._sync_source_badge()
        self._focus_editor()
        return True

    def compile(self):
        self._focus_editor()
        self.editor.mark_error_line(None)
        self.status.setText("Compiling C to assembly…")
        self.status.setStyleSheet("color:#e3b341;padding:2px;")
        try:
            assembly, log = compile_c_source(
                self.editor.toPlainText(), self.optimization.currentText())
        except BuildFailure as error:
            self.editor.mark_error_line(error.line)
            self.diagnostics.failure(str(error))
            self._diagnostic_revision = self.editor.document().revision()
            self._compiled_optimization = self.optimization.currentText()
            self.status.setText(
                f"Compile failed{f' at line {error.line}' if error.line else ''}")
            self.status.setStyleSheet("color:#f85149;padding:2px;")
            self.statusChanged.emit(self.status.text())
            return None
        self.diagnostics.success(log)
        self._diagnostic_revision = self.editor.document().revision()
        self._compiled_optimization = self.optimization.currentText()
        self.status.setText("Compiled successfully · assembly tab is ready")
        self.status.setStyleSheet("color:#3fb950;padding:2px;")
        self.statusChanged.emit(self.status.text())
        self.assemblyGenerated.emit(assembly, self.optimization.currentText())
        return assembly
