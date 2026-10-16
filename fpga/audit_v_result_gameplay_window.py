"""Audit the V-result build's completed 1.1B--1.2B gameplay observation.

Frames 6/7 were visually reviewed: firing in a stone room, then a different
corridor view, both with weapon/HUD. Original raw pixels are retained. This is
post-hoc observation, not current fetch-candidate or full-timedemo acceptance.
"""
import inspect

import audit_decode_bus_gameplay_window as previous

MODEL = 'b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'


def derive():
    assert previous.window.sha(previous.__file__) == '7bd1cb47a8c84a4d8b44d2f17f97dabcb0ca7606f306d2f3af707172c1ac635d'
    text = inspect.getsource(previous.main)
    text = text.replace('decode-bus-', 'v-result-carry-')
    for old,new in (
        ('quake-cold-v-result-carry-oct15.1', 'quake-cold-v-result-carry-oct16.1'),
        ('ventium-v-result-carry-quake-oct15-r1.service', 'ventium-v-result-carry-quake-oct16-r1.service'),
        ("os.sched_getaffinity(native['pid'])=={11}", "os.sched_getaffinity(native['pid'])=={14}"),
        ('quake-decode-frame', 'quake-v-result-frame'),
        ('post-hoc latest completed periodic window, not predeclared A/B',
         'post-hoc completed periodic window, not predeclared A/B'),
        ('(Path(__file__),Path(window.__file__),',
         '(Path(__file__),Path(previous.__file__),Path(window.__file__),'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old,new)
    compile(text,__file__,'exec')
    return text


def main():
    scope = dict(previous.__dict__,__file__=__file__,previous=previous,MODEL=MODEL)
    exec(compile(derive(),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__': main()
