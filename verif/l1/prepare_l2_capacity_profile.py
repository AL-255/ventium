#!/usr/bin/env python3
"""Exact platform-only profile selection; preserves all other SoC source bytes."""
from prepare_l2_capacity import transform


def capacity_profile(cache, system, sets):
    if sets not in (128, 256, 512, 1024):
        raise ValueError('supported cache sets: 128, 256, 512, 1024')
    # This experiment must not resurrect the already fixed replacement bug.
    for token in ('LRU_wraddr <= LRU_addr;', '.wraddress(LRU_wraddr)',
                  'LRU_we && (LRU_wraddr == LRU_addr)',
                  'LRU_write_through ? LRU_in[lru_rank_way] : LRU_out[lru_rank_way]',
                  'LRU_addr <= CPU_ADDR[LINEMASKMSB+1:LINEMASKLSB+1];'):
        if cache.count(token) != 1:
            raise ValueError('missing/ambiguous replacement repair: '+token)
    if system.count('l2_cache cache') != 1 or 'CACHE_SETS' in system:
        raise ValueError('missing/ambiguous unparameterized platform L2 instance')
    # Replace only this token, preserving CRLF/LF and all other system bytes.
    return transform(cache), system.replace('l2_cache cache',
        f'l2_cache #(.CACHE_SETS({sets})) cache')
