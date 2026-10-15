"""Independently regrade both short payload-mux cold controls; no score claim."""
from pathlib import Path

previous_driver = Path(__file__).with_name('audit_pair_next_disjoint_coremark.py')
text = previous_driver.read_text()
for old, new in (
    ('b542e94d172defa3528ef0e2faf80a636a5072aa99e63d6ab6ff56335acba2a2',
     '917b5e3a729902f19410fdaa3b43ac9a8827612109013f04388f03556c95dd91'),
    ('"original,original_driver,Path(__file__),root/\'started.json\'"',
     '"original,original_driver,previous_driver,Path(__file__),root/\'started.json\'"'),
):
    assert text.count(old) == 1, old
    text = text.replace(old, new, 1)
exec(compile(text, str(__file__), 'exec'), globals())
