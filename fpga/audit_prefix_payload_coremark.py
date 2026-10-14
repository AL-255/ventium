"""Regrade short CRC controls against the immediately preceding full-PC model."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('audit_v_carry_payload_coremark.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'c674a2804c03d6bf97724a3eff620fffea4cdd253b38aca0a12a9adda0d23103'
for before, after in (
    ("parent = scratch / 'ventium-fp-exec-cut.MNkzxfBO/soc'",
     "parent = scratch / 'ventium-data-size.v2HaTO2X/fast-segment-soc-r1'"),
    ("native['affinity'] == [11]", "native['affinity'] == [12]"),
    ("for p in (Path(__file__),root/'started.json'", "for p in (original,Path(__file__),root/'started.json'"),
    ("assert start['model'] == load(soc/'build-closed.json')['binary_sha256']",
     "assert start['model'] == load(soc/'build-closed.json')['binary_sha256'] == '5eee4d74d729663ad6af4abaa3f0fdbd5cc59937a36945ca81ff46e33b891ce9'")):
    assert text.count(before) == 1, before
    text = text.replace(before, after)
exec(compile(text, str(Path(__file__)), 'exec'), globals())
