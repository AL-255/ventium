"""Build the prepared UI composition only after this exact CAD chain closes."""
import inspect

import build_sfetch_interior_ui_soc as build
import run_next_ready_ui_build as previous

UNIT = 'ventium-sfetch-interior-timing-chain-oct16-r1.service'
INVOCATION = 'e4ffeb87989f40a3937f8f6ad535db88'


def namespace():
    assert build.sha(previous.__file__) == '9ce8d5e32f933b7646ccd1b3387cbc61876ee1b3735795103cee0fb4e1da4bc8'
    scope=dict(previous.__dict__,__file__=__file__,previous=previous,
               build=build,UNIT=UNIT,INVOCATION=INVOCATION)
    for func in (previous.disposition,previous.owner):
        exec(compile(inspect.getsource(func),__file__,'exec'),scope)
    return scope


def disposition(state):
    return namespace()['disposition'](state)


def derive():
    text=inspect.getsource(previous.main)
    for old,new in (
        ('next-ready-sequence-closed.json','sfetch-interior-sequence-closed.json'),
        ('881fba3884214158a222ab511a4d4e13','ad8028d56f994bd8ac7a081b4ded17c9'),
        ('(prepared,Path(__file__),Path(build.__file__))',
         '(prepared,Path(__file__),Path(previous.__file__),Path(build.__file__))'),
    ):
        assert text.count(old)==1, old
        text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


def main():
    scope=namespace()
    exec(compile(derive(),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
