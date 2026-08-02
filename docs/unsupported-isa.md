# Ventium — architecturally UNSUPPORTED CPU behaviour

REVIEW2_aug2 H-19 requires that features left out of scope be *documented as unsupported
CPU behaviour* rather than merely halting. This file is that documentation. It lists
only things the hardware **cannot do**, not things that are merely untested.

Each entry names the exact descriptor/condition, the RTL site, and what a guest that
uses it will observe. Nothing here fails silently: every case reaches a **loud halt**
whose debug tag identifies the form, so a freeze can be read back precisely.

---

## 1. System far transfers through unimplemented descriptor types

`rtl/core/core_seg_ljmp.svh` — a far JMP/CALL whose target selector names a system
descriptor the core does not implement halts. The `VEN_DBG_CORE` tag is `0xD<type>`, so
the low nibble is the descriptor's own type field:

| tag | descriptor type | status |
|---|---|---|
| `0xD5` | **task gate** (type 5) | UNSUPPORTED — halts |
| `0xD1` | **16-bit available TSS** (type 1) | UNSUPPORTED — halts |
| `0xD3` | **16-bit busy TSS** (type 3) | UNSUPPORTED — halts |
| `0xD2` | **LDT descriptor** (type 2) as a far-transfer target | UNSUPPORTED — halts |
| `0xD9`/`0xDB` | 32-bit TSS (available/busy) | **supported** — hardware task switch |
| `0xDC`/`0xD4` | call gates (32/16-bit) | **supported**, same privilege |

**Consequence for guests.** Any OS that dispatches through a *task gate* — the classic
386 way to give a fault its own TSS, and what DOS extenders such as CWSDPMI use for the
double-fault handler — will halt rather than switch tasks. 16-bit TSS types are used by
286-era and some V86-monitor code.

**Why halting rather than faulting:** these are *legal* descriptor types. Raising `#GP`
would be architecturally wrong — it would tell the guest its descriptor is malformed
when in fact this CPU simply does not implement the transfer. A halt is an honest
"unimplemented", and the tag says which one.

## 2. Cross-privilege call gates

A call gate whose target CS.DPL is *less than* CPL requires a stack switch through
`TSS.SS<n>:ESP<n>` and a parameter copy. `core_seg_ljmp.svh` halts on this separately
from the type check above. Same-privilege call gates work.

## 3. Nested-task state (NT / backlink)

Because task gates are unsupported, the nested-task path they feed — `EFLAGS.NT` set on
entry, the backlink field written into the incoming TSS, and `IRET` with `NT=1`
performing a *task return* rather than a stack pop — is correspondingly not exercised
and should be considered unsupported. See REVIEW2_aug2 H-08.

## 4. Correctness modes that are OFF in the shipping build

These are implemented and gated, but **not enabled by default**, so the FPGA build does
not have their behaviour. Each is off for a measured reason, recorded at its definition:

| define | what it adds | why it is off |
|---|---|---|
| `VEN_SEG_ENFORCE` | per-access segment limit/type checks | enforcement still architecturally incomplete (REVIEW2_aug2 H-05) |
| `VEN_X87_STKFLT` | x87 stack-fault detection + masked response | QEMU implements no stack faults; 3 of 98 differential programs drive the stack past its ends deliberately |
| `VEN_IC_ALIAS_SAFE` | flush executable state on every CPU store | correct under aliasing, but a full I-cache refill per store; the real fix is physical I-tags |
| `VEN_IC_FETCH_BYPASS` | honour CR0.CD on instruction fetch | **measured +82% clocks on psmm**; a real BIOS clears CD/NW after POST |
| `VEN_X87_MF_STRICT` | check pending `#MF` before *every* waiting x87 op | QEMU checks at exactly two sites; default-on would diverge from the oracle |

## 5. Memory-path properties not provided

| property | status |
|---|---|
| locked RMW atomicity vs DMA on the L1/AXI path | **not provided** — AXI4 `AxLOCK` is exclusive-access and needs a monitor + `EXOKAY` check + retry (REVIEW2_aug2 C-10) |
| single-access non-cacheable/MMIO reads | **not provided** — a non-cacheable read still issues a 32-byte fill, so read-to-clear registers and FIFOs see repeated accesses (REVIEW2_aug2 H-11) |
| SMRAM isolation in the shipping config | **not enabled** — SMBASE `0x30000` places SMRAM inside conventional DOS memory, so guarding it would deny guests 64 KiB (REVIEW2_aug2 C-08) |
| page-crossing split outside `S_LOAD`/`S_LOAD2`/`S_STORE` | **not provided** — detected and `$fatal` in simulation, never observed firing (REVIEW2_aug2 C-04) |
