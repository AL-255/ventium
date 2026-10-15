"""Regrade two short cold CRC controls; no valid-score or suite claim."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('audit_v_carry_payload_coremark.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'c674a2804c03d6bf97724a3eff620fffea4cdd253b38aca0a12a9adda0d23103'
for old, new in (
    ("root = soc / 'coremark'", "root = soc / 'coremark-r1'"),
    ("parent = scratch / 'ventium-fp-exec-cut.MNkzxfBO/soc'",
     "parent = scratch / 'ventium-fprem-sequence.iSZ9BAj4/branch-address-soc-r1'"),
    ("native['affinity'] == [11]", "native['affinity'] == [12]"),
    ("for p in (Path(__file__),root/'started.json'", "for p in (original,Path(__file__),root/'started.json'"),
    ("assert start['model'] == load(soc/'build-closed.json')['binary_sha256']",
     "assert start['model'] == load(soc/'build-closed.json')['binary_sha256'] == '7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68'")):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
assert text.count("parent/'coremark/") == 4
text = text.replace("parent/'coremark/", "parent/'coremark-r1/")
exec(compile(text, str(Path(__file__)), 'exec'), globals())
