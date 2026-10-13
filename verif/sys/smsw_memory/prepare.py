"""Unpromoted general memory-SMSW repair, derived from PRIME-CS inputs.

No in-place edits, new FSM, feature switch or workload-specific condition.
Native whole-core differential/fault gates are required before promotion.
"""
import hashlib

PARENTS = {
    'core.sv': '8dc1180b154b99b7fdf586071ca53d72427f09648403cf8f0120a4f570e3ed8d',
    'decode_stages.sv': 'bd01c3a8dc5d9b2d456e1a974fdfab5679808d0e617261ed4cba72642f113e3f',
    'core_fetch_decode.svh': 'e1b177c93b323fc4cc9956e92723de52179fd1b126e6841f5d48d76f491c1d38',
}

OLD_DECODE = """          end else if (modrm_reg==3'd4 && modrm_mod==2'b11) begin
            // SMSW r16/r32 (0F 01 /4, register form). Real boot/DOS code
            // (CWSDPMI's PE probe) reads CR0 this way. Reuse the MOVCR_FROM datapath
            // (creg0); QEMU chooses effective operand size for register SMSW,
            // while its memory form is always16 bits (still deferred here).
            d_sysop=SYS_MOVCR_FROM; d_smsw=1'b1; d_sys_creg=3'd0; d_dst_reg=modrm_rm;
            d_writes_reg=1'b1; d_w=eff_opsize?3'd2:3'd4; d_fetch_len=pfx_len+5'd3;
"""
NEW_DECODE = """          end else if (modrm_reg==3'd4) begin
            // SMSW r16/r32/m16 is unprivileged. The memory destination is
            // ALWAYS two bytes, independent of operand size. Keep the existing
            // register contract; memory uses the ordinary precise store path.
            d_sysop=SYS_MOVCR_FROM; d_smsw=1'b1; d_sys_creg=3'd0;
            if (modrm_mod==2'b11) begin
              d_dst_reg=modrm_rm; d_writes_reg=1'b1;
              d_w=eff_opsize?3'd2:3'd4; d_fetch_len=pfx_len+5'd3;
            end else begin
              d_mem_write=1'b1; d_mem_dst=1'b1; d_w=3'd2;
              begin fetch_ea_shape=1'b1; d_fetch_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
            end
"""
STORE_ANCHOR = """    end else if (q_is_mov) begin
      // F3 MOV [mem],Sreg:"""
DISPATCH_ANCHOR = '              default: state<=S_EXEC;  // MOV CRn to/from, MOV/STR sreg: no fetch\n'


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('SMSW source drift or reapplication: ' + name)
    if name == 'decode_stages.sv':
        edits = [
            (OLD_DECODE, NEW_DECODE),
            ('// existing register SMSW alias, not MOV CR', '// unprivileged SMSW alias, not MOV CR'),
            ('// register LGDT/LIDT, /4 SMSW mem, /6 LMSW etc deferred',
             '// register LGDT/LIDT, /6 LMSW etc deferred'),
        ]
    elif name == 'core_fetch_decode.svh':
        edits = [(DISPATCH_ANCHOR, """              // Only SMSW gives MOVCR_FROM a memory destination. Do not pass
              // through S_EXEC: its register arm commits a GPR unconditionally.
              SYS_MOVCR_FROM: state<=d_mem_write ? S_STORE : S_EXEC;
""" + DISPATCH_ANCHOR)]
    else:
        edits = [(STORE_ANCHOR, """    end else if (q_sysop==SYS_MOVCR_FROM) begin
      // Memory SMSW: q_w=2, ordinary EA/segment/page checks and split-store
      // preflight apply. Register SMSW/MOV CR never enter S_STORE.
      st_data = {16'd0, creg0[15:0]};
""" + STORE_ANCHOR)]
    for before, after in edits:
        if source.count(before) != 1:
            raise ValueError('SMSW ambiguous/missing anchor: ' + name)
        source = source.replace(before, after)
    return source
