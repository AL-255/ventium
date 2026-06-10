=================================================
Ventium — P5/P54C Replica Reference Documentation
=================================================

Ventium is a high-fidelity replica of the Intel Pentium (P5/P54C, i586,
non-MMX) microarchitecture, written as fully synthesizable SystemVerilog.
It models the dual-issue, in-order, five-stage integer core — the U and V
pipes, the fast-path single-cycle ALU, the carry-chain and shifter datapaths,
the slow multi-cycle microsequencing FSM, the two-way set-associative L1
caches, the branch target buffer with its two-bit predictors, and the x87
floating-point stack — at a level of detail intended to reproduce the real
part's *observable behaviour*, instruction by instruction and cycle by cycle.

Correctness is established by **differential verification against QEMU**: the
same program is executed on the Ventium RTL and on a QEMU reference, and the
architectural state (register file, EFLAGS, memory, and — in cycle mode — the
per-instruction retire trace, including U/V pipe assignment and pairing) is
compared for bit-identity. Where the real silicon has documented quirks, the
replica reproduces them faithfully: the Pentium FDIV flaw, the F00F (Erratum
81) lock-up, the FIST conversion erratum, and the AP-500 instruction-pairing
rules are all modelled, gated behind explicit errata flags so a "clean" core
and an "erratum-accurate" core can both be exercised. The FDIV flaw goes a step
further: an optional, genuine **radix-4 SRT divider** reproduces it from first
principles out of the reverse-engineered quotient-selection table — see
:doc:`microarch/srt-divider`. The full set of sources behind the replica — Intel
manuals and errata, the pipeline and timing literature, die-photo reverse
engineering, and the emulators used as differential oracles — is cataloged in
:doc:`reference-library`.

The **Instruction Catalog** below is the heart of the reference: it walks every
instruction category the integer and x87 cores decode, and for each
instruction records *what it computes*, *how it drives the pipeline datapath*
(fast path vs. slow microsequenced FSM, the AGU/ALU/shifter/FPU blocks it
uses, and any forwarding or AGI interaction), *which pipe — U or V — it may
issue to and why*, and an honest implementation status.

.. toctree::
   :maxdepth: 2
   :caption: Overview

   architecture

.. toctree::
   :maxdepth: 2
   :caption: Reference

   isa/index

.. toctree::
   :maxdepth: 2
   :caption: Microarchitecture deep dives

   microarch/srt-divider
   microarch/l1-cache-performance
   microarch/l1-parametric

.. toctree::
   :maxdepth: 1
   :caption: Project resources

   reference-library
