/* Copyright 2026 Ventium Contributors
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Bare-metal 32-bit protected-mode harness for Reinhold P. Weicker's
 * Dhrystone 2.1 benchmark.
 *
 * Measurement contract:
 *   1. Static record allocation (Record_Glob / Next_Record_Glob), matching
 *      embedded Dhrystone 2.1 harnesses (SiFive / z486).
 *   2. Optional cache/TLB/BTB warm-up (DHRY_WARMUP_ITERS, default 20),
 *      followed by a full state reset via initialize_dhrystone() so the
 *      timed run begins from canonical initial values.
 *   3. Exact P54 serializing CPUID + RDTSC bracket around ONLY the unmodified
 *      Reinhold Weicker measurement loop (Start_Timer .. Stop_Timer). No port
 *      I/O, formatting, or validation executes inside the timed window.
 *   4. Full 20-invariant post-loop verification of all global, record, array,
 *      string, and local variables against Reinhold Weicker's specification.
 */

#include "dhry.h"

#ifndef DHRY_ITERS
#define DHRY_ITERS 2000
#endif

#ifndef DHRY_WARMUP_ITERS
#define DHRY_WARMUP_ITERS 20
#endif

#ifndef DHRY_PROFILE_NAME
#define DHRY_PROFILE_NAME "custom"
#endif

#ifndef DHRY_VGA_CONSOLE
#define DHRY_VGA_CONSOLE 0
#endif

#ifdef REG
#undef DHRY_REG_ATTR
#define DHRY_REG_ATTR register
#else
#define DHRY_REG_ATTR
#endif

extern Rec_Pointer Ptr_Glob;
extern Rec_Pointer Next_Ptr_Glob;
extern int         Int_Glob;
extern Boolean     Bool_Glob;
extern char        Ch_1_Glob;
extern char        Ch_2_Glob;
extern int         Arr_1_Glob[50];
extern int         Arr_2_Glob[50][50];
extern Boolean     Reg;

extern int  Proc_1 ();
extern int  Proc_2 ();
extern int  Proc_3 ();
extern int  Proc_4 ();
extern int  Proc_5 ();
extern int  Proc_6 ();
extern int  Proc_7 ();
extern int  Proc_8 ();
extern Enumeration Func_1 ();
extern Boolean     Func_2 ();

static Rec_Type Record_Glob;
static Rec_Type Next_Record_Glob;
#if DHRY_VGA_CONSOLE
static unsigned int vga_cursor;
#endif

static void
console_putc (char c)
{
  __asm__ __volatile__ ("outb %0, $0xe9" : : "a"(c));
#if DHRY_VGA_CONSOLE
  volatile unsigned short *vga = (volatile unsigned short *)0x000B8000u;
  if (c == '\r')
    return;
  if (c == '\n')
    vga_cursor = (vga_cursor / 80u + 1u) * 80u;
  else
    vga[vga_cursor++] = (unsigned short)(0x0700u | (unsigned char)c);
  if (vga_cursor >= 80u * 25u)
  {
    unsigned int i;
    for (i = 0; i < 80u * 24u; ++i)
      vga[i] = vga[i + 80u];
    for (i = 80u * 24u; i < 80u * 25u; ++i)
      vga[i] = 0x0720u;
    vga_cursor = 80u * 24u;
  }
#endif
}

static void
console_puts (const char *s)
{
  while (*s != '\0')
    console_putc (*s++);
}

static void
console_put_hex32 (unsigned int v)
{
  static const char hex[] = "0123456789abcdef";
  int shift;
  for (shift = 28; shift >= 0; shift -= 4)
    console_putc (hex[(v >> shift) & 0xFu]);
}

static void
console_put_u32 (unsigned int v)
{
  char buf[12];
  int n = 0;
  if (v == 0)
  {
    console_putc ('0');
    return;
  }
  while (v != 0)
  {
    buf[n++] = (char)('0' + (v % 10u));
    v /= 10u;
  }
  while (n > 0)
    console_putc (buf[--n]);
}

