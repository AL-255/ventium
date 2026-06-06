# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Ventium pipeline visualizer — a PySide6 GUI over the verilated RTL core.

backend.py  : ctypes binding to libventium_viz.so (the Verilator backend).
disasm.py   : capstone x86 disassembly of instruction bytes.
*_view.py   : the GUI panels (pipeline / tables / trace / registers).
main.py     : the application entry point.
"""
__all__ = ["backend", "disasm"]
