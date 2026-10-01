# Far-frame word-width boundary gate

These are independent CALL-only and RETF-only legal-access witnesses. They do
not claim to explain the Win95 operand-32 RETF failure. No existing fixture or
RTL is changed by this gate.

`CASE-1` has five bits: RETF (otherwise CALL), page boundary (otherwise segment
boundary), CS.D, SS.B, and DWORD frame (otherwise WORD). There are 32 variants.
Both code descriptors have base `F0000`, limit `FFFF`, and pre-set accessed
bits. Operand size and stack address size are independent. CALL exits in its
callee without a RETF; RETF consumes a preseeded frame without a far CALL.

For segment cases, normal writable SS.limit is `FFFF`. CALL starts at ESP
`10000` for SS.B=1 or `DEAD0000` for SS.B=0. Its WORD slots are IP@`FFFC` and
CS@`FFFE`; both are wholly legal. RETF starts at that frame. DWORD controls
use IP@`FFF8` and CS@`FFFC`. SS.B=0 must retain the `DEAD` high half.

For page cases SS.base is `400000`, limit is `FFFF`, and only the first stack
page maps to physical `800000`. The next virtual page `401000` is absent.
WORD slots are IP@offset `FFC`, CS@`FFE`; DWORD slots are `FF8`/`FFC`. The
test never reads the absent page to inspect a sentinel; it checks its PTE.
CALL page cases are controls: the current write-fragment logic already uses
the exact write strobes, so they should not spuriously probe page two.

The reproduced independent defect was the default `cur_size=4` in `S_LCALL` and
`S_RETF`: legal WORD boundary accesses could be checked as DWORDs. RETF reads
also used legacy `bd_wstrb=0`, meaning a whole DWORD on the memory interface.
The coherent fix is `cur_size=lc_callw` for LCALL,
`cur_size=q_w` for **all** RETF slots, and RETF read strobes `strb_of(q_w)`.
Changing `cur_size` alone does not make bypass/MMIO reads byte-exact. No fix
is included in the fixture itself. Intel 1997 SDM Vol2 RET pp3-409–412 distinguishes WORD vs
DWORD pops from stack address size; the pinned QEMU helper uses corresponding
word/dword loads. These fixtures use legal ranges, avoiding QEMU's incomplete
ordinary segment-limit enforcement as an oracle for invalid accesses.

Host-only assembly, explicitly selecting a real root-filesystem output leaf:

```sh
tools/build_scope.sh -- timeout --kill-after=5s 55s \
  make -C verif/sys/tests/pfarwordwidth -j2 \
  OUTDIR=/absolute/owned/nonsymlink/obj_dir_leaf check-host
```

The standalone gate never rebuilds a model or assembles a guest implicitly.
Supply reviewed prebuilt images and a frozen TB with its actual compile
record. Segment cases require the recorded `VEN_SEG_ENFORCE`, not an
environment claim. Run individual cases first; the unmodified model is
expected to fail WORD segment cases and WORD RETF page cases.

```sh
bash verif/sys/run-pfarwordwidth-gate.sh \
  --tb /absolute/frozen/tb_ventium --tb-sha256 SHA256 \
  --compile-sha256 SHA256 --fixtures /absolute/prebuilt/images \
  --out /absolute/owned/nonsymlink/fresh_leaf --cases 1 --jobs 1
```

Native children use normal `--cosim --system`, actual ISA-debug-exit133,
separate stdout/stderr, canonical fault grammar with **zero** fault events,
matching stop/footer/I/O closure, and complete bounded traces. Both a free
pinned QEMU exit133 and its full GDB trace are required. The canonical
`compare.py --mode func --all` grades every record without new masks.
The whole scope is capped at540s, each RTL60s/QEMU trace90s/free QEMU30s;
up to four light cases may run in parallel, with distinct GDB ports.
Receipts preserve input, trace, log, compile, and binary hashes. A timeout,
exception, unexpected fault, bad witness, descendant leak, truncation, or
changed input fails closed. This is not full standard-suite acceptance.

## October 1 regression result

Frozen pre-fix TB `fe4a21d7` reproduced false #SS in cases1/2 and a false
#PF in case4; DWORD control17 passed. The primary faults are in `rtl.stdout`,
not just `rtl.stderr`. Their subsequent exception delivery also exposed a
separate same-privilege DWORD-gate stack-address wrap defect; these legal-access
tests do not establish that separate defect repaired.

Width-fixed TB `ba8effe8`, compile-record `c9027d1a`, passed **all32 cases**:
free QEMU exit133, completed GDB trace, actual native exit133, zero canonical
faults, full architectural comparison and stable input hashes. The local
summary is `ao486-sim/obj_dir_win95_retf_oct01.pP4BlM/design/pfarwordwidth-fixed-oct01.1/summary.json`,
SHA256 `a9be776af1f491db4f67ef381f279974639625639c72f60a967354e218b31bb6`.
The20 host tests passed too. This covers both CS.D values, both SS.B values,
WORD/DWORD frames and segment/page boundaries; it does not prove MMIO read
side-effect behavior, outer-privilege returns, Win95 desktop or Quake completion.
