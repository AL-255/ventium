"""Independently regrade the composed model's two short cold controls."""
from pathlib import Path

previous_driver = Path(__file__).with_name('audit_pair_next_disjoint_coremark.py')
text = previous_driver.read_text()
for old, new in (
    ('b542e94d172defa3528ef0e2faf80a636a5072aa99e63d6ab6ff56335acba2a2',
     '5a50175cd6daec6079b2d2cd94fd4857d09d09d99a2b41ea5ad4a52c8d2570d9'),
    ('"original,original_driver,Path(__file__),root/\'started.json\'"',
     '"original,original_driver,previous_driver,Path(__file__),root/\'started.json\'"'),
):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
exec(compile(text, str(__file__), 'exec'), globals())
