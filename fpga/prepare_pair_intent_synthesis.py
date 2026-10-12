"""Prepare a bounded measurement of checked cache-port intent arbitration.

Reuse the closed next-pair controller generator, preserving the native resource
guard and original clocks. Four hardware files plus the simulation-only probe
are transferred into the PC/FPGA image; only four differ in the directed core.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('prepare_next_pair_cofactor_synthesis.py')
text = original.read_text()
EXPECTED_TEMPLATE = '597eeec817d17ba0b559a9bdbecbe5c7d4c1f8c837e7bac451b9b6acbe05bd4b'
assert hashlib.sha256(text.encode()).hexdigest() == EXPECTED_TEMPLATE
end_doc = text.index('"""', 3) + 3
text = repr(__doc__) + text[end_doc:]


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import build_next_pair_cofactor_soc as native',
       'import build_pair_intent_soc as native')
# Replace candidate names only. The source-parent templates and resource
# lifecycle remain pinned to the same BACKING-PAYLOAD experiment.
text = text.replace('next-pair-cofactor-', 'pair-intent-')
text = text.replace('next_pair_cofactor_timing', 'pair_intent_timing')
change("'changes='+repr(native.CHANGES)",
       "'changes='+repr(sorted(native.recipe.PARENTS))")
change("        guarded(text,original[name])", """        if phase == 'synthesis':
            text = replace(text, "prepared['changes']==changes",
                           "prepared['changes']=="+repr(native.CHANGES))
        guarded(text,original[name])""")
change('source-matched RAW next-read/pair cofactor',
       'source-matched checked cache-port intent arbiter')
change('Expose the request-equivalent RAW next-read/U-read-V-store exclusion before late hint qualification. Preserve AGI hints, cache arbitration, all request guards, UV+fast and full P5 caches.',
       'Give checked store intent cache-port priority before speculative next-read qualification. Preserve real request/ACK/backing-credit guards, UV+fast, full P5 caches and architectural cycles. No timing exceptions added.')
change('Audit one tested RTL delta', 'Audit four tested hardware files and one simulation-only probe')
change("'prepare_next_pair_cofactor_synthesis.py','prepare_fragment_exact_timing.py',\n                 'prepare_payload_current_synthesis.py','build_next_pair_cofactor_soc.py'",
       "'prepare_pair_intent_synthesis.py','prepare_next_pair_cofactor_synthesis.py',\n                 'prepare_fragment_exact_timing.py','prepare_payload_current_synthesis.py',\n                 'build_pair_intent_soc.py','build_next_pair_cofactor_soc.py'")
change('Prepared bounded next-pair synthesis/timing controllers; nothing launched.',
       'Prepared bounded pair-intent synthesis/timing controllers; nothing launched.')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
