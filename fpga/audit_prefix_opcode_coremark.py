"""Regrade both short CoreMark CRC controls; never report a duration-valid score."""
import hashlib
from pathlib import Path

original=Path(__file__).with_name('audit_v_carry_payload_coremark.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='c674a2804c03d6bf97724a3eff620fffea4cdd253b38aca0a12a9adda0d23103'
for before,after in (
    ("parent = scratch / 'ventium-fp-exec-cut.MNkzxfBO/soc'","parent = scratch / 'ventium-data-size.v2HaTO2X/prefix-payload-soc-r1'"),
    ("native['affinity'] == [11]","native['affinity'] == [12]"),
    ("for p in (Path(__file__),root/'started.json'","for p in (original,Path(__file__),root/'started.json'"),
    ("assert start['model'] == load(soc/'build-closed.json')['binary_sha256']","assert start['model'] == load(soc/'build-closed.json')['binary_sha256'] == '977e63611f3addef40bdf60ccab402d949e82416c715a6551859a86d6451517d'")):
    assert text.count(before)==1,before
    text=text.replace(before,after)
exec(compile(text,str(__file__),'exec'),globals())
