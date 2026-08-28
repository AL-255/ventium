# Fast-path real-mode interrupt/return failure on FPGA

Date: 2026-08-22

Scope: current fast routed image only. No RTL was modified for this investigation. The only local changes were to the board probe and to a diagnostic ROM used to isolate the failing hardware sequence.

## Artifact hashes

```text
fast bitstream on board:
  /tmp/ao486/rk_ao486_system.bit.bin
  fce0eb3f431c5ea813cc5fca832d5c0d5f89d1a2eb2333a6f4a6f9a51af49a5d

ao486 daemon on board:
  /tmp/ao486/ao486d
  07a39c8668313299c668d1d8166bb4630ecf322706feb46c109f5ae7de49b7a7

board probe:
  fpga/board-tools/ven_board_probe.py
  2ca3dac58aede074eca963c1f5098128177b3ea9ba940a06e33a7f907e378c32

diagnostic ROM, first strengthened variant:
  fpga_verify_20260821/fastpath_irq_isolation/nested_irq_bios.bin
  bc1d600d748741601d2f8837583d8718f50a62a8e93e146b29a48bd5be256a86

diagnostic ROM, stricter IF-clear VGA-tail variant:
  fpga_verify_20260821/fastpath_irq_isolation/nested_irq_bios.bin
  0e82ce26a47f41b849169a954b2646e87d47a8e069fd976da18432294a3798fb

low-memory dumps:
  diag2_lowmem_after.bin
  e5bdafdbb3fb16149cb978c4e0c2a3fd83ca43b4023d2ef6ac299093fddd5d29

  diag3_lowmem_after.bin
  097c884352476f4005a1b16f956269c696a4ed5fb35f8e7e7399c057f40c1e26
```

The fast PL image was reloaded before the diagnostic captures with:

```bash
sshpass -p riguke ssh -F /dev/null -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/home/yukidama/.ssh/known_hosts \
  riguke@10.0.0.214 \
  'echo riguke | sudo -S /usr/local/bin/load-bitstream.sh /tmp/ao486/rk_ao486_system.bit.bin'
```

The board reported `load-bitstream: fpga state: operating`.

## Probe change

`trap-linear-data` now accepts `--no-tick-gate`. This is intentionally for focused test ROMs only; it lets the trap arm before a normal BIOS tick exists.

Command used for both captures:

```bash
echo riguke | sudo -S /tmp/ao486/ven_board_probe.py \
  trap-linear-data --no-tick-gate --streak 8 --max-delta 4096 --timeout 25
```

Daemon command:

```bash
echo riguke | sudo -S /tmp/ao486/ao486d \
  --membase 0x60000000 --bios /tmp/ao486/nestedirq-bios --secs 15 --trace
```

## Diagnostic ROM

The ROM sets:

- `IVT[8] = F000:irq0`;
- `IVT[13h] = F000:soft13`;
- PIT channel 0 to a short period;
- the PIC to legacy vectors with only IRQ0 unmasked.

Phase 1 repeatedly executes software `INT 13h`. The handler delays with IF clear, executes `STI`, lets a pending IRQ0 nest, then returns by `IRET`.

Phase 2 reproduces the VGA option-ROM tail shape:

```asm
sti_pop_tail:
    pushw   %ax
    pushw   %dx
    pushw   %cx
    cli
    movw    $1, %es:POP_ACTIVE
    movw    $1024, %cx
delay:
    nop
    loop    delay
    popw    %cx
    sti
    popw    %dx       /* STI shadow */
    popw    %ax
    ret
```

The stricter ROM enters this subroutine with IF cleared:

```asm
.pop_loop:
    cli
    movw    $0x1234, %ax
    movw    $0x5678, %dx
    call    sti_pop_tail
```

That makes the intended IRQ acceptance point the same class as the VGA BIOS failure: after `STI` and the one shadowed instruction, before the remaining `POP`/`RET`.

## Prior normal-BIOS fast-image failure

The fast image corrupts during VGA option ROM execution before it can reach FreeDOS/Quake.

Observed normal-BIOS trap:

```text
LINEAR-DATA TRAP FIRED cs:eip=8305:0000c7a3 streak=16 max_delta=4096
frozen=1 frz_eip=0000c7a9
```

PC ring boundary:

```text
[21] cs=c000 eip=00001cd7
[20] cs=8305 eip=00001c93
[19] cs=8305 eip=0000c783
```

The relevant VGA ROM tail is:

```text
C000:1D4B push ax
C000:1D4C push dx
C000:1D54 cli
C000:1D66 sti
C000:1D67 pop dx
C000:1D68 pop ax
C000:1D69 ret
```

So the normal boot failure already pointed at a pending IRQ accepted at an `STI` shadow / return boundary.

## Diagnostic capture 2: hardware IRQ IVT read consumes instruction bytes

