"""Split the two tag ways into independent distributed memories.

Private source-exact proposal: no latency, port, state-machine, validity,
replacement, permission or feature changes. The previous flattened memory has
16 asynchronous read ports under the full FPGA profile and maps to registers.
Each explicit way bank has eight reads and its own qualified fill write.
"""
import hashlib

PARENT = '9b888b991ffc38034899f3c9e98bc1e04f9d37268aaba57cf13e1c0495428311'
OLD_DECL = '''  // One unpacked address dimension is required for Vivado RAM inference.
  // Concatenate the original set and way: storage remains 128 * 2 * TAGW.
  (* ram_style = "distributed" *) logic [TAGW-1:0] dc_tag [L1_SETS*2];'''
NEW_DECL = '''  // Keep each way in its own one-dimensional distributed RAM. Flattening
  // set and way puts all 16 parallel reads on one memory and exceeds Vivado's
  // supported port organization. Each bank has eight reads in the full profile.
  // Valid bits still reset separately; payloads and read latency are unchanged.
  (* ram_style = "distributed" *) logic [TAGW-1:0] dc_tag_way0 [L1_SETS];
  (* ram_style = "distributed" *) logic [TAGW-1:0] dc_tag_way1 [L1_SETS];'''
OLD_WRITE = '                  dc_tag[{fset,fway}]<=ftag; dc_lru[fset]<=fway;'
NEW_WRITE = '''                  if (fway) dc_tag_way1[fset] <= ftag;
                  else      dc_tag_way0[fset] <= ftag;
                  dc_lru[fset] <= fway;'''


def replacements():
    rows = [(OLD_DECL, NEW_DECL), (OLD_WRITE, NEW_WRITE)]
    for index in ('store_pair_set', 'pair_set[lane]', 'set_c', 'set_n', 'snp_set'):
        for way in (0, 1):
            rows.append((f"dc_tag[{{{index},1'b{way}}}]", f'dc_tag_way{way}[{index}]'))
    for index, way in (('tag_current_set', 'tag_way'), ('tag_prime_set', 'tag_way'),
                       ('tag_current_next_set', 'next_tag_way'),
                       ('tag_prime_next_set', 'next_tag_way')):
        rows.append((f"dc_tag[{{{index},1'({way})}}]",
                     f'({way} == 0 ? dc_tag_way0[{index}] : dc_tag_way1[{index}])'))
    return rows


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('way-banked tag parent drift')
    changed = source
    for before, after in replacements():
        if changed.count(before) != 1 or after in changed:
            raise ValueError('way-banked tag anchor drift')
        changed = changed.replace(before, after)
    assert 'dc_tag[{' not in changed
    assert reverse(changed) == source
    return changed


def reverse(source):
    for before, after in reversed(replacements()):
        if source.count(after) != 1:
            raise ValueError('way-banked reverse anchor drift')
        source = source.replace(after, before)
    return source


def miter_fixture(source):
    before = 'dut.dc_tag[s*2+w] !== control.dc_tag[s*2+w]'
    after = '(w == 0 ? dut.dc_tag_way0[s] : dut.dc_tag_way1[s]) !== control.dc_tag[s*2+w]'
    if source.count(before) != 1 or after in source:
        raise ValueError('way-banked tag fixture drift')
    changed = source.replace(before, after)
    assert changed.replace(after, before) == source
    return changed
