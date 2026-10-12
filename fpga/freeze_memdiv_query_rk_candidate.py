"""Freeze the source-matched query selector without changing the RK profile."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('freeze_fetch_probe_rk_candidate.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '7ed7ea44ddd05cf91f9cedc43e4a28176f319ab5bfa6737c854c05ae4cc58406'
for before, after, count in (
    ('checked early fetch-probe payload', 'checked resident-query payload', 1),
    ('import build_fetch_probe_soc as native', 'import build_memdiv_query_soc as native', 1),
    ('09805c9c641b7b741fdf70c4547f0d4a8adbfa448d47be31c27a176d4d02c341',
     '0859a74cc3539b1644c90813029c02e0545d1b002184e33cd94f6ecbe6ed68cb', 1),
    ('b598f07768e3e04483a3c11dca8d97ff35acd134d2b3f94a54fb56d3e1f21b71',
     'eebeb872631af564d340958bfe0c3576ab7ac9c56fb18b7f57af2b2a9ea50987', 1),
    ("old['variant'] == 'load_read_ack_timing'", "old['variant'] == 'memdiv_capture_timing'", 1),
    ("variant='fetch_probe_payload_timing'", "variant='memdiv_query_payload_timing'", 1),
    ('Early fetch-probe payload only', 'Resident-query owner selection only', 1),
    ('for p in (Path(__file__), Path(previous.__file__)',
     'for p in (Path(__file__), original, Path(previous.__file__)', 1),
):
    assert text.count(before) == count, before
    text = text.replace(before, after)
exec(compile(text, str(original), 'exec'), globals())
