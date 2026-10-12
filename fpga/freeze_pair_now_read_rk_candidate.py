"""Freeze the source-matched immediate-read ACK cut with the original RK profile."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('freeze_fetch_probe_rk_candidate.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '7ed7ea44ddd05cf91f9cedc43e4a28176f319ab5bfa6737c854c05ae4cc58406'
for before, after, count in (
    ('checked early fetch-probe payload', 'checked immediate paired-read ACK', 1),
    ('import build_fetch_probe_soc as native', 'import build_pair_now_read_soc as native', 1),
    ('09805c9c641b7b741fdf70c4547f0d4a8adbfa448d47be31c27a176d4d02c341',
     'a15a7ec363d5ce5cd894a9d8e7f3a238cf0c57dc2086febe35c5587e787ef4be', 1),
    ('b598f07768e3e04483a3c11dca8d97ff35acd134d2b3f94a54fb56d3e1f21b71',
     '45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5', 1),
    ("old['variant'] == 'load_read_ack_timing'", "old['variant'] == 'memdiv_query_payload_timing'", 1),
    ("variant='fetch_probe_payload_timing'", "variant='pair_now_read_ack_timing'", 1),
    ('Early fetch-probe payload only', 'Immediate paired-read completion selector only', 1),
    ('for p in (Path(__file__), Path(previous.__file__)',
     'for p in (Path(__file__), original, Path(previous.__file__)', 1),
):
    assert text.count(before) == count, before
    text = text.replace(before, after)
exec(compile(text, str(original), 'exec'), globals())