static void
console_put_s32 (int v)
{
  if (v < 0)
  {
    console_putc ('-');
    console_put_u32 ((unsigned int)(-(v + 1)) + 1u);
  }
  else
  {
    console_put_u32 ((unsigned int)v);
  }
}

static inline __attribute__((always_inline)) unsigned long long
read_tsc_serialized (void)
{
  unsigned int lo, hi;
  /* Serialize with P54 CPUID before sampling 64-bit TSC (never SSE2 LFENCE). */
  __asm__ __volatile__ (
    "xorl %%eax, %%eax\n\t"
    "cpuid\n\t"
    "rdtsc"
    : "=a"(lo), "=d"(hi)
    :
    : "ebx", "ecx", "cc", "memory"
  );
  return ((unsigned long long)hi << 32) | (unsigned long long)lo;
}

static void
initialize_dhrystone (void)
{
  int i, j;

  Int_Glob = 0;
  Bool_Glob = false;
  Ch_1_Glob = '\0';
  Ch_2_Glob = '\0';
  for (i = 0; i < 50; ++i)
  {
    Arr_1_Glob[i] = 0;
    for (j = 0; j < 50; ++j)
      Arr_2_Glob[i][j] = 0;
  }

  Record_Glob = (Rec_Type){ 0 };
  Next_Record_Glob = (Rec_Type){ 0 };

  Next_Ptr_Glob = &Next_Record_Glob;
  Ptr_Glob = &Record_Glob;

  Ptr_Glob->Ptr_Comp                = Next_Ptr_Glob;
  Ptr_Glob->Discr                   = Ident_1;
  Ptr_Glob->variant.var_1.Enum_Comp = Ident_3;
  Ptr_Glob->variant.var_1.Int_Comp  = 40;
  strcpy (Ptr_Glob->variant.var_1.Str_Comp,
          "DHRYSTONE PROGRAM, SOME STRING");

  Next_Ptr_Glob->Ptr_Comp                = Ptr_Glob;
  Next_Ptr_Glob->Discr                   = Ident_1;
  Next_Ptr_Glob->variant.var_1.Enum_Comp = Ident_2;
  Next_Ptr_Glob->variant.var_1.Int_Comp  = 40;
  strcpy (Next_Ptr_Glob->variant.var_1.Str_Comp,
          "DHRYSTONE PROGRAM, SOME STRING");

  Arr_2_Glob[8][7] = 10;
}

static unsigned int
validate_dhrystone (int number_of_runs,
                    int int_1_loc,
                    int int_2_loc,
                    int int_3_loc,
                    Enumeration enum_loc,
                    Str_30 str_1_loc,
                    Str_30 str_2_loc)
{
  if (Int_Glob != 5) return 0x01u;
  if (Bool_Glob != 1) return 0x02u;
  if (Ch_1_Glob != 'A') return 0x03u;
  if (Ch_2_Glob != 'B') return 0x04u;
  if (Arr_1_Glob[8] != 7) return 0x05u;
  if (Arr_2_Glob[8][7] != number_of_runs + 10) return 0x06u;

  if (Ptr_Glob->Ptr_Comp != Next_Ptr_Glob) return 0x10u;
  if (Ptr_Glob->Discr != Ident_1) return 0x11u;
  if (Ptr_Glob->variant.var_1.Enum_Comp != Ident_3) return 0x12u;
  if (Ptr_Glob->variant.var_1.Int_Comp != 17) return 0x13u;
  if (strcmp (Ptr_Glob->variant.var_1.Str_Comp,
              "DHRYSTONE PROGRAM, SOME STRING") != 0) return 0x14u;

  if (Next_Ptr_Glob->Ptr_Comp != Ptr_Glob->Ptr_Comp) return 0x20u;
  if (Next_Ptr_Glob->Discr != Ident_1) return 0x21u;
  if (Next_Ptr_Glob->variant.var_1.Enum_Comp != Ident_2) return 0x22u;
  if (Next_Ptr_Glob->variant.var_1.Int_Comp != 18) return 0x23u;
  if (strcmp (Next_Ptr_Glob->variant.var_1.Str_Comp,
              "DHRYSTONE PROGRAM, SOME STRING") != 0) return 0x24u;

  if (int_1_loc != 5) return 0x30u;
  if (int_2_loc != 13) return 0x31u;
  if (int_3_loc != 7) return 0x32u;
  if (enum_loc != Ident_2) return 0x33u;
  if (strcmp (str_1_loc, "DHRYSTONE PROGRAM, 1'ST STRING") != 0) return 0x34u;
  if (strcmp (str_2_loc, "DHRYSTONE PROGRAM, 2'ND STRING") != 0) return 0x35u;

  return 0u;
}

