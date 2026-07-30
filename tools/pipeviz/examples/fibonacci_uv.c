/*
 * Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Freestanding 32-bit example for Pipeviz.  Build with DUAL=0 for one
 * dependency chain or DUAL=1 for two independent Fibonacci chains.  The latter
 * gives the Pentium-style U/V issue logic useful independent work to pair.
 */
typedef unsigned int u32;

#ifndef DUAL
#define DUAL 1
#endif

volatile u32 iterations = 120;
volatile u32 results[4];

__attribute__((noinline, noipa))
static void store_result(volatile u32 *address, u32 value)
{
    *address = value;
}

__attribute__((noreturn, used))
void _start(void)
{
    u32 count = iterations;
    u32 a = 0, b = 1;
#if DUAL
    u32 c = 2, d = 3;
#endif

    while (count--) {
        u32 next_a = a + b;
#if DUAL
        u32 next_c = c + d;
#endif
        a = b;
        b = next_a;
#if DUAL
        c = d;
        d = next_c;
#endif
    }

    store_result(&results[0], a);
    store_result(&results[1], b);
#if DUAL
    store_result(&results[2], c);
    store_result(&results[3], d);
#endif

    __asm__ volatile (
        "movl $1, %%eax\n\t"
        "xorl %%ebx, %%ebx\n\t"
        "int $0x80"
        :
        :
        : "eax", "ebx", "memory");
    __builtin_unreachable();
}
