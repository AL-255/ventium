/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
#include "coremark.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile=0x3415, seed2_volatile=0x3415;
#else
volatile ee_s32 seed1_volatile=0, seed2_volatile=0;
#endif
volatile ee_s32 seed3_volatile=0x66, seed4_volatile=ITERATIONS, seed5_volatile=0;
ee_u32 default_num_contexts=1;
static unsigned long long begin_ticks, end_ticks;
static unsigned cursor;

static unsigned long long ticks(void) {
    unsigned lo, hi;
    /* Serialize older instructions using a P54 instruction, never LFENCE. */
    __asm__ volatile("xorl %%eax,%%eax; cpuid; rdtsc"
                     : "=a"(lo), "=d"(hi) : : "ebx", "ecx", "cc", "memory");
    return ((unsigned long long)hi << 32) | lo;
}
void start_time(void) { begin_ticks=ticks(); }
void stop_time(void) { end_ticks=ticks(); }
CORE_TICKS get_time(void) {
    unsigned long long elapsed=end_ticks-begin_ticks;
    if ((elapsed>>32)!=0) ee_printf("ERROR! TSC interval exceeds 32-bit CoreMark ticks\n");
    return (ee_u32)elapsed;
}
secs_ret time_in_secs(CORE_TICKS elapsed) { return elapsed/40000000u; }

void uart_send_char(char c) {
    volatile unsigned short *vga=(volatile unsigned short *)0xb8000;
    /* E9 is QEMU's debug console. The board evidence is the ordinary VGA text. */
    __asm__ volatile("outb %0,$0xe9" : : "a"(c));
    if(c=='\r') return;
    if(c=='\n') cursor=(cursor/80+1)*80;
    else vga[cursor++]=(unsigned short)(0x0700|(unsigned char)c);
    if(cursor>=80*25) {
        for(unsigned i=0;i<80*24;i++) vga[i]=vga[i+80];
        for(unsigned i=80*24;i<80*25;i++) vga[i]=0x0720;
        cursor=80*24;
    }
}
void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc; (void)argv;
    if(sizeof(ee_ptr_int)!=sizeof(void *) || sizeof(ee_u32)!=4)
        ee_printf("ERROR! invalid port types\n");
    ee_printf("VENTIUM COREMARK BOOT: 40MHz calibration; raw TSC authority\n");
    ee_printf("Port: no OS, no paging, IRQ disabled, unmodified CoreMark\n");
    p->portable_id=1;
}
void portable_fini(core_portable *p) {
    unsigned long long elapsed=end_ticks-begin_ticks;
    ee_printf("PORT-TSC start=%08x:%08x stop=%08x:%08x\n",
        (unsigned)(begin_ticks>>32),(unsigned)begin_ticks,
        (unsigned)(end_ticks>>32),(unsigned)end_ticks);
    ee_printf("PORT-TSC delta=%08x:%08x\n",(unsigned)(elapsed>>32),(unsigned)elapsed);
    /* This is a completion marker, not a correctness pass. Parse the CRCs/errors. */
    ee_printf("PORT-END\n");
    p->portable_id=0;
}
