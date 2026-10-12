"""Test the binary read-ACK absorption lemma before changing cache RTL.

This is an abstract combinational analysis, not an extracted-RTL, sequential,
full-core or hardware proof. It deliberately leaves registered ownership and
tag results unconstrained. Native source testing is still required for a fix.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

PARENT = 'a9a1c8c640f2f5781765ca2f27979a664c1914fb14e4b93c348877b39ad29fae'


def problem():
    text = '(set-logic QF_BV)\n'
    flags = ('req we cache golden flush snoop stream early idle fill byp chain '
             'next_req prime prime_extra rd rd_armed current_hit next_hit '
             'window_valid shadow_valid same_window same_shadow no_code '
             'windows shadows extent28 code_eligible early_match byp_match '
             'stream_ack').split()
    for name in flags:
        text += f'(declare-const {name} Bool)\n'

    def term(name, body):
        nonlocal text
        text += f'(define-fun {name} () Bool {body})\n'

    # 'rd' abstracts the entire registered owner/address/code equality. The
    # only assumption on this abstraction is one present in its RTL definition.
    text += '(assert (=> rd rd_armed))\n'
    text += '(assert (not (and idle fill)))\n'
    term('lookup', '(and chain next_req (not early) (not stream) '
         '(or (and req (not we) rd idle) '
         '(and prime (not req) (not rd_armed) (or idle prime_extra))))')
    term('hit', '(ite lookup next_hit current_hit)')
    term('guard', '(and (not flush) (not snoop))')
    term('window_base', '(and windows (not stream) (not early) idle req (not we) '
         'cache (not golden) guard no_code extent28 '
         '(or (and window_valid same_window) (and shadows shadow_valid same_shadow)))')
    term('old_windows', '(and window_base (not lookup) hit)')
    term('new_windows', '(and window_base current_hit)')
    # code_access in actual RTL implies cacheable, !c_we and !golden. Remaining
    # code-line/fill identities are unconstrained, but shared between formulas.
    term('code_base', '(and req (not we) cache (not golden) guard '
         '(not early) (not stream) code_eligible)')
    term('old_code', '(and code_base (not lookup))')
    term('old_owner', '(and rd guard cache)')
    term('other', '(or (and early_match guard) (and byp byp_match))')
    term('old_ack', '(ite stream stream_ack (and req (not we) '
         '(or old_owner old_windows old_code other)))')
    term('new_ack', '(ite stream stream_ack (and req (not we) '
         '(or old_owner new_windows code_base other)))')
    # Mutation controls protect the required dominating owner, cacheability,
    # current-tag residency and invalidation guards in the proposed cofactor.
    term('lost_owner_ack', '(ite stream stream_ack (and req (not we) '
         '(or new_windows code_base other)))')
    term('lost_cache_ack', '(ite stream stream_ack (and req (not we) '
         '(or (and rd guard) new_windows code_base other)))')
    term('lost_residency_ack', '(ite stream stream_ack (and req (not we) '
         '(or old_owner window_base code_base other)))')
    term('lost_flush_ack', '(ite stream stream_ack (and req (not we) '
         '(or (and rd cache (not snoop)) new_windows code_base other)))')
    term('lost_stream_ack', '(and req (not we) '
         '(or old_owner new_windows code_base other))')
    return text


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    source = args.source.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != Path(__file__).stat().st_dev
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert sha(source) == PARENT
    pins = {str(p): sha(p) for p in (source, Path(__file__).resolve())}
    cases = [('equivalence', '(not (= old_ack new_ack))', 'unsat'),
             ('lookup-under-request-implies-owner',
              '(and req lookup (not rd))', 'unsat')]
    for name in ('lost_owner', 'lost_cache', 'lost_residency', 'lost_flush', 'lost_stream'):
        cases.append((name, '(not (= old_ack ' + name + '_ack))', 'sat'))
    root.mkdir()
    rows = []
    for name, assertion, expected in cases:
        query = root / (name + '.smt2')
        query.write_text(problem() + '(assert ' + assertion + ')\n(check-sat)\n' +
                         ('(get-model)\n' if expected == 'sat' else ''))
        run = subprocess.run(['/usr/bin/z3', str(query)], text=True,
                             capture_output=True, timeout=10)
        log = root / (name + '.log')
        log.write_text(run.stdout + run.stderr)
        assert run.returncode == 0 and run.stdout.splitlines()[0] == expected, (name, run)
        rows.append(dict(name=name, answer=expected, native_exit=run.returncode,
                         query_sha256=sha(query), log_sha256=sha(log)))
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(passed=True, analysis_only=True, rtl_modified=False,
                  source_extracted_proof=False, hardware_acceptance=False,
                  invocation=os.environ.get('INVOCATION_ID'), pins=pins,
                  rows=rows, pins_unchanged=True, gameplay_ipc=None, fmax_mhz=None)
    (root / 'closed.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'pins'}), flush=True)


if __name__ == '__main__':
    main()
