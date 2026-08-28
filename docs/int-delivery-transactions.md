# Interrupt-delivery transaction boundaries

What "transactional delivery" means on this core, per delivery class. Named here
so the boundary is stated, not implied by whichever state was touched last.

## Cross-privilege (TSS-stack) delivery

`S_INT_PROBE` stages the new SS/CPL and pre-probes the frame's page extent
(supervisor-class write probes) **before** any frame byte is written or any
privilege state installed. A page failure there faults in the OLD context with
the frame never started (pxprobe). Once the probe passes, the frame writes
cannot page-fault, so the commit point (handler CS, CPL, EIP, masked EFLAGS)
is atomic from the guest's point of view.

The probe walks the frame's **slot plan** in push order: one plan
(`frm_slot_off`, the staged SP/B and the frame kind's slot count/unit) serves
the probe sequencer, the push-address mirror, and the ESP writeback, so the
frame shape cannot drift among formulas. Every slot's first page is probed at
the slot's own start address (CR2 = the faulting push, silicon's attribution)
and a straddling slot's second page at its base. A frame that wraps its SP
window (16-bit stack with SP < frame size, or a 32-bit stack with ESP < frame
size) occupies two offset chunks and can touch up to four pages once the
arbitrary SS.base alignment is accounted for — every one is enumerated.

`pxwrap` pins the wrapped layout differentially (B=0/B=1 wraps across the
16-bit interrupt/trap/call-gate and V86 frame kinds: each touched page denied
in turn — #PF err=2, push-order CR2, old context intact, no escalation —
then permitted with every frame byte verified). `pxwrapm` is its witness
half: QEMU pushes slots incrementally (a rejected frame leaves k_fault
slots written there) while the probe leaves zero, so the byte-level
difference is graded in-guest rather than by the trace; the V86 denials are
terminal in both oracles and live there too.

## Same-privilege delivery

**No pre-probe — deliberately.** Same-privilege pushes are incremental
(S_INT_PUSH beats 0..N, EFLAGS/CS/EIP [+errcode] descending), and a fault on push
k leaves pushes 0..k-1 **visible on the stack**. This is the architectural
boundary, not a shortcut: the pinned QEMU pushes the same frame incrementally
(`do_interrupt_protected` writes each slot as it goes), so a mid-frame fault has
identical observable state in both oracles — same partial bytes, same saved
context, same CR2/error attribution.

The exact boundary:

- ESP is decremented only at the final beat, so a mid-frame fault leaves ESP at
  its pre-delivery value (the partial bytes sit *above* it).
- The fault (page fault on a push) is delivered in the ORIGINAL context: CR2 is
  the faulting push's address, W/R=1, saved EIP = the interrupted instruction,
  no handler state installed.
- If the fault delivery itself faults on its own pushes, the escalation is the
  ordinary nested-fault path (#DF), unchanged.

`psamepf` pins this differentially (page-2 not-present and page-2 read-only on
a straddling same-priv frame; the handler records CR2/err/partial bytes/ESP and
the delivery then restarts and completes).

## Segment-enforcement coverage

Per-access segment limit/type/null checks (including stack-segment validation on
the frame's slots) are behind `VEN_SEG_ENFORCE` and remain **off by default** —
the enforcement mechanism is complete and `make seg` green, but the default flip
is deferred on the review's own precondition (the m7 Quake/Win95 matrices are
absent in this checkout). With enforcement off, the probed/bounded class is the
page-level checks above.