/* Execute `runs` canonical Dhrystone 2.1 iterations. When `measure != 0`,
 * sample serialized RDTSC immediately before and after the loop. */
static __attribute__((noinline)) unsigned int
run_dhrystone_kernel (int runs, int measure,
                      unsigned long long *out_start,
                      unsigned long long *out_stop)
{
        One_Fifty       Int_1_Loc;
  DHRY_REG_ATTR One_Fifty Int_2_Loc;
        One_Fifty       Int_3_Loc;
  DHRY_REG_ATTR char    Ch_Index;
        Enumeration     Enum_Loc;
        Str_30          Str_1_Loc;
        Str_30          Str_2_Loc;
  DHRY_REG_ATTR int     Run_Index;
  DHRY_REG_ATTR int     Number_Of_Runs;
  unsigned long long t0 = 0, t1 = 0;

  Number_Of_Runs = runs;
  initialize_dhrystone ();
  strcpy (Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");

  if (measure)
    t0 = read_tsc_serialized ();

  /***************/
  /* Start timer */
  /***************/
  for (Run_Index = 1; Run_Index <= Number_Of_Runs; ++Run_Index)
  {
    Proc_5 ();
    Proc_4 ();
      /* Ch_1_Glob == 'A', Ch_2_Glob == 'B', Bool_Glob == true */
    Int_1_Loc = 2;
    Int_2_Loc = 3;
    strcpy (Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");
    Enum_Loc = Ident_2;
    Bool_Glob = ! Func_2 (Str_1_Loc, Str_2_Loc);
      /* Bool_Glob == 1 */
    while (Int_1_Loc < Int_2_Loc)  /* loop body executed once */
    {
      Int_3_Loc = 5 * Int_1_Loc - Int_2_Loc;
        /* Int_3_Loc == 7 */
      Proc_7 (Int_1_Loc, Int_2_Loc, &Int_3_Loc);
        /* Int_3_Loc == 7 */
      Int_1_Loc += 1;
    } /* while */
      /* Int_1_Loc == 3, Int_2_Loc == 3, Int_3_Loc == 7 */
    Proc_8 (Arr_1_Glob, Arr_2_Glob, Int_1_Loc, Int_3_Loc);
      /* Int_Glob == 5 */
    Proc_1 (Ptr_Glob);
    for (Ch_Index = 'A'; Ch_Index <= Ch_2_Glob; ++Ch_Index)
                             /* loop body executed twice */
    {
      if (Enum_Loc == Func_1 (Ch_Index, 'C'))
          /* then, not executed */
        {
        Proc_6 (Ident_1, &Enum_Loc);
        strcpy (Str_2_Loc, "DHRYSTONE PROGRAM, 3'RD STRING");
        Int_2_Loc = Run_Index;
        Int_Glob = Run_Index;
        }
    }
      /* Int_1_Loc == 3, Int_2_Loc == 3, Int_3_Loc == 7 */
    Int_2_Loc = Int_2_Loc * Int_1_Loc;
    Int_1_Loc = Int_2_Loc / Int_3_Loc;
    Int_2_Loc = 7 * (Int_2_Loc - Int_3_Loc) - Int_1_Loc;
      /* Int_1_Loc == 1, Int_2_Loc == 13, Int_3_Loc == 7 */
    Proc_2 (&Int_1_Loc);
      /* Int_1_Loc == 5 */
  } /* loop "for Run_Index" */
  /**************/
  /* Stop timer */
  /**************/

  if (measure)
    t1 = read_tsc_serialized ();

  if (out_start != (unsigned long long *)0)
    *out_start = t0;
  if (out_stop != (unsigned long long *)0)
    *out_stop = t1;

  return validate_dhrystone (Number_Of_Runs,
                             Int_1_Loc,
                             Int_2_Loc,
                             Int_3_Loc,
                             Enum_Loc,
                             Str_1_Loc,
                             Str_2_Loc);
}

unsigned char __attribute__((section(".text.entry")))
dhrystone_c_entry (void)
{
  unsigned long long start_tsc = 0, stop_tsc = 0, delta_tsc = 0;
  unsigned int warm_err = 0, meas_err = 0;

  console_puts ("VENTIUM DHRYSTONE 2.1 BARE-METAL HARNESS\n");
  console_puts ("DHRY-CONFIG profile=");
  console_puts (DHRY_PROFILE_NAME);
  console_puts (" reg=");
  console_put_u32 (Reg ? 1u : 0u);
  console_puts (" warmup=");
  console_put_u32 ((unsigned int)DHRY_WARMUP_ITERS);
  console_puts (" runs=");
  console_put_u32 ((unsigned int)DHRY_ITERS);
  console_puts ("\n");

#if DHRY_WARMUP_ITERS > 0
  warm_err = run_dhrystone_kernel (DHRY_WARMUP_ITERS, 0,
                                   (unsigned long long *)0,
                                   (unsigned long long *)0);
  if (warm_err != 0u)
  {
    console_puts ("DHRY-SELFCHECK FAIL phase=warmup code=0x");
    console_put_hex32 (warm_err);
    console_puts ("\nDHRY-END\n");
    return (unsigned char)(0x40u | (warm_err & 0x3Fu));
  }
#endif

  meas_err = run_dhrystone_kernel (DHRY_ITERS, 1, &start_tsc, &stop_tsc);
  delta_tsc = stop_tsc - start_tsc;

  console_puts ("DHRY-STATE Int_Glob=");
  console_put_s32 (Int_Glob);
  console_puts (" Bool_Glob=");
  console_put_s32 (Bool_Glob);
  console_puts (" Ch_1_Glob=");
  console_putc (Ch_1_Glob);
  console_puts (" Ch_2_Glob=");
  console_putc (Ch_2_Glob);
  console_puts (" Arr1_8=");
  console_put_s32 (Arr_1_Glob[8]);
  console_puts (" Arr2_8_7=");
  console_put_s32 (Arr_2_Glob[8][7]);
  console_puts (" Ptr_Int=");
  console_put_s32 (Ptr_Glob->variant.var_1.Int_Comp);
  console_puts (" NextPtr_Int=");
  console_put_s32 (Next_Ptr_Glob->variant.var_1.Int_Comp);
  console_puts ("\n");

  console_puts ("DHRY-TSC start=");
  console_put_hex32 ((unsigned int)(start_tsc >> 32));
  console_putc (':');
  console_put_hex32 ((unsigned int)start_tsc);
  console_puts (" stop=");
  console_put_hex32 ((unsigned int)(stop_tsc >> 32));
  console_putc (':');
  console_put_hex32 ((unsigned int)stop_tsc);
  console_puts ("\n");

  console_puts ("DHRY-TSC delta=");
  console_put_hex32 ((unsigned int)(delta_tsc >> 32));
  console_putc (':');
  console_put_hex32 ((unsigned int)delta_tsc);
  console_puts (" runs=");
  console_put_u32 ((unsigned int)DHRY_ITERS);
  console_puts ("\n");

  if (meas_err != 0u)
  {
    console_puts ("DHRY-SELFCHECK FAIL phase=measure code=0x");
    console_put_hex32 (meas_err);
    console_puts ("\nDHRY-END\n");
    return (unsigned char)(0x80u | (meas_err & 0x3Fu));
  }

  console_puts ("DHRY-SELFCHECK PASS\n");
  console_puts ("DHRY-END\n");
  return 0x10u; /* isa-debug-exit -> status (0x10 << 1) | 1 = 33 */
}
