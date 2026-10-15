# Golden transport ownership — October 15, 2026

The old producer could connect to a different QEMU when its requested TCP port
was occupied. A valid trace header names the requested ELF, not necessarily the
program actually connected. Consequently a successful producer exit was not
proof of the golden's identity. Its final RSP `k` could also kill that other
inferior. Changing port numbers or retrying on the adjacent worker's port is
not a repair.

## Evidence and repair

`fetch-fragment-func-r1` closed **107 PASS / 1 FAIL**. The `t_fastmem` golden
contains `t_faststack` bytes and 384 records rather than the target's 201.
Port41345 was occupied by Steam; worker retries advance to the neighboring port.
The first-attempt error was overwritten, so that particular retry sequence is
inferred, not claimed as a retained observation. The bad trace remains intact.

[owned_gdb.py](owned_gdb.py) now allocates a private Unix socket for each of the
four producer paths: user, system, syscall proxy, and reset-memory capture.
Before sending any RSP command it verifies the peer PID/UID/GID against the live
QEMU child using Linux [SO_PEERCRED](https://man7.org/linux/man-pages/man7/unix.7.html).
Child exit and connection timeout fail closed. Cleanup releases only this
producer's newly created temporary directory, after the child is reaped.

Long `TMPDIR` paths use `/proc/<owner-pid>/fd/<directory-fd>/gdb` as a short
socket-path alias. The socket and directory remain on the requested filesystem;
there is no fallback directory on the root disk. Linux procfs and SO_PEERCRED
are required. Exec-only launchers such as `setarch` preserve the checked PID;
forking wrappers fail authentication. Guest arguments named `-g` remain valid.

`--port` remains accepted for existing callers but is unused by owned launches.
Explicit external callers of `RSPClient(host=..., port=...)` retain TCP behavior;
that API is not an authenticated golden launcher. No stepping, architectural
field, comparison mask, instruction limit, QEMU binary or RTL changes are part
of this repair. The production canonical oracle is not replaced by the private
reference experiment.

The worker's functional cache identity now includes the generator, transport
helper and trace-format source hashes. Its cycle-to-functional ESP lookup uses
the same key; plugin cycle keys remain unchanged. Thus old contaminated entries
are bypassed, not deleted or relabelled. See
[prepare_owned_gdb_cache.py](../lib/prepare_owned_gdb_cache.py).

## Qualification

Scratch evidence root:
`/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

- Five host transport tests: long-path creation/cleanup, foreign-peer rejection
  without sending bytes, child exit and timeout, launch failure cleanup, all
  four owned launch paths (non-GDB replay stays unchanged).
- Two producer-cache tests plus three earlier observer/ESP identity tests pass.
  All three dependency changes invalidate functional keys but not cycle keys.
- Six existing hidden-CS observer tests pass.
- [Native qualification](run_owned_gdb.py), `owned-gdb-r4`: the pinned original
  producer returns a wrong-program 64-record trace when colliding with a QEMU
  created by this test. Socket-inode ownership is checked before reproducing
  that unsafe behavior; unrelated applications are never contacted or killed.
- The fixed producer captures its own 16-record target, including x87 state,
  and leaves the deliberately conflicting QEMU at its original instruction.
  Eight simultaneous/same-port captures match the clean control. A guest `-g`
  argument is also tested. Full system traces match over 439 records; syscall
  proxy traces match over 16 records; reset physical-memory images match over
  589,824 bytes. No architectural fields are masked. Proxy initial sidecars
  are retained but are not the stated equality criterion.
- Native R1 was a launcher error (nonexistent fixture0). R2 compared plain
  `StopReply` objects by Python identity and failed despite byte-identical
  traces. R3 compares their semantic exit fields and passes. R4 adds the guest
  option compatibility case. Failed evidence is retained separately.
- `fetch-fragment-owned-func-r1`: **108/108 private functional PASS**,
  110.28 seconds, all QEMU/RTL child affinities observed on CPU13–16, no OOM.
  The final guest-option-compatible helper is requalified separately in R4;
  `fetch-fragment-owned-func-r2` also closes **108/108 PASS**, in 110.58 seconds,
  with unchanged pins, observed child affinities and no OOM. Its closure SHA-256
  is `55712af50f9d8a69cfa0763fe27fa4bd409693fe5edffb9552a26980ed0d5569`.
  R4 native closure SHA-256 is
  `7f392a2dbedaefb301c1cbba3c556e1d798ab057d26726a992d5498a574c4c3a`.
  The separate same-input A/B status is recorded in
  [FETCH_FRAGMENT_EXTENT.md](../fe_pipe/FETCH_FRAGMENT_EXTENT.md).

This is verification-infrastructure evidence, not processor performance or
standard-suite/FPGA acceptance. Latest verified gameplay is **0.50520554 total
U+V IPC**, older model `c7b95b78`, cycles **5,600,065,237–5,700,065,237**. The
current timing candidate has no gameplay measurement.
