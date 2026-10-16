"""Independently regrade private-reference functional results; not promotion."""
from pathlib import Path
import audit_qualified_pair_credit_func as template
from prepare_parallel_write_admission import once


def derive():
    source=template.derive()
    for old,new in (
        ('import run_qualified_pair_credit_func as runner','import run_parallel_write_func as runner'),
        ('qualified-pair-credit-func-r1','parallel-write-func-r1'),
        ('qualified-pair-credit-core-r1','parallel-write-core-r1'),
        ('ventium-qualified-pair-func-oct16-r1.service','ventium-parallel-write-func-oct16-r1.service'),
        ('runner.SOURCE, Path(', 'runner.SOURCE, Path('+repr(str(Path(template.__file__)))+'), Path('),
    ):
        source=once(source,old,new)
    return source


if __name__=='__main__': exec(compile(derive(),__file__,'exec'),globals())