ROM hash: `bc1d600d748741601d2f8837583d8718f50a62a8e93e146b29a48bd5be256a86`

Trap:

```text
LINEAR-DATA TRAP FIRED cs:eip=b900:00000115 streak=8 max_delta=4096
frozen=1 frz_eip=00000119
```

Daemon freeze:

```text
==== TRACE[final] frozen=1 frz_eip=00000119 last_eip=00000119 state=3 vec=08 count=0 stall=27915139 ====
```

Important PC-ring boundary:

```text
F000:016A  mov ax,0x1234
F000:016D  mov dx,0x5678
F000:0170  call F000:0238
F000:0238  push ax
F000:0239  push dx
F000:023A  push cx
F000:023B  ...
B900:0105  first bad target
```

Low-memory counters from `diag2_lowmem_after.bin`:

```text
IRQ_COUNT =0x01b1
SW_ENTER  =0x0100
SW_RETURN =0x0100
NEST_COUNT=0x0104
BAD_COUNT =0x0000
POP_RETURN=0x0004
POP_BAD   =0x0000
POP_NEST  =0x0006
MAIN_BAD  =0x0000
```

IVT was still valid:

```text
IVT8  = 4e 02 00 f0 = F000:024E
IVT13 = 07 02 00 f0 = F000:0207
```

Stack was also structurally valid; it contained the expected return IP and a valid hardware IRQ frame:

```text
6ff2: 023b
6ff4: f000
6ff6: 0283
6ff8: 5aa5
6ffa: 5678
6ffc: 1234
6ffe: 0173
```

The wrong target bytes `05 01 00 b9` do not come from the IVT or stack. They are present in the ROM instruction stream at offset `0x240`, crossing:

```text
F000:023C 26 c7 06 10 05 01 00   mov word ptr es:0x510,1
F000:0243 b9 00 04               mov cx,0x400
```

Conclusion for capture 2: `S_RMINT_RD` latched stale instruction-stream bytes as the real-mode IVT entry for IRQ0. IVT corruption is ruled out. Stack-frame corruption is ruled out.

## Diagnostic capture 3: real-mode IRET consumes instruction bytes

ROM hash: `0e82ce26a47f41b849169a954b2646e87d47a8e069fd976da18432294a3798fb`

Trap:

```text
LINEAR-DATA TRAP FIRED cs:eip=b9a5:00005ac8 streak=8 max_delta=4096
frozen=1 frz_eip=00005ace
```

Daemon freeze:

```text
==== TRACE[final] frozen=1 frz_eip=00005ace last_eip=00005ace state=1 vec=08 count=0 stall=765091 ====
```

Important PC-ring boundary:

```text
[20] cs=f000 eip=0000027c   IRQ0 iret
[19] cs=f000 eip=00000226   return into soft13
...
[13] cs=f000 eip=00000236   soft13 iret
[12] cs=b9a5 eip=000000e8   bad return CS with correct return IP
[11] cs=b9a5 eip=00005ab8
```

Low-memory counters from `diag3_lowmem_after.bin`:

```text
IVT8  = 4d 02 00 f0 = F000:024D
IVT13 = 06 02 00 f0 = F000:0206

IRQ_COUNT =0x000a
SW_ENTER  =0x0006
SW_RETURN =0x0006
NEST_COUNT=0x0007
BAD_COUNT =0x0000
SW_ACTIVE =0x0000
POP_RETURN=0x0000
POP_BAD   =0x0000
POP_NEST  =0x0000
MAIN_BAD  =0x0000
```

The stack image at the failed point contains the correct software INT return frame:

```text
6ffa: 00e8   return IP after INT 13h
6ffc: f000   return CS
6ffe: 0246   FLAGS
```

It also contains the expected software-handler saves below it:

```text
6ff6: 5aa5   saved CX
6ff8: a55a   saved AX
```

The bad `CS=B9A5` is not in the IVT or architectural return frame. It matches bytes from the mainline instruction stream around:

```text
F000:00E0 b8 5a a5        mov ax,0xa55a
F000:00E3 b9 a5 5a        mov cx,0x5aa5
F000:00E6 cd 13           int 13h
```

Specifically, bytes at `F000:00E2` are `a5 b9 a5 5a`; a mis-associated 32-bit read from there yields low half `B9A5`, high half `5AA5`. The observed return IP `00E8` was correct, while the observed return CS came from this stale code window.

Conclusion for capture 3: the failure is broader than just IVT fetch. A real-mode microcoded return path (`S_RMIRET`) can also latch stale instruction-stream data on `mem_ack`.

## RTL areas implicated

Current source inspection:

