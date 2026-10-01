# POP-memory ESP-base precision

The first two fixtures independently reproduced the defect on frozen TB
`9a7976f7` against private pinned QEMU `b42b70e5`: QEMU exited133, RTL135.
CASE1 uses the exact CS16 bytes `67 66 8f 44 24 08 66 cb`; the stale
destination overwrote the following RETF selector. CASE2 reads an independent
destination sentinel, without relying on RETF. Both original images and their
source archive remain under `obj_dir_espdebug_oct01.eo9QA1/ppopespea-images-oct01.1`.
After the central decoder repair, frozen TB `80d89a33` passed both original
136-record goldens with unmodified `compare.py --mode func --all`, native133.

The first matrix on `.3` images passed CASE1–11 and14 on frozen80d89a33;
CASE12/13/15/16 failed in free QEMU before any RTL. Preserve that closed
FAIL result at `obj_dir_popesp_oct01.Ohf0sN/ppopespea-qualified-oct01.1`.
The old CASE14 displacementDFA selected2DFE, so its PASS is **not** a
cross-page witness. New CASE14/15 useFFA, selecting2FFE through3001;
assembly and host image checks enforce this exact boundary geometry.
Original `.3` images and matching source/checker archive
`ppopespea-fixture-failure-oct01.1` remain unchanged. Updated fault/cross-page
cases are covered by the fresh final qualification below:

| CASE | Independent witness |
|---|---|
| 1 | Exact CS16 Win95 POP32/RETF32 thunk, SS.B0 |
| 2 | CS32 POP32 `[ESP+8]`, SS.B1 sentinel |
| 3–5 | POP16 B0/B1 and POP32 B0, nonzero high ESP |
| 6–7 | POP16/32, SS.B0 low-SP wrap, nonzero high ESP |
| 8 | POP32 SS.B1 control at1FFFC, scaled SIB index |
| 9 | Negative displacement / destination aliases source |
| 10 | Explicit ES destination override plus disp32 |
| 11 | Non-ESP base; independent address16, POPEDI, POPESP controls |
| 12 | Destination non-present write #PF2 / old ESP and source preserved |
| 13 | Intel-spec-only destination SS-limit #SS0 / old ESP and source preserved |
| 14 | Successful DWORD destination crosses4KiB; one final ESP increment |
| 15 | Second destination page read-only, CR0.WP1: #PF3, no partial store |
| 16 | Implicit source #PF0 before destination or ESP effects |

SS.B0 wrap destination follows this exact pinned oracle's full32-bit
`oldESP + operandwidth + index*scale + displacement`; architectural SP update
preserves high ESP. Later Intel manuals describe the wrap write location as
processor-family-specific; these cases are not a universal CPU-family claim.
Implicit source still uses SS:maskedSP; destination segment override does not
affect the source. Broad SS limits prevent unrelated source/destination faults.

Fault handlers examine the actual error/IP/CS/exact savedFLAGS2 frame and
unchanged GPRs before changing observers or disabling paging. They never IRET,
so precision does not rely on a return-path fix. Canaries are read only after
paging is disabled on fault; absent guest pages are not used as live read probes.
The shared legacy trace convention includes one fault-delivery marker at the
faulting PC: the checker preserves it and demands adjacent handler entry.

SavedFLAGS2 is explicitly the current pinned-QEMU/model profile, not Intel
automatic fault-RF qualification. The original10002 fixtures fail at the
exact flags compare for CASE12/16, after correct error/IP/CS/oldESP checks.
Pinned QEMU `excp_helper.c:91–112` does not set RF while raising the fault;
`seg_helper.c:760–767` pushes unmodified `cpu_compute_eflags`. Current RTL
`core_bus_driver.svh` S_INT_PUSH likewise pushes unmodified EFLAGS.
Intel1997 Vol3 printed14-9 (PDF419) requires automatic RF for fault-class
exceptions except instruction-breakpoint #DB. That independent pre-existing
fidelity gap remains open; these POP tests neither fix nor mask it, and no
canonical differential flags mask was changed.

CASE13 is a separate Intel-spec SS-limit witness, not a QEMU correctness pass.
The pinned QEMU per-access address generator adds the segment base but does
not enforce its limit: actual original golden POP completed atESP12004 without
#SS and then correctly took the fixture's failure exit135. The gate requires
that fresh QEMU limitation exit135 separately, and native133 with the exact
#SS0/frame/oldESP/no-effect witnesses and actually compiled VEN_SEG_ENFORCE.
No invented golden, filtered records or relaxed differential are used.

Build into a fresh, owned root-filesystem leaf; no canonical model rebuild:

```sh
make -C verif/sys/tests/ppopespea -j4 OUTDIR=/absolute/owned/fresh-images
PPOPESPEA_IMAGES=/absolute/owned/fresh-images python3 -B -m unittest discover \
  -s verif/sys/tests/ppopespea -p test_check_witness.py -v
bash verif/sys/run-ppopespea-gate.sh \
  --tb /absolute/frozen/tb_ventium --tb-sha256 SHA256 \
  --compile-record /absolute/frozen/Vventium_top__verFiles.dat \
  --compile-sha256 SHA256 --compile-cwd /absolute/repo/verif/tb \
  --fixtures /absolute/owned/fresh-images --out /absolute/owned/fresh-results \
  --cases all --jobs 4
```

Except explicit CASE13, the guarded gate requires pinned free QEMU133, complete golden/native traces,
native133 with exact fault counts and footers, full architectural differential,
and unchanged binary/compile/source/fixture pins. All failures remain on disk.
540s outer bound; 30s freeQEMU, 90s golden, 60s native per case, at most4 jobs.
Host-only contract tests are not DUT/QEMU qualification or standard-suite
acceptance. The suite still requires CoreMark, error-free Win95 desktop, and
completed Quake timedemo.

## Corrected cross-page red/green

On frozen TB `4b81d6a5`, the corrected CASE14 (`2FFE..3001`) reaches the
POP with ESP2000 but retires atESP2008, versus the unchanged QEMU ESP2004.
The preliminary first-page ACK was updating GPRs before S_STORE's final
whole-store commit. `core_gpr_wb.svh` now uses the same final-ACK predicate
as the sequencer and store-lock completion; no extra stall or FSM is added.
Closed red summary SHA256:
`8941a876aa43683302b768842eca91ccad23c92d7033f260beff65895fb9df0a`.

Final frozen TB `2ce6ac0a` / compile record `65bab228` passes all16:
15 complete unfiltered QEMU differentials and the separately labelled CASE13
Intel SS-limit witness. The successful split POP is3237 records/25306 clocks;
fault cases retain old ESP and precise/no-partial-write checks. Native exits
are133, all groups close, and all model/source/fixture pins are unchanged.
Final summary SHA256:
`9c0d585b4abbe35df2c3781d1d13e10ea1a26f59c6ebfeb054572793bc4e272e`.
This does not close the independent automatic-RF fidelity gap described above.
