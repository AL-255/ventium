"""Unchanged strict CPU lint on the sealed parallel-admission FPGA export."""
import freeze_parallel_write_rk_candidate as export
import lint_qualified_pair_credit_rk as template


def derive():
    assert export.native.sha(template.__file__) == '16ae2970da61e6e19febb058ae22861e2f99baf116ab6645457a0fc36228aad9'
    return export.native.recipe.once(template.derive(),
        '(Path(__file__),Path(template.__file__),Path(previous.__file__),',
        '(Path(__file__),Path(template.__file__),Path(template.template.__file__),Path(previous.__file__),')


def main():
    scope = dict(template.template.previous.__dict__, __file__=__file__, template=template,
                 previous=template.template.previous, export=export)
    exec(compile(derive(), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__': raise SystemExit(main())
