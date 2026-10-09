#!/usr/bin/env python3
"""Private platform-L2 capacity experiment; P5 L1 geometry is unchanged."""
import argparse
import hashlib
import json
from pathlib import Path


def repair_lru_lookup(text, write_owner=True, forward=True):
    before = '\t\t\t\t\t\tread_addr     <= CPU_ADDR[ADDRBITS+1:1];'
    if text.count(before) != 1:
        raise ValueError('missing/ambiguous LRU admission anchor')
    text = text.replace(before, before + '''
                        // READONE may irrevocably select a streaming victim.
                        // Put THIS request's set on the existing asynchronous
                        // LRU RAM read port at admission, alongside read_addr.
                        // Waiting until READONE selects from the previous set.
                        LRU_addr <= CPU_ADDR[LINEMASKMSB+1:LINEMASKLSB+1];''')
    if write_owner:
        anchors = {
            'reg    [LINE_BITS-1:0]          LRU_addr;':
                'reg    [LINE_BITS-1:0]          LRU_addr;\n'
                '// Keep the registered rank data and its write set together.\n'
                '// A new request may change the read set before this write lands.\n'
                'reg    [LINE_BITS-1:0]          LRU_wraddr;',
            '\t\t// LRU update after read\n':
                '\t\t// LRU update after read\n\t\tLRU_wraddr <= LRU_addr;\n',
            '\t\t\t\t\tLRU_addr        <= update_tag_addr;':
                '\t\t\t\t\tLRU_addr        <= update_tag_addr;\n'
                '\t\t\t\t\tLRU_wraddr      <= update_tag_addr;',
            '.wraddress(LRU_addr),': '.wraddress(LRU_wraddr),',
        }
        for before, after in anchors.items():
            if text.count(before) != 1:
                raise ValueError('missing/ambiguous LRU write owner anchor: ' + before)
            text = text.replace(before, after)
        if forward:
            # READONE can coincide with the previous hit's registered write.
            # Read the newest ranks without stalling or relying on the RAM's
            # implementation-specific read-during-write result.
            before = 'reg    [LINE_BITS-1:0]          LRU_wraddr;'
            assert text.count(before) == 1
            if text.count('LRU_out[i]') != 7:
                raise ValueError('missing/ambiguous LRU rank consumers')
            text = text.replace('LRU_out[i]', 'LRU_rank[i]')
            text = text.replace('.q(LRU_rank[i])', '.q(LRU_out[i])')
            text = text.replace(before, before + '''
wire [ASSO_BITS-1:0] LRU_rank[0:ASSOCIATIVITY-1];
wire LRU_write_through = LRU_we && (LRU_wraddr == LRU_addr);
genvar lru_rank_way;
generate for (lru_rank_way = 0; lru_rank_way < ASSOCIATIVITY; lru_rank_way = lru_rank_way + 1) begin
    assign LRU_rank[lru_rank_way] = LRU_write_through ? LRU_in[lru_rank_way] : LRU_out[lru_rank_way];
end endgenerate''')
    return text


def transform(text):
    anchors = {
        'module l2_cache #(parameter ADDRBITS = 24)':
            'module l2_cache #(parameter ADDRBITS = 24, parameter CACHE_SETS = 128)',
        'localparam LINES         = 128;': '''// Keep the four-way / 64-byte-line platform cache and its RAM ports.
// Only the per-way RAM depth changes; the core P5 L1s are untouched.
localparam LINES         = CACHE_SETS;
initial begin
    if ((CACHE_SETS < 128) || (CACHE_SETS > 1024) ||
        ((CACHE_SETS & (CACHE_SETS - 1)) != 0))
        $fatal(1, "platform L2 requires 128/256/512/1024 power-of-two sets");
end''',
        '// the state needed is one bit per set rather than a queue of addresses. LINES is 128,\n'
        '// so this is a 128-bit register and a 128-entry priority encoder.':
            '// The pending bitmap remains one bit per set, sized by LINES. Larger\n'
            '// configurations require separate physical qualification of this encoder.',
        '// lowest pending set index (128-wide priority encoder)':
            '// lowest pending set index (LINES-wide priority encoder)',
    }
    for before, after in anchors.items():
        if text.count(before) != 1:
            raise ValueError('missing/ambiguous L2 capacity anchor: ' + before)
        text = text.replace(before, after)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    original = args.source.read_bytes()
    changed = transform(original.decode())
    args.out.mkdir()
    (args.out/'l2_cache.v').write_text(changed)
    (args.out/'inputs.json').write_text(json.dumps(dict(
        source=str(args.source.resolve()), source_sha256=hashlib.sha256(original).hexdigest(),
        candidate_sha256=hashlib.sha256(changed.encode()).hexdigest(),
        core_l1_changed=False, production_selected=False, physical_qualified=False), indent=2)+'\n')


if __name__ == '__main__':
    main()
