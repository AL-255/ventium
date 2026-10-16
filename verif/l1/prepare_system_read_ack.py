"""Exact-parent read-owner ACK cut; no new request, cycle or commit event.

Only read-only system owners use the already fragment-qualified read ACK.
Page walks split read/write guards, including the independent TLB-fill mirror.
This private derivative is not a replacement for the dirty checkout or an
acceptance claim. Every source is pinned before any transformation.
"""
import hashlib
import re

PREFIX = 'rtl/core/'
PARENTS = {
    'core.sv': '8d454c1ce275963da75354aca703701a4341b441031ae53f39e1fb911a365d0d',
    'core_int_deliver.svh': 'e37ad609ee031351d8d7fdd0cd6fe836f8bcf84b39f72a8f4663a4f38d9b146b',
    'core_iret.svh': '9905949447874d4ec9b8bcc615a532ecdb781a7c78aee995e9ea864651c40df5',
    'core_seg_ljmp.svh': '0e1a4183f4fe45f1b2f64dbbdc4326844e867ed104c04ecf503541b511623e53',
    'core_tss_priv.svh': 'a2ce97d7e68b4295b19cc45616c5caac423288470f4147018f68b17f30e870b1',
    'core_tsw.svh': '3a2884ac8c370b8f3a224d7137183c2ed47b78163499fb05ba90ca7da8335cf7',
    'core_rmint.svh': '2526f5c3bb7fb1abe0c8cd9aac701286e23a3cf5440ec1ec9c0d0b477a0c2251',
    'core_gpr_wb.svh': '4ae36b71b057a728ce077214173a99fbe653c2215e6b9256cf14dd2dc62c422b',
    'core_walk.svh': 'f9f534583e788336ad9fae05a218ebaba9198b148fbd04c12fb52958f4646394',
}
BUS_SHA = '1b67761e014321884d87099df3cc1c4b3d834b40acf83fb58cf6d68b02ead818'
OWNERS = {
    'core_int_deliver.svh': ('S_INT_GATE', 'S_INT_CS'),
    'core_iret.svh': ('S_IRET', 'S_INT_CS_RET', 'S_IRET_SS'),
    'core_seg_ljmp.svh': ('S_LGDT', 'S_SEGLD', 'S_DQUERY', 'S_LJMP', 'S_RETF'),
    'core_tss_priv.svh': ('S_NTRET_RD', 'S_IOPERM', 'S_INT_TSS', 'S_INT_SS', 'S_CG_PRD'),
    'core_tsw.svh': ('S_TSW_READ', 'S_TSW_LDT', 'S_TSW_SEG'),
    'core_rmint.svh': ('S_RMINT_RD', 'S_RMIRET'),
}
STATES = tuple(s for group in OWNERS.values() for s in group)
GPR_STATES = ('S_RETF', 'S_IRET', 'S_RMIRET')
ALIASES = ('retf_commit_w', 'segld_commit_ok', 'dq_commit_ok', 'iret_cs_commit',
           'iret_ss_commit', 'str_store_walk_fault_now', 'tlbp_walk_fault_now')


def once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('missing/ambiguous source fragment: '+old[:100])
    return source.replace(old, new)


def arm(source, state, indent=8):
    """A pinned top-level state arm, stopping before the next peer/default."""
    pattern = r'^'+' '*indent+re.escape(state)+r':.*?(?=^'+' '*indent+r'(?:S_\w+:|default:|endcase)|\Z)'
    rows = re.findall(pattern, source, re.M | re.S)
    if len(rows) != 1:
        raise ValueError('ambiguous state arm: '+state)
    return rows[0]


def assignment(source, name):
    rows = re.findall(r'^  assign '+name+r'\s*=.*?;', source, re.M | re.S)
    if len(rows) != 1:
        raise ValueError('ambiguous assignment: '+name)
    return rows[0]


