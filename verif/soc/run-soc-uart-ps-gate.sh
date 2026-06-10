#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# PS-offload cosim: prove the COM1 UART C model (sw/ps_periph/ven_uart16550.c) is
# bit-exact vs qemu when the UART is PS-placed (+VEN_UART_PS). Thin wrapper so the
# soc-gate aggregator (no script args) can run it.
exec bash "$(dirname "${BASH_SOURCE[0]}")/run-soc-ps-cosim-gate.sh" uart
