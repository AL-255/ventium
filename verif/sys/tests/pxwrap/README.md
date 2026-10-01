# pxwrap segment-offset legalization

The differential matrix still has 351 cases: 348 page denials, each followed
by its permitted refire, plus three V86 controls. Expected trigger deliveries
remain 332 `#GP(0x60)` events. No RTL or differential mask changes are involved.

The original B=1 `ESP0=2, SS.base=0` INT and call-gate layouts put their first
dword at **segment offset** `0xFFFFFFFE`. This is illegal: its last two bytes
exceed the segment's effective `0xFFFFFFFF` limit. Intel's 1997 Volume 3,
section 4.3, requires a doubleword offset to be at most `effective-limit - 3`.
Wrapping SP/ESP between separate stack operands is different from allowing
one operand's bytes to exceed its segment limit. QEMU 8.2.2 misses this check.

Those four deny cases are now represented by `ESP0=0, SS.base=2`, using a
dynamic writable B=1 descriptor with the same full effective limit. For every
slot, subtracting two from its offset and adding two to the base preserves
the exact linear bytes. The first dword now has legal offset `0xFFFFFFFC`,
but still starts at **linear address** `0xFFFFFFFE` and crosses into page zero.
Thus both denied pages, their push order, the fault slot and CR2 are retained.
Other B=1/base-zero cases keep the original flat SS selector `0x10`.

The sentinel fill already uses the case's base and individual byte accesses.
INT32 frame reads already address SS through ESP. CG32 frame reads now use
an explicit SS override on their manually masked offsets: adding the base
into a flat-DS dword operand at `0xFFFFFFFE` would recreate the same illegal
segment access in the verifier. B=0 cases retain 16-bit SP masking, but their
G=1 descriptors have a 4-GiB segment limit, not a 64-KiB limit.

`python3 -B test_gen_cases.py` is a host-only check. It independently enumerates
the original matrix, compares every linear byte/page/fault address, proves
each new slot fits the segment limit, rejects illegal old constructions,
and pins the unchanged `pxwrapm_cases.inc` bytes. It is **not** an architectural
DUT test. A fresh complete QEMU/RTL differential gate passed on October1:
112630 records match the frozen enforcing-profile TB `6aeaff4b...` and pinned
QEMU. Canonical fault grading counts exactly 348 `#PF(2)`, 332 `#GP(0x60)`
and the one intended V86 `#GP(0)`, with no escalation or extra classes.
Artifacts: `verif/tb/obj_dir_bitmem_sep30.aUqHZB/pxwrap-legal-oct01.1/`.
This is fixture qualification, not Win95 desktop or standard-suite acceptance;
old goldens remain inapplicable to the changed setup instructions/selectors.

## Separate rejected-extent witness (proposed, not yet implemented)

Keep the original illegal layout as a dedicated RTL/Intel architectural
witness instead of silently treating QEMU's acceptance as correct. Install
a same-CPL3 `#SS` handler, a valid cross-privilege INT32 gate, and TSS
`SS0:ESP0=0x10:2`. Run with the destination pages (a) present and (b) denied.
Both must produce `#SS(0x10)` at the original INT PC **before any frame write,
page-fault delivery, new SS/CPL/ESP commit, or CR2 change**. Add a legal
`SS0:ESP0=0x30:0, SS.base=2` control proving the corresponding linear wrap
delivers successfully or gets the expected `#PF(err=2)` when denied. This
requires an explicit Intel-spec witness gate, because pinned QEMU misses
the invalid operand's segment-limit check; do not weaken the differential
matrix to admit it.

The existing closed failing capture does not establish a PF-before-SS bug:
its 303 page faults belong to the first 303 legal deny cases. Case 303
(`ESP0=0/base=0`) records CR2=`0xFFFFFFFC` and returns; case 304 then rejects
the invalid slot with `#SS(0x10)` while retaining that previous CR2. Its
unconfigured exception path escalates to shutdown, and the observer stops
after 400 clocks without retirement. This is not a 16M-clock timeout or proof
of a deadlock in the frame-probe FSM.
