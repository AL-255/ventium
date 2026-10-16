#!/usr/bin/env python3
"""Read-only clock measurement for a fresh, held-reset ABI-5 source image.

This never selects a clock, releases reset, clears counters, or changes debug
execution mode. The deployment controller must separately pin/program the
bitstream and check the DDR reservation. It is not timing or CPU acceptance.
"""
import argparse
import json
import math
import os
import time

import ven_board_probe as probe


def measure(ctrl, *, expected_mhz=40.0, api=probe,
            monotonic_ns=time.monotonic_ns, sleep=time.sleep):
    # Explicit experimental target, never an unconstrained observed-clock pass.
    # The default retains the original 39.5..40.5 MHz admission limits.
    if not math.isfinite(expected_mhz) or not 20 <= expected_mhz <= 100:
        raise ValueError('expected clock must be finite and within 20..100 MHz')
    def endpoint():
        api.require_exec_debug(ctrl)
        if (api.u32(ctrl, api.R_IDENT) != api.IDENT_MAGIC or
                api.u32(ctrl, 0x20) != 1 or
                api.u32(ctrl, api.R_DBG_FRZINFO) & 0x80000000 or
                api.u32(ctrl, api.R_DBG_CR0) != 0x60000010):
            raise ValueError('requires held-reset, non-frozen ABI-5 reset state')
        t0 = monotonic_ns()
        cycles = api.stable_u64(ctrl, api.R_DBG_CYC_LO, api.R_DBG_CYC_HI)
        t1 = monotonic_ns()
        retired = api.stable_u64(ctrl, api.R_DBG_RET_LO, api.R_DBG_RET_HI)
        if retired != 0:
            raise ValueError('fresh image already has primary retirements')
        if t1 < t0:
            raise ValueError('monotonic clock moved backwards')
        return dict(cycles=cycles, retired=retired, time_before_ns=t0, time_after_ns=t1)

    before = previous = endpoint()
    deadline = before['time_after_ns'] + 5_000_000_000
    checks = 1
    while monotonic_ns() < deadline:
        sleep(0.05)
        current = endpoint()
        if current['cycles'] < previous['cycles']:
            # A reset/clear is not a plausible 64-bit wrap in a five-second test.
            raise ValueError('cycle counter reset/clear invalidates clock admission')
        previous = current
        checks += 1
    after = previous
    minimum_ns = after['time_before_ns'] - before['time_after_ns']
    maximum_ns = after['time_after_ns'] - before['time_before_ns']
    delta = after['cycles'] - before['cycles']
    if not 4_800_000_000 <= minimum_ns <= maximum_ns <= 6_000_000_000:
        raise ValueError('clock observation duration or read uncertainty is excessive')
    lower = delta * 1000 / maximum_ns
    upper = delta * 1000 / minimum_ns
    if not expected_mhz * .9875 <= lower <= upper <= expected_mhz * 1.0125:
        raise ValueError(f'held core is not {expected_mhz:g} MHz: bounded observation {lower:.6f}..{upper:.6f} MHz')
    elapsed = (minimum_ns + maximum_ns) / 2e9
    verdict = ('PASS_HELD_RESET_40MHZ_ONLY' if expected_mhz == 40 else
               'PASS_HELD_RESET_EXPERIMENTAL_CLOCK_ONLY')
    return dict(result=verdict, expected_core_mhz=expected_mhz, before=before, after=after,
                cycles_delta=delta, retirements_delta=0, elapsed_seconds=elapsed,
                measured_core_mhz=delta/elapsed/1e6, lower_mhz=lower, upper_mhz=upper,
                guard_checks=checks, debug_abi=5, read_only=True,
                uv_fast_qualified=False, gameplay_ipc=None, sta_signoff=False,
                acceptance=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-mhz', type=float, default=40.0,
                        help='explicit core-only target; does not change any clock')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise PermissionError('must run as root on the board')
    fd, ctrl, _ = probe.open_mmio(writable=False)
    try:
        print(json.dumps(measure(ctrl, expected_mhz=args.expected_mhz), indent=2))
    finally:
        ctrl.close()
        os.close(fd)


if __name__ == '__main__':
    main()
