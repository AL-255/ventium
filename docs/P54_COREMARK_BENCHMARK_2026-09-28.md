# CoreMark on the current Ventium P54 candidate (2026-09-28)

## What is being measured

The benchmark is the pinned static i586 CoreMark ELF at
`ventium-refs/07-p5-emulation-harness/benchmarks/bin/coremark` (SHA-256
`8d8b84ad407b1ec35344415084fa4b77afa9dfd2b6369e1677345816ee2c7dbe`),
compiled with GCC 13.3.0 `-O2` via `p5cc` (`-m32 -march=pentium`, static musl).
It runs under the current `ff0a80397798672f27632ad7af8f51d16277a342`
`verif/tb/obj_dir_p54_fpstack/tb_ventium` binary (SHA-256
`2236d0ef99ee5c22854509b077873818382ea0dc70af54a27579bd3995f8f40a`).
The build contains the P54 IPC define profile and the L1/AXI modules, but
this Linux-user ELF is run in the TB's **direct-memory cycle mode**, not the
ao486 full-PC or FPGA memory system. Each input image comes from pinned
QEMU `-cpu pentium -seed 1234` with seeds `0,0,0x66`, algorithm mask 7,
CoreMark's default 2000-byte total dataset (it prints size 666 per algorithm).

The normalized score is calculated from RTL clock counts, not from the
testbench's synthetic Linux time syscall:

`CoreMark/MHz = iterations × 1,000,000 / RTL cycles`.

The free-run syscall emulator's time has a 1-second initial floor and a
1-ms-per-call floor. For a short run, CoreMark's own `Iterations/Sec` line
is therefore not a usable performance measurement; the cycle count is.
The RTL invocation is `tb_ventium --quake-image <QEMU-produced image.json>
--emulate-syscalls --no-trace --cycle --max-insn 1000000000
--max-cycles 1200000000 --user-stdout <output>`. `--max-insn` is explicit
because the TB's default cap is only 1,048,576 instructions.

## Calibration and status

The 100-iteration run exited normally (`exit_group(0)`) after **36,188,797
retirements in 55,235,622 RTL clocks** (IPC **0.6552**). Its expected data
CRCs matched pinned QEMU: `crclist=e714`, `crcmatrix=1fd7`, `crcstate=8e3a`,
`crcfinal=988c`. The cycle-derived **short-run estimate is 1.810425888
CoreMark/MHz**. CoreMark prints `Errors detected` solely because its elapsed
synthetic time is 0.001 s, below its required 10 s. This is *not* an
EEMBC-reportable score. Raw logs and QEMU-derived image are under
`/home/yukidama/ventium-bg-sep28/coremark_candidate_ff0a803/`.

A 1500-iteration run has been launched to exceed the 10-second guest-time
threshold. Its measured result should replace the short-run estimate only
after normal exit, expected CRC validation, and a check that the elapsed
synthetic guest time is at least 10 seconds.

A short, independent validation-seed RTL run (`0x3415,0x3415,0x66`, 10
iterations) also exited normally after 5,643,162 clocks; `crclist=e3c1`,
`crcmatrix=0747`, `crcstate=8d84`, `crcfinal=c64e` all match pinned QEMU for
the same 10 iterations. A 1500-iteration validation-seed run is proceeding
concurrently. Neither short run satisfies the required duration by itself.

Enabling `--l1-axi` for the QEMU Linux-user image is not valid in this TB:
the guest stack starts at `0x407ff510`, outside the no-L2 DRAM routing
aperture, so the run faults after four retirements with the explicit
`[L1AXI] R2-H03 ROUTE-ERR` at `0x407ff50c`. No score from that failed run
is used. A full-cache CoreMark result needs a guest image and memory map
designed for the SoC, not a flag change.

## Reported P54C comparison

[Wenting's CoreMark table](https://zephray.me/coremark/) reports a physical
Pentium P54C at 133 MHz scoring 281 CoreMark, or **2.1 CoreMark/MHz**
(281/133 = 2.113); its stated compiler is GCC 8.4.0 `-O2 -march=i486`.
This is a published, self-reported machine result, not one independently
certified here by EEMBC.
Against the table's rounded 2.1 figure, the short-run RTL direct-memory
estimate of 1.8104 is **13.8% lower**. This is a directional comparison,
not an apples-to-apples silicon score: compilers, libraries, memory systems,
and execution environments differ. The repository's older **2.25
CoreMark/MHz** figure is a QEMU-trace/P5-model *estimate*, not measured
Ventium RTL or physical silicon. [EEMBC's CoreMark rules](https://github.com/eembc/coremark)
require a run of at least 10 seconds and successful validation of both
specified seed configurations before an official result is reported.

Current verified **Quake gameplay IPC is 0.457219** on the current `ff0a803`
candidate over cycles 1,150,000,531–1,400,000,000; it is a different
workload and must not be substituted for the CoreMark IPC above.
