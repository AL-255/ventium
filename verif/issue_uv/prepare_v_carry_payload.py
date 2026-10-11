#!/usr/bin/env python3
"""Remove paired-acceptance gating from V's carry *payload*, not retirement.

Private successor to the exact FP-only ACK-cut core. V ALU/flags have only
paired architectural consumers; their enables must remain unchanged. A
failed/unpaired V may compute a different unused value. No architectural
forwarding, instruction eligibility, fault guard or clock is removed.
"""
import hashlib

PARENT_SHA = '93865328ee935db1f1bf0677fce39f6071af14f9ea4f98be44569c6d91a95f83'
OLD = '''  always_comb begin
    v_input_flags = eflags;
    if (pipe_pair_eff && pipe_u_eff.wflags)
      v_input_flags[0] = pipe_u_eff.is_shift
                      ? ((u_shift_cnt != 0) ? u_shcf : eflags[0])
                      : u_flags[0];
  end'''
NEW = '''  // V's ALU/flags are consumed only by paired architectural writeback.
  // Prepare that payload independently of the late memory ACK / pair permit.
  // Keep every write/retire enable unchanged. With no accepted V, this value
  // is unobserved; with an accepted V, it is exactly the former forwarded CF.
  // In particular, a zero-count U shift still preserves the incoming carry.
  always_comb begin
    v_input_flags = eflags;
    if (pipe_u_eff.wflags)
      v_input_flags[0] = pipe_u_eff.is_shift
                      ? ((u_shift_cnt != 0) ? u_shcf : eflags[0])
                      : u_flags[0];
  end'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT_SHA:
        raise ValueError('not the source-qualified FP-only ACK-cut core')
    if source.count(OLD) != 1:
        raise ValueError('V carry payload predicate drift')
    return source.replace(OLD, NEW)