- `rtl/core/core_fastpath.svh` diverts from `S_PIPE` on `fp_irq_divert` and calls `start_fault(...)`.
- `rtl/core/core.sv` `start_fault()` then transitions directly to `S_RMINT_RD` in pure real mode.
- `rtl/core/core_rmint.svh`:
  - `S_RMINT_RD` latches `int_gate_off/int_gate_sel` on unqualified `mem_ack`;
  - `S_RMIRET` latches `iret_eip/iret_cs/eflags` on unqualified `mem_ack`.
- `rtl/core/core_bus_driver.svh` drives the intended addresses:
  - `S_RMINT_RD`: `idt_base + int_vec*4`;
  - `S_RMIRET`: `SS:SP + int_step*2`.
- `rtl/core/core.sv` exposes the core bus response as:
  - `mem_rdata = fx_merge_e ? fx_merged : bus_rdata`;
  - `mem_ack = bus_ack && !fx_hold_e`.
- `rtl/mem/ven_l1d.sv` uses the timing-closure registered read window:
  - `rd_window_q`;
  - `rd_addr_q`;
  - `rd_match = rd_armed && (rd_addr_q == c_addr)`;
  - registered-hit `c_ack` depends on `rd_match`.

The RTL comments already identify the exact hazard class: a captured read window must never be acknowledged for a new address. The FPGA evidence shows stale code-window data is still reaching real-mode delivery/return consumers.

## Proposed fixes for the repair agent

Do not brute-force this by disabling `VEN_SYS_FASTPATH`, flushing the whole cache on every interrupt, or forcing all real-mode execution through the slow path. Those would mask the symptom and likely make Quake too slow.

Recommended repair direction:

1. Add a response-valid/address qualification at the core memory response boundary.

   The core should not let a microcoded consumer latch `mem_rdata` unless the response belongs to the currently issued core memory request. A minimal form is to carry a registered request address/state token through the core/L1D seam and qualify `bus_ack` before exposing `mem_ack`.

   Required consumers include at least `S_RMINT_RD` and `S_RMIRET`; protected-mode delivery/IRET paths should be checked for the same assumption.

2. Serialize the fast-path interrupt handoff into real-mode delivery.

   On `fp_irq_divert` from `S_PIPE`, insert a one-cycle clean handoff/bubble before `S_RMINT_RD` or explicitly clear any pending core-side read-window/ack state that can belong to the previous instruction stream. During that bubble:

   - all old memory request sources must be quiesced;
   - no `mem_ack` may be consumed;
   - the next accepted read must be the IVT request for `idt_base + int_vec*4`.

   This should be a boundary clean-up, not a cache flush.

3. Fix INTA so it matches actual fast interrupt acceptance.

   Current `inta` pulses in any `S_PIPE && intr_take`, but actual delivery is gated by `fp_irq_divert`, which includes `!fp_occ_pending`:

   ```systemverilog
   assign fp_irq_divert = (state == S_PIPE) && !fp_occ_pending
                       && (smi_take || nmi_take || intr_take);
   ```

   Proposed shape:

   ```systemverilog
   assign inta = (((state == S_DECODE) || (state == S_HLTWAIT)) && intr_take)
              || ((state == S_PIPE) && fp_irq_divert && intr_take);
   ```

   If declaration order is inconvenient, introduce a `pipe_intr_accept` predicate near `intr_take` and use it both for `inta` and `fp_irq_divert`.

4. Add directed gates.

   Minimum tests:

   - real-mode `INT 13h` handler with a pending IRQ0 nested immediately after `STI`; assert the handler returns to the original `CS:IP` and preserves stack/registers;
   - VGA-tail shape: `STI; POP r16; POP r16; RET` with IRQ pending before `STI`; assert the interrupt target is read from IVT8 and the caller returns correctly;
   - assertion or TB monitor: when `state == S_RMINT_RD && mem_ack`, the consumed data must match the IVT entry at `idt_base + int_vec*4`;
   - assertion or TB monitor: during `S_RMIRET`, each acknowledged beat must correspond to `SS:SP + int_step*2`, not a prior fetch/data request;
   - assertion: `inta` pulses only when the core is actually accepting the maskable interrupt.

5. After RTL repair, regenerate the fast bitstream and rerun this diagnostic before attempting Quake.

   Acceptance for this diagnostic:

   ```text
   SW_ENTER  == 0x0100
   SW_RETURN == 0x0100
   BAD_COUNT == 0x0000
   MAIN_BAD  == 0x0000
   POP_RETURN== 0x0100
   POP_BAD   == 0x0000
   POP_NEST  >= 0x0080
   no linear-data trap
   ```

## Current acceptance status

Win95 desktop is already proven on the timing-valid non-fast control image.

Quake timedemo is still blocked. The timing-valid non-fast control image is too slow to reach the exact 969-frame result in practical time, and the fast image cannot yet reach FreeDOS because the fast-path real-mode interrupt/return bug corrupts execution during BIOS/diagnostic ROM execution.
