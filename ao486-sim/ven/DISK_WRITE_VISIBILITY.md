# Simulator Disk-Write Host Visibility (`ao486-sim/ps/ps_shim.cpp`)

In `ao486-sim/ps/ps_shim.cpp`, guest IDE/VHD sector stores pass through
`FileWriteAdv` and `FileWriteSec`. Leaving written bytes buffered inside `libc`
`FILE*` streams caused two host-side defects during long full-PC simulations:

1. External host observers inspecting a live guest FAT/result sector saw stale
   on-disk bytes until a subsequent `fseek` or simulator exit flushed the buffer.
2. Deferred `libc` buffer flushes (for example against a full scratch volume or
   `/dev/full`) falsely returned write success at sector-submission time.

`FileWriteAdv` (shared by `FileWriteSec`) requires both a complete `fwrite` **and
an immediate `fflush == 0`** before reporting success to the ATA layer. This
guarantees immediate visibility to independent host file descriptors on the same
machine without adding guest cycles, altering RTL timing, or forcing `fsync`
disk-platter latency on every sector.

> **Qualification Context (`c0e3fe43`, 2026-11-14):** This is a host C++
> simulator I/O invariant, not a CPU/RTL change. Current verified physical Quake
> gameplay IPC is **`0.515778001` total U+V** (`0.397847833` primary/U-only,
> counters include `REP`-element retirement) on **RK-XCZU15EG-F** release image
> **`c0e3fe43`** across cycles **`28,696,827,616–32,989,404,795`** (`8.0 FPS` at
> `40.000 MHz`, `40.264133 MHz` STA-signed-off).

---

## Standalone Regression (`test_disk_write_visibility.cpp`)

`ao486-sim/ven/test_disk_write_visibility.cpp` links against the real
`ps_shim.cpp` implementation and verifies:

- **18 live-visibility cases** (`1`, `511`, `512`, `513`, `4096`, and `8192`
  bytes across three file offsets) read back through an independent open file
  descriptor *before* closing the writer, confirming exact payload bytes and
  untouched neighboring bytes (`0/18` stale reads).
- **2 write-error cases** against `/dev/full`, confirming immediate failure
  return rather than silent buffered acceptance (`0/2` false successes).

Run the candidate check directly against any private `Vsystem.h` model directory
and `/tools/verilator/v5.046/share/verilator/include`, or run the full
control-versus-candidate runner (`run_disk_write_visibility.py`) with a
pre-fix `ps_shim.cpp` control (`623dcb7e…`) and a fresh `/home/yukidama/external/tmp`
leaf:

```sh
export TMPDIR=/home/yukidama/external/tmp
VINC=/tools/verilator/v5.046/share/verilator/include

# Standalone candidate check against a private full-PC model directory:
g++ -std=c++17 -O1 -ffunction-sections -fdata-sections \
  -I"$VARIANT_OBJ" -I"$VINC" -I"$VINC/vltstd" -Iao486-sim/ps \
  ao486-sim/ps/ps_shim.cpp ao486-sim/ven/test_disk_write_visibility.cpp \
  -Wl,--gc-sections -o "$TMPDIR/test-disk-write-visibility"
mkdir -p "$TMPDIR/stdio-vis-data" && "$TMPDIR/test-disk-write-visibility" "$TMPDIR/stdio-vis-data"

# Full control + candidate receipt runner (requires pre-fix 623dcb7e control shim):
python3 -B ao486-sim/ven/run_disk_write_visibility.py \
  --control-shim /path/to/frozen/pre_fix_ps_shim.cpp \
  --model-dir "$VARIANT_OBJ" \
  --out "$TMPDIR/stdio-visibility-check"
```
