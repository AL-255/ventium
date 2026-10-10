"""Compose reviewed arithmetic and FST repairs without replacing newer RTL.

Pure source transformation for a separately pinned tree. Preserve the numeric
SRT-floor fix and every unrelated performance hunk. This is not qualification
of unmasked numerical exceptions, legacy arithmetic C1 or the standard suite.
"""
import prepare_current_round_c1 as arithmetic
import prepare_fst_register as register
import prepare_fst_memory_c1 as memory

FILES = tuple(sorted(set(arithmetic.FILES) | {arithmetic.CORE} |
                     set(register.TRANSFORMS) | set(memory.TRANSFORMS)))


def transform(sources):
    if set(sources) != set(FILES):
        raise ValueError('FP bundle requires exactly its seven reviewed source files')
    out = dict(sources)
    out.update(arithmetic.transform({name: out[name]
        for name in (*arithmetic.FILES, arithmetic.CORE)}))
    for stage in (register, memory):
        # Materialize the whole stage before publishing any result to the next.
        out.update({name: fn(out[name]) for name, fn in stage.TRANSFORMS.items()})
    if any(out[name] == sources[name] for name in FILES):
        raise ValueError('missing FP bundle source delta')
    return out
