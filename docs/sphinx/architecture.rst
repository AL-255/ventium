===================
System architecture
===================

Ventium is organised in two layers. The **core** (``ventium_top`` wrapping
``core.sv``) is the P5/P54C microprocessor itself — the in-order, dual-issue
integer pipeline, the x87 floating-point unit, the L1 caches and TLB, and the
64-bit bus interface. The **SoC** (``ventium_soc.sv``) wraps that core with the
PC-platform peripherals — interrupt controller, timers, keyboard, VGA, IDE and
so on — so that bare-metal images and the external CPU tester boot against a
period-correct machine.

Both layers are verified the same way: a program runs on the RTL and on a QEMU
reference, and the architectural (and, in cycle mode, per-instruction retire)
state is diffed for bit-identity (see :doc:`reference-library`).


The core microarchitecture
==========================

The core implements the classic Pentium **five-stage, in-order, dual-issue**
pipeline. The diagram below follows the layout of the Pentium Processor manual's
block diagram (Fig. 1) — instructions flow top to bottom from the instruction
cache down through decode, the control unit and the execution units, with the
Bus Unit and Page Unit on the left and the memory subsystem at the bottom. Each
block is annotated with the **RTL file** that implements it (per
``rtl/README.md``).

.. graphviz:: diagrams/ventium-core.dot

**PF — front end.** The L1 instruction cache (``icache.sv``, 8 KB / 2-way /
32-byte lines) and the branch target buffer with its two-bit predictors
(``bpred_btb.sv``) feed a prefetch / instruction buffer. A correctly predicted
branch costs no bubble; a misprediction is resolved in the execute stage.

**D1 — decode & pairing.** Two fast-path decoders (``decode.sv``) crack the
variable-length x86 stream into the internal ``fpd_t`` micro-op form. The U/V
**pairing checker** (``issue_uv.sv``) applies the AP-500 rules — both ops
"simple", no register dependency, no displacement+immediate conflict, prefix and
branch-position restrictions — to decide whether the pair may dual-issue (up to
2 instructions per clock) or must issue singly in the U pipe (see the
:doc:`Instruction Catalog <isa/index>` for the per-instruction U/V class).

**D2 — operands & AGU.** The GPR register file is read (with partial-register
handling and the bypass network), and the address-generation unit forms
effective addresses for memory operands. A result feeding an address one clock
later triggers the **AGI** interlock.

**EX — execute.** The **U pipe** runs the full ALU / shifter / multiply-divide /
branch-resolve datapath; the **V pipe** runs the simple ALU / shift / branch
subset. The **x87 FPU** (``fpu_x87_pkg`` / ``fpu_top``) operates on 80-bit
``floatx80`` values and hosts the optional genuine **radix-4 SRT divider** that
reproduces the FDIV bug (see :doc:`microarch/srt-divider`). The dual-ported L1
D-cache (``dcache_timing.sv``, banked, MESI) services loads and stores from
either pipe; the TLB (``tlb.sv``) supplies the physical address.

**WB — writeback.** Results commit to the register file and EFLAGS; the full
EX→EX and WB→EX **bypass network** lets a dependent chain of simple ops sustain
one result per clock.

**Memory & bus.** The bus interface unit (``biu`` / the SVA-verified
``biu_p5.sv``) drives the 64-bit P5 bus, filling the I- and D-caches and draining
writebacks.

.. note::

   The file label on each block is the RTL unit that implements it. The R2
   refactor extracted behaviour-preserving **leaf modules** from the ``core.sv``
   spine: ``bpred_btb.sv`` (BTB arrays + predictor), ``icache.sv`` (I-cache
   arrays + fill + LRU), ``tlb.sv`` (split I/D TLB arrays + lookup), and
   ``dcache_timing.sv`` (D-cache *timing* model — no data array; load data still
   comes from the bus), alongside ``decode.sv`` / ``issue_uv.sv`` (decode +
   pairing), the x87 state file ``fpu_top.sv``, and the pure-function packages
   ``ventium_alu_pkg.sv`` / ``fpu_x87_pkg.sv``. The spine ``core.sv`` still runs
   the pipeline FSM, the prefetch path, the slow-path microsequencer, the
   page-table walk, the execution datapath and the FPU scoreboard — which is why
   *Prefetch Buffers*, *Microcode / µseq*, the *Control Unit*, the *Integer
   Datapath* and the *Page Unit* are labelled ``core.sv``. ``biu_p5.sv`` is the
   standalone pin-level 64-bit P5 bus FSM (``biu.sv`` is its default-OFF
   integration wrapper). See ``rtl/README.md`` for the authoritative file list.


The SoC integration
===================

``ventium_soc.sv`` instantiates the core with ``soc_en=1`` and wires the
PC-platform peripheral models onto the programmed-I/O (PMIO) bus. Memory traffic
goes over the 64-bit bus through the BIU; ``IN``/``OUT`` to the legacy port map
is decoded to the device models; and device interrupts are funneled through the
8259A PIC to the core's ``INTR``/``INTA`` handshake.

.. graphviz:: diagrams/ventium-soc.dot

**Peripherals** (``rtl/soc/ven_*.sv``): the 8259A **PIC** (master + slave,
``0x20``/``0xA0``), the 8254 **PIT** (``0x40``–``0x43``), the MC146818 **RTC**
(``0x70``/``0x71``), the 8042 **keyboard/mouse** controller (``0x60``/``0x64``),
the **port-92** fast-A20 gate (``0x92``), the **VGA** register file
(``0x3B0``–``0x3DF``), the **ACPI PM** timer (``0x608``), and two **IDE/ATA**
channels — a primary master disk (``0x1F0``/``0x3F6``) and a secondary ATAPI
CD-ROM (``0x170``/``0x376``).

**Interrupts.** Device IRQ lines (PIT → IRQ0, keyboard/mouse → IRQ1/IRQ12, RTC →
IRQ8, IDE → IRQ14/IRQ15) feed the cascaded 8259A pair, which presents a single
``INTR`` to the core and returns the vector over the ``INTA`` cycle. Several
lines are wired but held quiescent (e.g. the polled IDE channels run with
``nIEN``) so they cannot perturb the differential gate.

**A20.** The port-92 register and the 8042 (port ``0x64``) commands combine into
the physical A20 address mask applied at the core's bus boundary.

The SoC track has its own regression aggregate (``make verify-soc``): each device
model is diffed against ``qemu-system-i386`` over a directed bare-metal test, and
the ``test386`` external CPU tester boots on ``ventium_soc`` and is diffed
byte-for-byte against QEMU.
