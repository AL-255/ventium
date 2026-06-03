# =============================================================================
# Ventium M0 smoke test  --  freestanding 32-bit i386 (P5 / Pentium) program
# =============================================================================
# See PLAN.md §4 (verification) / "M0 Bootstrap" gate, and
# docs/trace-format.md §4 (M0 expectation).
#
# A SHORT, fully deterministic sequence of ORIGINAL-PENTIUM-ONLY instructions
# (i586 base ISA; NO MMX/SSE/CMOV, no x87 here).  It deliberately avoids every
# instruction that leaves EFLAGS architecturally undefined, so the differential
# comparator can compare EFLAGS without per-record masking:
#   * allowed here: mov, add, sub, and, or, xor, inc, dec, lea, push, pop,
#                   cmp, test, nop, jmp, jcc
#   * NOT used:     mul/imul/div/idiv/bsf/bsr/daa/das/shifts-by-CL (undefined flags)
#
# GNU-as / AT&T syntax.  Built with: gcc -m32 -nostdlib -static -Wl,-Ttext=0x08048000
# Each instruction's post-commit architectural state is the differential
# comparison point (trace-format.md §2.2).
#
# Stack note: the program uses push/pop. The Linux i386 process entry stack
# (provided by QEMU's linux-user loader and by the Verilator TB's preloaded
# image setup) supplies a valid ESP, so these pushes/pops are well-formed.
# The pushed value is immediately popped back, so the test does not depend on
# any particular initial ESP value for its register results.
# =============================================================================

    .text
    .globl  _start
_start:
    # --- load some deterministic constants -----------------------------------
    movl    $0x11111111, %eax       # eax = 0x11111111
    movl    $0x22222222, %ecx       # ecx = 0x22222222
    movl    $0x00000003, %edx       # edx = 3
    movl    $0x00000010, %esi       # esi = 16

    # --- straightforward ALU ops (well-defined flags) ------------------------
    addl    %ecx, %eax              # eax = 0x33333333
    subl    %edx, %eax              # eax = 0x33333330
    xorl    %ebx, %ebx              # ebx = 0 (also clears flags deterministically)
    orl     $0x0000000F, %ebx       # ebx = 0x0000000F
    andl    $0x00000007, %ebx       # ebx = 0x00000007

    incl    %edx                    # edx = 4
    decl    %esi                    # esi = 15

    # --- lea (address arithmetic, no flag side effects) ----------------------
    leal    (%eax,%edx,2), %edi     # edi = eax + edx*2 = 0x33333330 + 8 = 0x33333338

    # --- push/pop round-trip (memory + stack pointer) ------------------------
    pushl   %eax                    # [esp-4] = eax ; esp -= 4
    popl     %ebp                   # ebp = eax = 0x33333330 ; esp += 4

    # --- compare / test that set flags, then a taken branch ------------------
    cmpl    %eax, %ebp              # eax == ebp -> ZF=1
    je      .Lequal                 # taken
    movl    $0xDEADBEEF, %eax       # (skipped) sentinel: never executed
.Lequal:
    testl   %ebx, %ebx              # ebx != 0 -> ZF=0
    jnz     .Ldone                  # taken
    movl    $0xBADC0DE0, %ebx       # (skipped) sentinel: never executed
.Ldone:
    nop                             # quiescent marker before exit

    # --- clean exit: Linux i386 _exit(0) -------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # syscall -> never returns
