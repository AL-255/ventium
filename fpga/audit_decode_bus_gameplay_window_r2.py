"""Audit a newer completed gameplay window of the unchanged older model.

Retains exact source/runtime/native-owner checks, raw pixels and actual clocks.
Frames 11/12 were visually reviewed: two different gameplay views with the
weapon and HUD, not loading screens. This does not qualify a current candidate.
"""
import inspect
from pathlib import Path

import audit_decode_bus_gameplay_window as previous


def main():
    assert previous.window.sha(previous.__file__)=='7bd1cb47a8c84a4d8b44d2f17f97dabcb0ca7606f306d2f3af707172c1ac635d'
    text = inspect.getsource(previous.main)
    edits = (
        ('observed_cycles[:12]','observed_cycles[:17]'),
        ('range(4,13)','range(4,18)'),
        ('1100065247','1600065247'),('1200065247','1700065247'),
        ('48146083','49046518'),('37609117','37998050'),('10536966','11048468'),
        ("((6,first,'Weapon firing in stone room with enemy and HUD'),",
         "((11,first,'Weapon and HUD in stone room; fallen enemies and pickup message'),"),
        ("(7,last,'Weapon in stone corridor with HUD; different view')):",
         "(12,last,'Weapon and HUD in different stone corridor view')):"),
        ('sample_indices=[11,12]','sample_indices=[16,17]'),
        ('post-hoc latest completed periodic window, not predeclared A/B',
         'post-hoc completed periodic window, not predeclared A/B'),
        ('decode-bus-gameplay-window-oct16-r1.json','decode-bus-gameplay-window-oct16-r2.json'),
        ('(Path(__file__),Path(window.__file__),',
         '(Path(__file__),Path(previous.__file__),Path(window.__file__),'),
    )
    for old,new in edits:
        assert old in text,old
        text = text.replace(old,new)
    namespace = dict(previous.__dict__, __file__=__file__, previous=previous)
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__': main()
