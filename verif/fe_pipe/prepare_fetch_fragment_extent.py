"""Remove the already page-clipped boundary-fetch size from fragment crossing.

Private derivative of the retained prefix-payload parent, not the rejected
opcode-selector or response-kind candidates. No request/size/state changes.
"""
import hashlib

FILE = 'rtl/core/core.sv'
PARENT = '238cd9f713cc6e84a6881cb5e06b8ff341a90cb428be8882b1f1b2d974491ac4'
BUS_PARENT = '2e592948d1ae2a99babc970a5c573a1de42fbf011f62e8b34d473c4b216ae08c'
OLD = '''  assign fx_rd_end = {1'b0, cur_lin_nat[11:0]} + {9'd0, cur_size};
  logic        fx_cross;
  assign fx_cross = bd_we
                 ? ({1'b0, cur_lin_nat[11:0]} + {10'd0, fx_wr_hi} > 13'hFFF)
                 : (fx_rd_end > 13'h1000);'''
NEW = '''  // Boundary-fetch beats are already clipped to the remaining page bytes
  // by sfetch_demand_size and never write. Their generic fragment crossing
  // is therefore false, including idle/zero-size beats. Use the pre-fetch
  // size tap for every other state; preserve the actual bus size unchanged.
  assign fx_rd_end = {1'b0, cur_lin_nat[11:0]} + {9'd0, cur_data_size};
  logic        fx_cross;
  assign fx_cross = !((state == S_FETCH) && sfetch_boundary) &&
                   (bd_we
                 ? ({1'b0, cur_lin_nat[11:0]} + {10'd0, fx_wr_hi} > 13'hFFF)
                 : (fx_rd_end > 13'h1000));
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n)
    assert (fx_cross === (bd_we
              ? ({1'b0, cur_lin_nat[11:0]} + {10'd0, fx_wr_hi} > 13'hFFF)
              : ({1'b0, cur_lin_nat[11:0]} + {9'd0, cur_size} > 13'h1000)))
      else $fatal(1, "FETCH-FRAGMENT-EXTENT: changed page crossing");
`endif'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('fetch fragment parent drift/reapplication')
    if source.count(OLD) != 1 or source.count('fx_rd_end') != 3:
        raise ValueError('fragment arithmetic consumer drift')
    if source.count('    cur_data_size = cur_size;\n') != 1:
        raise ValueError('missing pre-fetch size tap')
    return source.replace(OLD, NEW)


def fetch_size(source):
    begin = source.index('  always_comb begin\n    sfetch_demand_size = 3\'d0;')
    end = source.index('\n  end\n', begin) + len('\n  end\n')
    return source[begin:end]


def fetch_bus(source):
    if hashlib.sha256(source.encode()).hexdigest() != BUS_PARENT:
        raise ValueError('fetch bus producer drift')
    begin = source.index('      S_FETCH: begin\n')
    end = source.index('      S_PF: ', begin)
    arm = source[begin:end]
    if 'bd_we' in arm or source.count("bd_req =1'b0; bd_we =1'b0;") != 1:
        raise ValueError('fetch is no longer unconditionally read-only')
    return arm


def symbolic(mutant=None):
    # All binary offsets, counts, states and control combinations. No demand-
    # decoder validity, fetch_word range or reachable-state assumption needed.
    out = '''(set-logic QF_BV)
(declare-const fetch Bool)
(declare-const boundary Bool)
(declare-const allowed Bool)
(declare-const interior Bool)
(declare-const we Bool)
(declare-const off (_ BitVec 12))
(declare-const need (_ BitVec 5))
(declare-const valid (_ BitVec 5))
(declare-const width (_ BitVec 4))
(declare-const hi (_ BitVec 2))
(define-fun req () Bool (and fetch boundary allowed (bvult valid need)))
(define-fun remain () (_ BitVec 13) (bvsub (_ bv4096 13) ((_ zero_extend 1) off)))
(define-fun diff () (_ BitVec 5) (bvsub need valid))
(define-fun cap () (_ BitVec 3)
 (ite (or interior (bvuge diff (_ bv4 5))) (_ bv4 3) ((_ extract 2 0) diff)))
(define-fun size () (_ BitVec 3) (ite req
 (ite (and (bvugt off (_ bv4092 12)) (bvugt cap ((_ extract 2 0) remain)))
 ((_ extract 2 0) remain) cap) (_ bv0 3)))
(define-fun oldsize () (_ BitVec 4)
 (ite (and fetch boundary) ((_ zero_extend 1) size) width))
(define-fun write () Bool (and (not fetch) we))
(define-fun wcross () Bool
 (bvugt (bvadd ((_ zero_extend 1) off) ((_ zero_extend 11) hi)) (_ bv4095 13)))
(define-fun old () Bool (ite write wcross
 (bvugt (bvadd ((_ zero_extend 1) off) ((_ zero_extend 9) oldsize)) (_ bv4096 13))))
(define-fun new () Bool (and (not (and fetch boundary)) (ite write wcross
 (bvugt (bvadd ((_ zero_extend 1) off) ((_ zero_extend 9) width)) (_ bv4096 13)))))
(assert (not (= old new)))
(check-sat)
'''
    if mutant == 'no-exclusion':
        out = out.replace('(and (not (and fetch boundary)) (ite write wcross',
                          '(and true (ite write wcross')
    elif mutant == 'fixed-width':
        out = out.replace('((_ zero_extend 9) width)', '(_ bv4 13)')
    elif mutant == 'lost-page-clamp':
        out = out.replace('(bvugt off (_ bv4092 12))', 'false')
    elif mutant is not None:
        raise ValueError(mutant)
    return out
