"""Check the actual request cofactor with every overlap/AGI/reference corpus.

Reuse the original native checks unchanged. Fix only the collector's mistaken
selection of comparator stdout, and add the producer-specific microbenchmarks.
The original failed collection and independently audited logs remain intact.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('run_next_pair_probe.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'a5006104c66a3011683803b25100445eb85237ab562182e13d490221e5a4c643'


def change(old,new):
    global text
    assert text.count(old) == 1,old
    text = text.replace(old,new)


change("MODEL = '7ce9cfa450ee674e59fc296503153ac9c9fd24b03f52f9175e04bce5eb482f32'",
       "MODEL = '5b8c134e4e3d4c6856025ce37d0abdf1cd3bfc424baaae837fa393130d3a541a'")
change("    commands = [(label,", """    plan += [
        ('agi','verif/l1/run_prime_noack_system.py',['--kind','agi'],270),
        ('ref','verif/l1/run_prime_noack_system.py',['--kind','ref'],270),
        ('agi-store','verif/l1/run_next_pair_agi_store.py',[],150),
    ]
    commands = [(label,""")
change("                text = p.read_text(); matches = PATTERN.findall(text)",
       """                if not re.fullmatch(r'candidate-(?:lat|l)\\d+-cycle(?:-func)?\\.stdout',p.name):
                    continue
                text = p.read_text(); matches = PATTERN.findall(text)""")
change("    pins = {str(Path(__file__).resolve()):sha(__file__)}", """    pins = {str(Path(__file__).resolve()):sha(__file__)}
    inherited = Path(__file__).with_name('run_next_pair_probe.py')
    pins[str(inherited)] = sha(inherited)""")
change("hardware_behavior_changed=False)","hardware_behavior_changed=False,request_equivalence_assertion=True)")
change("        assert result['probe_runs'] > 0", "        assert result['probe_runs'] == 4240")
change("('agi','ref','prime','intent','request','accept'))",
       "('agi','ref','prime','intent','request','accept','shape_only'))")

exec(compile(text,str(Path(__file__)),'exec'),globals())
