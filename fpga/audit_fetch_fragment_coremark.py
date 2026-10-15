"""Regrade both source-matched short CRC controls, not a CoreMark score."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('audit_v_carry_payload_coremark.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'c674a2804c03d6bf97724a3eff620fffea4cdd253b38aca0a12a9adda0d23103'
for old, new in (
    ("root = soc / 'coremark'", "root = soc / 'coremark-r2'"),
    ("parent = scratch / 'ventium-fp-exec-cut.MNkzxfBO/soc'",
     "parent = scratch / 'ventium-data-size.v2HaTO2X/prefix-payload-soc-r1'"),
    ("native['affinity'] == [11]", "native['affinity'] == [12]"),
    ("for p in (Path(__file__),root/'started.json'", "for p in (original,Path(__file__),root/'started.json'"),
    ("assert start['model'] == load(soc/'build-closed.json')['binary_sha256']",
     "assert start['model'] == load(soc/'build-closed.json')['binary_sha256'] == 'a97035b6138624e3ccd89c7ce0eabac8d069e3957e71e430144aae770629d06d'")):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
exec(compile(text, str(__file__), 'exec'), globals())
