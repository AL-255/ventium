"""Private no-memory prime cofactor; never weaken architectural coherence.

Only AGI/reference hint commits change. Their live arm excludes a current
integer memory owner, while their offer excludes an active fragment engine.
The audited integration's own-store snoop ports must therefore be inactive.
Keep sticky prior poison and external invalidation; leave the actual I-cache,
REP recovery sequencer, architectural commit and public ports untouched.
"""
import hashlib
import re

from prepare_mc_local_commit import assignment

PARENTS = {
    'rtl/core/core.sv': '3d8aebbdf338a63ab86bb58a6fab2ebb43f0f280bdbd3626ff4710941a5983c6',
    'rtl/core/core_mem_chain.svh': 'b1e94ba311c54860a56d872aadaff75771c6eff795bb112f2bc0476b3ec29788',
    'rtl/core/core_agi_resident_prime.svh': '818dbc33998087af6849f5ca3177733f7ab05de38e670b9a6e470e2fe275d092',
    'rtl/core/core_ref_operand_prime.svh': 'e4a31829ed91c44ccfdb5e96350c95f3953c8c6d746a97b3b25c094b5be35399',
    'rtl/core/core_bus_driver.svh': '2e592948d1ae2a99babc970a5c573a1de42fbf011f62e8b34d473c4b216ae08c',
    'rtl/mem/ventium_l1_axi.sv': '8be78961aaede131862f1aea5bd6cc49b0873d29f5849a5c509aa655e803b7d9',
    'rtl/mem/icache.sv': 'daa92a4891a365965530460f230b6a7cf88f358f5d690be2586490d19459164f',
    'rtl/ventium_top.sv': '0e324c5df71112df2f583218df305946fd99904847dd72b5cf7ae78007415b91',
}
CHANGES = ['rtl/core/core_agi_resident_prime.svh', 'rtl/core/core_ref_operand_prime.svh']


def audit(inputs):
    if set(inputs) != set(PARENTS):
        raise ValueError('need the complete prime/coherence source contract')
    for name, digest in PARENTS.items():
        if hashlib.sha256(inputs[name].encode()).hexdigest() != digest:
            raise ValueError('prime/coherence source drift: '+name)
    core = inputs['rtl/core/core.sv']
    live = assignment(core, 'pipe_prime_live_arm')
    for term in ('(state == S_PIPE)', '!pipe_mem_active_q', '!fp_issue_block',
                 '(pipe_agi || fp_sys_bail)'):
        assert term in live
    for name in ('pipe_new_load_req', 'pipe_new_store_req'):
        eq = re.search(r'    '+name+r'\s*=.*?;', core, re.S).group()
        assert '!pipe_agi' in eq and '!fp_sys_bail' in eq
    assert 'pipe_load_req  = pipe_mem_active_q ? ((state==S_PIPE) && !pipe_mem_we_q)' in core
    assert 'pipe_store_req = pipe_mem_active_q ? ((state==S_PIPE) &&  pipe_mem_we_q)' in core
    assert 'cur_is_w_nat = pipe_store_req;' in core
    assert 'assign fx_eng   = fx_act && !fx_walk_hold && !fx_abort_q;' in core
    assert 'assign mem_we    = bd_we;' in core
    assert 'assign mem_store_pair_req = pipe_store_pair_offer && mem_store_pair_ready;' in core
    assert 'assign pipe_store_pair_offer = (pipe_store_req\n`ifdef VEN_P54_LOAD_STORE_PAIR\n       || pipe_load_req' in core
    boundary = assignment(inputs['rtl/core/core_mem_chain.svh'], 'mc_boundary_ok')
    assert '!fx_act' in boundary and '!exec_flush_all && !ic_snoop_valid' in boundary
    # S_PIPE's only write arm is a current store; the post-case tail does not
    # introduce writes. No pending write-queue drain drives these CPU ports.
    bus = inputs['rtl/core/core_bus_driver.svh']
    start = bus.index('      S_PIPE:  begin')
    packet = bus[start:bus.index('      S_LOAD: begin', start)]
    assert packet.count("bd_we=1'b1;") == 1
    assert "else if (pipe_store_req) begin\n          bd_req=1'b1; bd_we=1'b1;" in packet
    assert not re.search(r'bd_we\s*=', bus[bus.rindex('endcase'):])
    seam = inputs['rtl/mem/ventium_l1_axi.sv']
    assert 'assign icache_snoop_valid1 = core_we;' in seam
    assert 'assign smc_xline = core_we &&' in seam
    assert 'assign icache_snoop_valid2 = smc_xline || core_store_pair_req;' in seam
    top = inputs['rtl/ventium_top.sv']
    for wiring in ('.core_we   (core_mem_we)', '.core_store_pair_req(l1axi_en && core_store_pair_req)',
                   '.ic_snoop_valid2(ic_snoop_v2)', '.icache_snoop_valid2(ic_snoop_v2)'):
        assert wiring in top
    # The own-cache and bypass hit terms are all qualified by these valids.
    cache = inputs['rtl/mem/icache.sv']
    for n in (1, 2):
        assert f'if (snoop_inv_valid{n} && ic_val[' in cache
        assert f'if (icbp_v[i] && icsnp_v{n} &&' in core
    assert 'rep_stos_cont_hold = rep_stos_cont_ready_noevent && !fp_irq_divert;' in core
    assert 'rep_stos_cont_would_take_noevent = rep_stos_cont_ready_noevent &&' in core
    assert 'rep_stos_cont_take = rep_stos_cont_would_take_noevent && !fp_irq_divert;' in core
    assert 'rep_stos_cont_redecode_q || rep_stos_cont_hold;' in core


