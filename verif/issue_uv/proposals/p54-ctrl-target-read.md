# Slow-control I-BRAM turnaround

`VEN_P54_CTRL_TARGET_READ` steers the two existing registered I-cache read
ports to a resolved near-control target while the slow instruction still owns
`S_EXEC` (near RET/RET-immediate/JMP-indirect) or `S_STORE` (near CALL).
It does not add RAM ports, a return stack, decoded-instruction storage, or a
zero-clock redirect. The old instruction still pays all its normal clocks,
memory acknowledgement, retirement, breakpoint, and fault handling.

The optional first profile admits only flat, default-32-bit user execution
without paging, SMM, SoC, or co-simulation. Target addresses come exclusively
from the same latched operands/target resolver used by the real commit.
The selector never depends on `mem_ack`, an issue/fault permit, or a returned
instruction byte. Thus speculative reads cannot feed the request/permission
cone back into their own address selection. Ordinary `S_PIPE` predicted-target
steering is unchanged, and macro-off builds retain the original selectors.

Both ports read target/target-next-line. The existing returned set/way tags,
read/write collision flags, current I-cache presence and extent guards remain
mandatory at consumption. A cold, invalidated, collided, or wrong-way target
still stalls/refills normally. These reads make no cache allocation, LRU touch,
BTB update, instruction capture, or architectural side effect.

The real-include leaf passes 13,450 shape/context/offset checks; artifacts:
`/tmp/ventium-ctrl-target-read-leaf.dtKbGd`. The prepared whole-core fixture
covers relative/register/memory CALL, register/memory JMP, RET-immediate,
operand-size-16 CALL/RET, own-store self-modifying targets, same-set conflict,
and an instruction crossing a target line boundary. All eleven cases pass
architectural comparison against pinned QEMU in both the control and preceding
combined candidate. Evidence is `/tmp/ventium-ctrl-target-control-fixed.cSLg2w`
and `/tmp/ventium-ctrl-target-candidate.U4VV6B`. The candidate predates the final
prefix-owner/WAW corrections; this is not a full FIXED32 qualification.

Warm CALL/RET witness gaps shrink by one clock; same-set conflict and a
cross-line target shrink by two. Register/memory JMP and self-modification
witnesses are unchanged. The compared candidate also enables MOV ACK and
prefix admission, so those differences are bundled results, not an isolated
target-port saving. Full-system standard-suite qualification remains pending.

The prior timed trace contains 36,372 relevant CALL/RET operations. That is an
opportunity upper bound, **not** a measured saving: resident target buffers,
other debts and control scheduling can hide the turnaround already.
