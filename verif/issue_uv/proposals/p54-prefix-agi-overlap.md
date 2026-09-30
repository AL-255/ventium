# Existing prefix D1 clock overlapping reference AGI (Sep 29 proposal)

The optional production helper is implemented after the parent released its
source-hash freeze; compilation and measurement belong to the parent.
The parent subsequently measured the prefix-overlap candidate at approximately
1.992748 CM/MHz versus predecessor exact-AGI 1.97713: approximately **+0.79%
score / −0.78% cycles** in short diagnostics. These are not official-duration
scores or gameplay IPC. Its later COMMON-mask successor reached 2.053795,
authorizing bounded directed gates; the actual full-mask implementation now
supersedes the legacy writer-fidelity limitation below. User-requested wrap-up
is active; no further run is being launched. The focused isolated on/off
microfixture comparisons listed below remain deferred, not claimed as passed.

## Primary rule and bounded change

Intel AP-500, 241799-002, section 5.5 (local primary PDF under
`ventium-refs/03-optimization-timing/`) assigns one decode clock to ordinary
prefixes, including operand-size, segment override, and opcode-map `0F`.
It specifically permits that decode clock to overlap the one-cycle address
generation interlock. The near-Jcc `0F` form is exceptional: it has no extra
prefix clock. Branches are excluded from this direct-dispatch whitelist.

`VEN_P54_PREFIX_AGI` requires the existing exact dependency admission profile
`VEN_P54_SDISPATCH_AGI`. It permits a true, known EA-GPR dependency only if the
already performed capture/D1 clock pays **exactly one** architectural prefix:

```systemverilog
prefix_agi_clock =
  ((npfx == 1) && (refdecode_ibuf[1] != 8'h0f)) ||
  ((npfx == 0) && (refdecode_ibuf[0] == 8'h0f));
```

`npfx` counts ordinary prefixes, not `0F`. Thus one ordinary prefix followed
by `0F` costs two prefix clocks and cannot receive this credit. Multiple
ordinary prefixes, branches/LOCK/address override/REP/unknown/system cases
still fail their existing guards. A nonprefixed true EA dependency never
borrows a capture clock to evade AGI. An independent address already qualifies
under the earlier exact-mask change and receives no new speedup from this one.

The clock is not removed: S_PIPE captures the current instruction and shared
q fields on a no-retire/no-request clock, then S_LOAD/S_EXEC starts next clock.
The preceding writer has already updated the live GPR file, so the existing EA
generator captures the same correct address. Only redundant S_DECODE is
omitted when its AGI bubble is already overlapped by the paid prefix D1 clock.
Actual memory acknowledgement and native/iterative EX occupancy remain intact;
neither prefix nor AGI is an EX credit or a post-retire timing penalty.

The initial isolated measurement intentionally preserved `agi_wr0/1` writer
semantics. The integrated `VEN_P54_AGI_WRITE_MASK` profile now uses fully gated
actual prior-clock write enables and the documented PUSH/POP-only exemption;
see [p54-agi-write-mask.md](p54-agi-write-mask.md). A final faithful 2.1 score
must use that full producer rather than the old slow-writer/ESP omissions.
No lookahead, extra decoder, SRAM
port, stored execution descriptor, branch-pair rule, or writeback mirror is
added by this change.

## Deferred isolated overlap fixtures

`t_sdispatch_addrdep.s` now has `EXTRA_PREFIX` preparation controls. Run a
matched prefix-overlap-on/off comparison only when non-CoreMark tests are
authorized. Each fixture must first pass full architectural QEMU comparison,
then compare actual writer/result retirement gaps (not profiler startup IPC).

| Family | Prefixes | Dependency | Expected overlap effect |
|---|---|---|---|
| EXT memory (0) | inherent0F | EBX base | saves one redundant AGI/decode clock; EX floor3 intact |
| TEST memory (1) | EXTRA_PREFIX=1 (66) | EBX base | saves one clock; memory/ALU clocks intact |
| IMUL2 memory (4) | inherent0F | EBX base | saves one clock; EX floor10 intact |
| LEA16 (5) | inherent66 | EBX base | saves one clock; 16-bit register merge/IP semantics intact |
| MUL/DIV memory (2/3) | none | EBX base | unchanged: no prefix clock to overlap |
| EXT/IMUL2 memory | EXTRA_PREFIX=1 + inherent0F | EBX base | unchanged: two prefixes, ordinary S_DECODE required |
| TEST memory | EXTRA_PREFIX=3 (66+2E) | EBX base | unchanged: multiple ordinary prefixes |
| Any admitted family | corresponding prefix | independent ESI base | unchanged from exact-mask profile |
| A1 moffs (6) | none/one ordinary | no address GPR | unchanged: absolute scratch mask cleared |

Also require index and both prior U/V-writer cases; tag/way/collision, real
instruction bytes across line/page/CS boundaries, SMC/flush, event/debug
cancellation, and mask-unknown negatives. Existing guarded reference capture
retains those protections. Do not claim these deferred gates passed.
