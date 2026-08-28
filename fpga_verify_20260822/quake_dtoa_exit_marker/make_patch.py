#!/usr/bin/env python3
"""Exit Quake's broken fractional dtoa loop after one emitted digit."""
import argparse
from hashlib import sha256
from pathlib import Path
HERE = Path(__file__).resolve().parent
SRC = HERE.parent / "quake_norender_heapscan" / "QUAKE_NORENDER_HEAPSCAN.EXE"
SHA = "16cfc75dc096bf5b1a9869f469e1e5d009a84737a7e380e29385a8588e4a79e3"
DTOA, RESULT, LOGGER = 0x540D1, 0x37E0, 0x6344
RCTX = bytes.fromhex("e8cd2b000083c41883c404c374696d65")
RREP = bytes.fromhex("e80700000083c41883c404c383c404c705480b0900c9030000e8b42b000068e53f0000c3")
def main():
 p=argparse.ArgumentParser(); p.add_argument("--keep-logger",action="store_true"); a=p.parse_args()
 b=bytearray(SRC.read_bytes())
 if sha256(b).hexdigest()!=SHA or b[DTOA:DTOA+6]!=bytes.fromhex("0f8577ffffff") or b[RESULT:RESULT+len(RCTX)]!=RCTX or b[LOGGER:LOGGER+10]!=bytes.fromhex("57538b5c240c8d442414"): raise SystemExit("unexpected context")
 b[DTOA:DTOA+6]=bytes.fromhex("e90100000090")
 b[RESULT:RESULT+len(RREP)]=RREP
 if not a.keep_logger: b[LOGGER]=0xc3
 out=HERE/("QUAKE_DTOA_EXIT_MARKER_QEMU.EXE" if a.keep_logger else "QUAKE_DTOA_EXIT_MARKER.EXE")
 out.write_bytes(b); print(out.name,sha256(b).hexdigest())
if __name__=="__main__": main()