def edits(source, kind):
    old = assignment(source, kind+'_prime_commit')
    assert old.startswith('  assign '+kind+'_prime_commit = '+kind+'_prime_offer && pipe_prime_live_arm &&')
    new = old.replace('!rep_stos_cont_recovery_need',
        '!(rep_stos_cont_redecode_q || (rep_stos_cont_q &&\n'
        '          (rep_stos_cont_poison_q || exec_flush_all || rep_stos_cont_snoop_now)))')
    assert new.count('!rep_stos_cont_take') == 1
    new = re.sub(r'\s*&&\s*!rep_stos_cont_take', '', new)
    if kind == 'agi':
        assert new.count('!icsnp_v1 && !icsnp_v2 && !ic_snoop_valid2') == 1
        new = re.sub(r'\s*&&\s*!icsnp_v1 && !icsnp_v2 && !ic_snoop_valid2', '', new)
    witness = kind+'_prime_before_coherence_cut'
    new = '''  // Only this no-memory hint cofactor omits live OWN-store feedback.
  // The shared live arm excludes both new/held U requests; the offer excludes
  // fragments. The integrated CPU-store snoop ports are consequently idle.
  // Sticky prior poison, external invalidation and all execution guards stay.
  // REP take implies REP hold, already excluded by the live arm.
'''+new+'''`ifndef SYNTHESIS
  logic '''+witness+';\n'+old.replace(kind+'_prime_commit', witness)+'''
  always_ff @(posedge clk) if (rst_n) begin
    assert ('''+kind+'_prime_commit === '+witness+''')
      else $fatal(1,"PRIME-COHERENCE: changed '''+kind+''' hint commit");
    if ('''+kind+'''_prime_offer && pipe_prime_live_arm) begin
      assert (!pipe_load_req && !pipe_store_req && !mem_we &&
              !icsnp_v1 && !icsnp_v2 && !ic_snoop_valid2 &&
              !ic_snp1_hit && !ic_snp2_hit && !rep_stos_cont_icbp_snoop_hit &&
              !rep_stos_cont_take)
        else $fatal(1,"PRIME-COHERENCE: no-memory hint acquired a live own snoop");
    end
  end
`endif
'''
    return old, new


def transform(inputs):
    audit(inputs)
    result = dict(inputs)
    for path, kind in zip(CHANGES, ('agi', 'ref')):
        old, new = edits(inputs[path], kind)
        assert result[path].count(old) == 1
        result[path] = result[path].replace(old, new)
    return result
