"""Regrade both short controls against the retained parent; no score claim."""
from pathlib import Path

original_driver=Path(__file__).with_name('audit_fetch_fragment_coremark.py')
text=original_driver.read_text()
for old,new in (
    ("root = soc / 'coremark-r2'","root = soc / 'coremark-r1'"),
    ('a97035b6138624e3ccd89c7ce0eabac8d069e3957e71e430144aae770629d06d',
     'b542e94d172defa3528ef0e2faf80a636a5072aa99e63d6ab6ff56335acba2a2'),
    ("original,Path(__file__),root/'started.json'","original,original_driver,Path(__file__),root/'started.json'"),
):
    assert text.count(old)==1,old
    text=text.replace(old,new)
exec(compile(text,str(__file__),'exec'),globals())