def split_walk(block, fsm):
    """Distribute the original guard over four arms, keeping bodies verbatim."""
    outer = '          if (mem_ack) begin\n' if fsm else '    if (state==S_WALK && mem_ack) begin\n'
    block = once(block, outer, '' if fsm else '    if (state==S_WALK) begin\n')
    indent = '              ' if fsm else '        '
    for phase, ack in (("3'd0", 'mem_read_ack'), ("3'd1", 'mem_ack'),
                       ("3'd2", 'mem_read_ack'), ('default', 'mem_ack')):
        old = indent+phase+': begin'
        block = once(block, old, indent+phase+': if ('+ack+') begin')
    if fsm:
        block = once(block, '            endcase\n          end\n        end',
                     '            endcase\n        end')
    return block


def audit_bus(bus):
    if hashlib.sha256(bus.encode()).hexdigest() != BUS_SHA:
        raise ValueError('bus source drift')
    start = bus.index('  // Bus request generation (single combinational driver).')
    # The second passive reference driver is not an authority on real pins.
    actual = bus[start:bus.index('    mem_addr_pre = bd_addr;', start)]
    assert "bd_req =1'b0; bd_we =1'b0;" in actual
    for state in STATES:
        body = re.sub(r'//[^\n]*', '', arm(actual, state, 6))
        writes = re.findall(r'\bbd_we\s*=\s*([^;]+);', body)
        assert all(w.strip() == "1'b0" for w in writes), (state, writes)
    walk = arm(actual, 'S_WALK', 6)
    assert re.findall(r'bd_we\s*=\s*([^;]+);', walk) == ["1'b1", "1'b1"]
    assert "3'd0: bd_addr = walk_pde_addr;" in walk
    assert "3'd2: bd_addr = walk_pte_addr;" in walk
    assert "3'd1: begin bd_we =1'b1;" in walk and "default: begin bd_we =1'b1;" in walk
    # All post-stage cancellation/translation overrides leave direction alone.
    tail = bus[bus.index('    mem_addr_pre = bd_addr;', start):]
    tail = tail[:tail.index('\n  end')]
    assert not re.search(r'\bbd_we\s*=', re.sub(r'//[^\n]*', '', tail))
    return dict(read_states=list(STATES), walk_read_phases=[0, 2],
                walk_write_phases=[1, 3, 4, 5, 6, 7], bus_sha256=BUS_SHA)


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('system-read predecessor drift/reapplication: '+name)
    states = OWNERS.get(name, GPR_STATES if name == 'core_gpr_wb.svh' else ())
    for state in states:
        old = arm(source, state)
        assert len(re.findall(r'\bmem_ack\b', old)) == 1, state
        source = once(source, old, re.sub(r'\bmem_ack\b', 'mem_read_ack', old))
    if name == 'core_walk.svh':
        source = split_walk(source, True)
    if name == 'core.sv':
        for alias in ALIASES:
            old = assignment(source, alias)
            assert old.count('mem_ack') == 1
            source = once(source, old, old.replace('mem_ack', 'mem_read_ack'))
        source = once(source, '((state == S_IRET) && mem_ack && (int_step == 4\'d8)',
                      '((state == S_IRET) && mem_read_ack && (int_step == 4\'d8)')
        start = source.index('    if (state==S_WALK && mem_ack) begin')
        stop = source.index('\n  // TLB CR3 flush', start)
        old = source[start:stop]
        source = once(source, old, split_walk(old, False))
        witness = '''`ifndef SYNTHESIS
  // Direction is independently established by core_bus_driver's state arms.
  // No STEP/forced state or synthetic ACK is used by this witness.
  always_ff @(posedge clk) if (rst_n) begin
    if ((state inside {READ_STATES}) ||
        ((state == S_WALK) && ((walk_step == 3'd0) || (walk_step == 3'd2)))) begin
      assert (!mem_we && (mem_read_ack === mem_ack))
        else $fatal(1,"SYSTEM-READ-ACK: owner/fragment completion changed");
      if ($test$plusargs("ven_system_read_ack_witness") &&
          fsm_case_enabled && mem_read_ack)
        $display("[SYSTEM-READ-ACK] state=%s walk=%0d pc=%08x",
                 state.name(), walk_step, q_pc);
    end
  end
`endif
'''.replace('READ_STATES', ', '.join(STATES))
        source = once(source, '  assign mem_we    = bd_we;\n', '  assign mem_we    = bd_we;\n'+witness)
    assert hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]
    return source
