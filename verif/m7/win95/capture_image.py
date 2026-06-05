#!/usr/bin/env python3
"""M7.3b harness fix: re-run ONLY PASS A (initial phys-mem image capture) of the
M7.3a producer, so the image.json covers the extended _INIT_MEM_REGIONS (now
including the 0xE0000..0xEFFFF PM-POST BIOS shadow that golden record 31's
`jmp edx` enters). The golden .vtrace is deterministic and UNCHANGED — only the
phys-memory image sidecar is regenerated. This calls the exact same
gen_trace._capture_initial_phys_mem used by the full --system-replay producer,
so the captured bytes are bit-identical to what PASS A would have written.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
QTRACE = os.path.join(HERE, "..", "..", "qemu-trace")
sys.path.insert(0, QTRACE)
import gen_trace  # noqa: E402
import tracefmt   # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
QEMU = os.path.join(REPO, "ventium-refs",
                    "07-p5-emulation-harness", "build", "qemu",
                    "build-sys", "qemu-system-i386")
OVERLAY = os.path.join(REPO, "build", "m7", "win95", "overlay.qcow2")
IMAGE_OUT = os.path.join(REPO, "build", "m7", "win95", "win95-boot.image.json")
PORT = 56321  # gdbstub, within the allowed 56000-56999 range
RAM_MB = 64
CPU = "pentium"

def main():
    sys.stderr.write("[capture_image] regions_spec = %s\n"
                     % gen_trace._INIT_MEM_REGIONS)
    img = gen_trace._capture_initial_phys_mem(
        QEMU, OVERLAY, PORT, RAM_MB, CPU, verbose=True)
    if img is None:
        sys.stderr.write("[capture_image] FAILED: PASS A returned None\n")
        return 1
    with open(IMAGE_OUT, "w") as f:
        f.write(tracefmt.dumps(img) + "\n")
    n_bytes = img["meta"]["bytes_captured"]
    sys.stderr.write("[capture_image] wrote %s (%d regions, %d bytes)\n"
                     % (IMAGE_OUT, len(img["regions"]), n_bytes))
    return 0

if __name__ == "__main__":
    sys.exit(main())
