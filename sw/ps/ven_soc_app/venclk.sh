#!/bin/sh
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# venclk.sh — set / step / smoke-test the Ventium PL core clock from the PS.
#
# On the ZynqMP the PL fabric clock pl_clk0 is PS-owned: CRL_APB.PL0_REF_CTRL
# (0xFF5E00C0) selects the PLL source and two dividers. This design's psu_init
# uses IOPLL=1000 MHz with DIVISOR0=25 -> 40 MHz (the timing-closure target;
# sign-off margin ends ~40.4 MHz — anything above is silicon-lottery overclock).
# Steps with DIVISOR1=1: div 25..20 -> 40 / 41.7 / 43.5 / 45.5 / 47.6 / 50 MHz.
#
#   venclk.sh status            read the register + compute the frequency
#   venclk.sh set <div>         hold core in reset, set DIVISOR0=<div>, release
#   venclk.sh ramp              step 25->20, smoke-testing psocfw at each step;
#                               stops (and steps back) at the first failure
#
# The smoke test = the gate-proven F2 firmware (psocfw banner + isa-debug-exit):
# ven_soc_app exits cleanly only if the core executed it correctly end-to-end.
# Requires root (devmem + /dev/mem). NOT a supported operating point above 40MHz.
set -eu

CRL=0xFF5E00C0
IOPLL_MHZ=1000
APP=/usr/local/bin/ven_soc_app
FW=/usr/local/share/ventium/psocfw.bin

DEVMEM() { busybox devmem "$@" 2>/dev/null || devmem "$@"; }

status() {
    v=$(DEVMEM $CRL)
    d0=$(( (v >> 8) & 0x3f )); d1=$(( (v >> 16) & 0x3f ))
    [ "$d1" -eq 0 ] && d1=1; [ "$d0" -eq 0 ] && d0=1
    echo "PL0_REF_CTRL=$v  DIVISOR0=$d0 DIVISOR1=$d1  -> $((IOPLL_MHZ / (d0*d1))) MHz (IOPLL $IOPLL_MHZ)"
}

setdiv() {
    div=$1
    [ "$div" -ge 10 ] && [ "$div" -le 63 ] || { echo "div out of range (10..63)"; exit 1; }
    v=$(DEVMEM $CRL)
    nv=$(( (v & ~0x3f00) | (div << 8) ))
    printf 'PL0 div %d -> %d MHz\n' "$div" $((IOPLL_MHZ / div))
    DEVMEM $CRL 32 $(printf '0x%08x' "$nv")
}

smoke() {
    # run the F2 firmware; ven_soc_app exits 0 on the clean isa-debug-exit.
    timeout 30 "$APP" "$FW" 0xF0000 0x0 0x000FFFF0 --sys >/dev/null 2>&1
}

case "${1:-status}" in
    status) status ;;
    set)    setdiv "${2:?usage: venclk.sh set <div>}"; status ;;
    ramp)
        last_good=25
        for d in 25 24 23 22 21 20; do
            setdiv "$d"
            if smoke; then
                echo "div=$d ($((IOPLL_MHZ / d)) MHz): PASS"
                last_good=$d
            else
                echo "div=$d ($((IOPLL_MHZ / d)) MHz): FAIL — stepping back"
                setdiv "$last_good"
                break
            fi
        done
        echo "final operating point:"; status ;;
    *) echo "usage: venclk.sh {status|set <div>|ramp}"; exit 1 ;;
esac
