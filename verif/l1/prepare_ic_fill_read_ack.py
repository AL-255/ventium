"""Exact-parent I-fill read-ACK cofactor, without changing request authority.

Both fill arms are reads: S_PF, and S_PIPE with no held owner and no resident
instruction bytes. The latter excludes new data requests via frontend_ready.
mem_read_ack already retains final-fragment suppression and falls back to
mem_ack when VEN_FP_LOAD_EARLY_CMD is absent. This adds no cycle or feature flag.
"""
import hashlib
import re

CORE = '16f45dc7fd6d041d5212b723bcb506a210ef066a9108effb34cbf4781cb87bd3'
START = '    // ---- fill port: the two MUTUALLY-EXCLUSIVE fill arms'
END = '    // ---- LRU touch ports'


def fill_body(source):
    if source.count(START) != 1 or source.count(END) != 1:
        raise ValueError('I-fill extraction boundary drift')
    return source[source.index(START):source.index(END)]


def predicates(body):
    miss = re.findall(r'    ic_pf_miss_fill = (.*?);', body, re.S)
    pf = re.findall(r'    if \((state==S_PF.*?)\) begin', body)
    if len(miss) != 1 or len(pf) != 1:
        raise ValueError('I-fill predicate drift')
    return miss[0], pf[0]


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != CORE:
        raise ValueError('I-fill parent drift/reapplication')
    old = fill_body(source)
    changes = (
        ('&& (!real_bus || mem_ack)', '&& (!real_bus || mem_read_ack)'),
        ('&& !exec_flush_all && mem_ack) begin',
         '&& !exec_flush_all && mem_read_ack) begin'),
    )
    new = old
    for before, after in changes:
        if new.count(before) != 1:
            raise ValueError('I-fill ACK consumer drift')
        new = new.replace(before, after)
    new = new.replace('    // ---- fill port:', '''    // Both consumers below are read-only. Use the existing final-fragment
    // read ACK, avoiding paired-store admission in the I-fill control cone.
    // All request, fault, stall, flush and held-owner guards stay unchanged.
    // ---- fill port:''')
    miss, pf = predicates(old)
    witness = '''`ifndef SYNTHESIS
  // Compare against the original general-ACK fill permit on every clock,
  // including no-response, diversion, flush and held data-owner clocks.
  logic ic_fill_before_read_ack;
  assign ic_fill_before_read_ack = ('''+pf+''') ||
      ('''+miss+''');
  always_ff @(posedge clk) if (rst_n) begin
    assert (ic_fill_en === ic_fill_before_read_ack)
      else $fatal(1, "IC-FILL-READ-ACK: fill timing changed");
    if (ic_fill_en) assert (!mem_we)
      else $fatal(1, "IC-FILL-READ-ACK: fill has a write owner");
  end
`endif

'''
    anchor = '  logic        ic_tch0_en, ic_tch1_en, ic_tch2_en;'
    if source.count(anchor) != 1:
        raise ValueError('I-fill witness insertion drift')
    return source.replace(old, new).replace(anchor, witness+anchor)
