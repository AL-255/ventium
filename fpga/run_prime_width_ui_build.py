"""Wait for the exact width CAD chain before compiling its input composition."""
import inspect

import build_prime_width_ui_soc as build
import run_sfetch_interior_ui_build as template

UNIT='ventium-prime-width-timing-chain-oct16-r1.service'
INVOCATION='42b3ad41ea2f41d5be78bab3ab850260'


def namespace():
    assert build.sha(template.__file__)=='b9ee07f1172213780bf3befd6a94be2621a450a377bd57a62e667d5d5daa8b17'
    scope=template.namespace()
    scope.update(__file__=__file__,template=template,build=build,UNIT=UNIT,INVOCATION=INVOCATION)
    return scope


def disposition(state):
    return namespace()['disposition'](state)


def derive():
    text=template.derive()
    for old,new in (
        ('sfetch-interior-sequence-closed.json','prime-width-sequence-closed.json'),
        ('ad8028d56f994bd8ac7a081b4ded17c9','6486dfa5929e45f78d351a1622f67466'),
        ('Path(previous.__file__),Path(build.__file__))',
         'Path(previous.__file__),Path(template.__file__),Path(build.__file__))'),
    ):
        assert text.count(old)==1,old;text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


def main():
    scope=namespace()
    exec(compile(derive(),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
