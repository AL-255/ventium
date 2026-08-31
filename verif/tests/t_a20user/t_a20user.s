# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# User-mode A20 reset regression.
#
# The image deliberately starts with physical address bit 20 set.  A cold
# user-mode reset must leave A20 enabled, just as the system reset does; if it
# does not, instruction fetch aliases this image down by 1 MiB and never reaches
# the Linux exit syscall below.  This is independent of call/return, cache state,
# and any Quake-specific snapshot data.

    .text
    .globl _start
_start:
    movl    $1, %eax              # __NR_exit
    xorl    %ebx, %ebx            # status 0
    int     $0x80
